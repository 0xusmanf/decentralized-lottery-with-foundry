// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {DeployLottery} from "../../script/DeployLottery.s.sol";
import {Lottery} from "../../src/Lottery.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {VRFCoordinatorV2Mock} from "../mocks/VRFCoordinatorV2Mock.sol";
import {CreateSubscription} from "../../script/Interactions.s.sol";
import {LibString} from "@solmate/utils/LibString.sol";
import {MockV3Aggregator} from "../mocks//MockV3Aggregator.sol";

contract PlayerIsAContract {}

contract LotteryFuzzTest is StdCheats, Test {
    struct Player {
        address player;
        uint256 balance;
    }

    struct SeedPlayer {
        uint160 seed;
        uint256 balance;
    }
    /* Events */

    event RandomWordsFulfilled(uint256 indexed requestId, uint256 outputSeed, uint96 payment, bool success);
    event RequestedLotteryWinner(uint256 indexed requestId);
    event LotteryEntered(address indexed player);
    event WinnerPicked(address indexed player);

    Lottery public lottery;
    HelperConfig public helperConfig;

    uint64 subscriptionId;
    bytes32 gasLane;
    uint256 automationUpdateInterval;
    uint256 lotteryEntranceFee;
    uint256 minimumEntracneFee;
    uint32 callbackGasLimit;
    address vrfCoordinatorV2;
    address priceFeed;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant PRECISION = 1e18;
    mapping(address => bool) public hasEntered;

    PlayerIsAContract public playerIsAContract = new PlayerIsAContract();

    function setUp() external {
        DeployLottery deployer = new DeployLottery();
        (lottery, helperConfig, subscriptionId) = deployer.run();
        vm.deal(PLAYER, STARTING_USER_BALANCE);

        (
            ,
            gasLane,
            automationUpdateInterval,
            minimumEntracneFee,
            callbackGasLimit,
            vrfCoordinatorV2, // link
            // deployerKey
            ,
            ,
            priceFeed
        ) = helperConfig.activeNetworkConfig();

        lotteryEntranceFee = lottery.getMinimumEthAmountToEnter();
    }

    /////////////////////////
    // enterLottery         //
    /////////////////////////

    modifier enterLotteryWithMultiplePlayers(Player[] memory players) {
        //Arrange
        vm.assume(players.length > 0);
        for (uint256 i = 0; i < players.length; i++) {
            // Igonore contract addresses
            vm.assume(players[i].player.code.length == 0);
            // Ignore contracts i.e. consol, VM
            vm.assume(players[i].player != address(0x000000000000000000636F6e736F6c652e6c6f67));
            vm.assume(players[i].player != address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));
            // Ignore precompiled contracts
            vm.assume(uint256(uint160(players[i].player)) > 1000);

            vm.assume(!hasEntered[players[i].player]);
            players[i].balance = bound(players[i].balance, lottery.getMinimumEthAmountToEnter(), PRECISION);
            vm.deal(players[i].player, players[i].balance);
            vm.prank(players[i].player);
            lottery.enterLottery{value: players[i].balance}();
            hasEntered[players[i].player] = true;
        }
        _;
    }

    function testFuzzLotteryRevertsWhenYouDontPayEnough(address player, uint256 value) public {
        // Arrange
        value = bound(value, 0, (lottery.getMinimumEthAmountToEnter() - 1));
        vm.deal(player, value);
        vm.prank(player);
        // Act / Assert
        vm.expectRevert(Lottery.Lottery__SendMoreToEnterLottery.selector);
        lottery.enterLottery{value: value}();
    }

    function helperFuzzLotteryRecordsPlayerWhenTheyEnter(Player[] memory players, uint256 index)
        internal
        enterLotteryWithMultiplePlayers(players)
    {
        // Arrange
        index = bound(index, 0, (players.length - 1));
        uint256 playerRecordedEntries = lottery.getEntriesPerPlayer(players[index].player);
        //Assert
        assert(playerRecordedEntries > 0);
    }

    function testFuzzLotteryRecordsPlayerWhenTheyEnter(Player[] memory players, uint256 index) public {
        helperFuzzLotteryRecordsPlayerWhenTheyEnter(players, index);
    }

    function testFuzzEmitsEventOnEntrance(Player memory player) public {
        // Arrange
        // Igonore contract addresses
        vm.assume(player.player.code.length == 0);
        // Ignore contracts i.e. consol, VM
        vm.assume(player.player != address(0x000000000000000000636F6e736F6c652e6c6f67));
        vm.assume(player.player != address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));
        // Ignore precompiled contracts
        vm.assume(uint256(uint160(player.player)) > 1000);
        player.balance = bound(player.balance, lottery.getMinimumEthAmountToEnter(), PRECISION);
        vm.deal(player.player, player.balance);
        vm.prank(player.player);

        // Act / Assert
        vm.expectEmit(true, false, false, false, address(lottery));
        emit LotteryEntered(player.player);
        lottery.enterLottery{value: player.balance}();
    }

    function testFuzzDontAllowPlayersToEnterWhileLotteryIsCalculating(Player memory player) public {
        // Arrange
        // Igonore contract addresses
        vm.assume(player.player.code.length == 0);
        // Ignore contracts i.e. consol, VM
        vm.assume(player.player != address(0x000000000000000000636F6e736F6c652e6c6f67));
        vm.assume(player.player != address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));
        // Ignore precompiled contracts
        vm.assume(uint256(uint160(player.player)) > 1000);
        player.balance = bound(player.balance, lottery.getMinimumEthAmountToEnter(), PRECISION);
        vm.deal(player.player, (player.balance * 2));
        vm.prank(player.player);
        lottery.enterLottery{value: player.balance}();
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);
        lottery.performUpkeep("");

        // Act / Assert
        vm.expectRevert(Lottery.Lottery__LotteryNotOpen.selector);
        vm.prank(player.player);
        lottery.enterLottery{value: player.balance}();
    }

    function testFuzzPlayerCanNotEnterInTheSameRoundAgain(Player memory player) public {
        // Arrange
        // Igonore contract addresses
        vm.assume(player.player.code.length == 0);
        // Ignore contracts i.e. consol, VM
        vm.assume(player.player != address(0x000000000000000000636F6e736F6c652e6c6f67));
        vm.assume(player.player != address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));
        // Ignore precompiled contracts
        vm.assume(uint256(uint160(player.player)) > 1000);
        player.balance = bound(player.balance, lottery.getMinimumEthAmountToEnter(), PRECISION);
        vm.deal(player.player, (player.balance * 2));
        vm.prank(player.player);
        lottery.enterLottery{value: player.balance}();

        // Act / Assert
        vm.expectRevert(Lottery.Lottery__PlayerAlreadyEntered.selector);
        vm.prank(player.player);
        lottery.enterLottery{value: player.balance}();
    }

    /////////////////////////
    // checkUpkeep         //
    /////////////////////////

    function helperFuzzUpkeep(Player[] memory players) internal enterLotteryWithMultiplePlayers(players) {}

    function testFuzzCheckUpkeepReturnsFalseIfLotteryIsntOpen(Player[] memory players) public {
        // Arrange
        helperFuzzUpkeep(players);
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);
        lottery.performUpkeep("");
        Lottery.LotteryState lotteryState = lottery.getLotteryState();
        // Act
        (bool upkeepNeeded,) = lottery.checkUpkeep("");
        // Assert
        assert(lotteryState == Lottery.LotteryState.CALCULATING);
        assert(upkeepNeeded == false);
    }

    function testFuzzCheckUpkeepReturnsFalseIfEnoughTimeHasntPassed(Player[] memory players) public {
        // Arrange
        helperFuzzUpkeep(players);
        vm.warp(block.timestamp + automationUpdateInterval - 1);
        vm.roll(block.number + 1);
        Lottery.LotteryState lotteryState = lottery.getLotteryState();
        // Act
        (bool upkeepNeeded,) = lottery.checkUpkeep("");
        // Assert
        assert(lotteryState == Lottery.LotteryState.OPEN);
        assert(upkeepNeeded == false);
    }

    function testFuzzCheckUpkeepReturnsTrueWhenParametersGood(Player[] memory players) public {
        // Arrange
        helperFuzzUpkeep(players);
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);

        // Act
        (bool upkeepNeeded,) = lottery.checkUpkeep("");

        // Assert
        assert(upkeepNeeded);
    }

    /////////////////////////
    // performUpkeep       //
    /////////////////////////

    function testFuzzPerformUpkeepCanOnlyRunIfCheckUpkeepIsTrue(Player[] memory players) public {
        // Arrange
        helperFuzzUpkeep(players);
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);

        // Act / Assert
        // It doesnt revert
        lottery.performUpkeep("");
    }

    function testFuzzPerformUpkeepRevertsIfCheckUpkeepIsFalse(Player[] memory players) public {
        // Arrange
        helperFuzzUpkeep(players);

        // Act / Assert
        vm.expectPartialRevert(bytes4(Lottery.Lottery__UpkeepNotNeeded.selector));
        lottery.performUpkeep("");
    }

    function testFuzzPerformUpkeepUpdatesLotteryStateAndEmitsRequestId(Player[] memory players) public {
        // Arrange
        helperFuzzUpkeep(players);
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);

        // Act
        vm.recordLogs();
        lottery.performUpkeep(""); // emits requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        // Assert
        Lottery.LotteryState lotteryState = lottery.getLotteryState();
        assert(uint256(requestId) > 0);
        assert(uint256(lotteryState) == 1); // 0 = open, 1 = calculating
    }

    /////////////////////////
    // fulfillRandomWords //
    ////////////////////////

    function testFuzzFulfillRandomWordsCanOnlyBeCalledAfterPerformUpkeep(Player[] memory players, uint256 requestId)
        public
    {
        // Arrange
        helperFuzzUpkeep(players);

        // Act / Assert
        vm.expectRevert("nonexistent request");
        VRFCoordinatorV2Mock(vrfCoordinatorV2).fulfillRandomWords(requestId, address(lottery));
    }

    /*function testFuzzFulfillRandomWordsPicksAWinnerResetsAndWinnerCanWithdraw(Player[] memory players) public {
        // Arrange
        helperFuzzUpkeep(players);
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);
        uint256 expectedWinnerIndex = uint256(keccak256(abi.encode(1, 0))) % players.length;
        address expectedWinner = players[expectedWinnerIndex].player;
        uint256 startingTimeStamp = lottery.getLastTimeStamp();
        uint256 startingBalance = expectedWinner.balance;
        uint256 prize = lottery.getTotalEthValue();

        // Act
        vm.recordLogs();
        lottery.performUpkeep(""); // emits requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1]; // get the requestId from the logs

        VRFCoordinatorV2Mock(vrfCoordinatorV2).fulfillRandomWords(uint256(requestId), address(lottery));
        vm.prank(expectedWinner);
        lottery.withdrawPrize();

        // Assert
        address recentWinner = lottery.getRecentWinner();
        Lottery.LotteryState lotteryState = lottery.getLotteryState();
        uint256 winnerBalance = recentWinner.balance;
        uint256 endingTimeStamp = lottery.getLastTimeStamp();
        assert(recentWinner == expectedWinner);
        assert(uint256(lotteryState) == 0);
        assert(winnerBalance == startingBalance + prize);
        assert(endingTimeStamp > startingTimeStamp);
    }*/
}
