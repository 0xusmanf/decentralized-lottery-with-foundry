// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

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
        uint256 seed;
    }
    /* Events */

    event RandomWordsFulfilled(uint256 indexed requestId, uint256 outputSeed, uint96 payment, bool success);
    event RequestedLotteryWinner(uint256 indexed requestId);
    event LotteryEntered(address indexed player, uint256 numberOfEntries);
    event WinnerPicked(address indexed player);
    event ExpectedWinner(address expectedWinner, uint256 numberOfPlayers, uint256 numberOfEntrances);

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
    mapping(address => uint256) public entries;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant PRECISION = 1e18;
    mapping(address => bool) public hasEntered;
    uint256 totalEntriesPerRound;

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
        vm.assume(players.length > 0 && players.length <= 50);

        for (uint256 i = 0; i < players.length; i++) {
            players[i].player = _helperGetAddressFromSeed(players[i].seed);
            vm.assume(!hasEntered[players[i].player]);
            players[i].balance = bound(players[i].balance, lotteryEntranceFee, (lotteryEntranceFee * 5));
            vm.deal(players[i].player, players[i].balance);
            vm.prank(players[i].player);
            lottery.enterLottery{value: players[i].balance}();
            hasEntered[players[i].player] = true;
            uint256 totalEntries = _keepTrackOfEntries(players[i]);
            emit LotteryEntered(players[i].player, totalEntries);
        }
        _;
    }

    function _helperGetAddressFromSeed(uint256 seed) internal view returns (address) {
        seed = bound(seed, 1000, type(uint160).max);
        address player = address(uint160(seed));
        // Ensure only EOA
        vm.assume(player.code.length == 0);
        // Ignore precompiled consol contract
        vm.assume(player != 0x000000000000000000636F6e736F6c652e6c6f67);

        return player;
    }

    function _keepTrackOfEntries(Player memory player) internal returns (uint256) {
        uint256 totalEntriesPerPlayer = player.balance / lotteryEntranceFee;
        entries[player.player] = totalEntriesPerPlayer;
        totalEntriesPerRound += totalEntriesPerPlayer;
        return totalEntriesPerPlayer;
    }

    function _getExpectedwinner(Player[] memory players) internal view returns (address expectedPlayer) {
        uint256 expectedWinnerIndex = uint256(keccak256(abi.encode(1, 0))) % totalEntriesPerRound;
        uint256 cumulative = 0;
        for (uint256 i = 0; i < players.length;) {
            address player = players[i].player;
            cumulative += entries[player];
            if (expectedWinnerIndex < cumulative) {
                expectedPlayer = player;
                break;
            }
            unchecked {
                ++i;
            }
        }
    }

    function testFuzzLotteryRevertsWhenYouDontPayEnough(address player, uint256 value) public {
        // Arrange
        value = bound(value, 0, (lotteryEntranceFee - 1));
        vm.deal(player, value);
        vm.prank(player);
        // Act / Assert
        vm.expectRevert(Lottery.Lottery__SendMoreToEnterLottery.selector);
        lottery.enterLottery{value: value}();
    }

    function _helperFuzzLotteryRecordsPlayerWhenTheyEnter(Player[] memory players, uint256 index)
        internal
        enterLotteryWithMultiplePlayers(players)
    {
        // Arrange
        index = bound(index, 0, (players.length - 1));
        uint256 playerRecordedEntries = lottery.getEntriesPerPlayer(1, players[index].player);
        //Assert
        assert(playerRecordedEntries > 0);
    }

    function testFuzzLotteryRecordsPlayerWhenTheyEnter(Player[] memory players, uint256 index) public {
        _helperFuzzLotteryRecordsPlayerWhenTheyEnter(players, index);
    }

    function testFuzzEmitsEventOnEntrance(Player memory player) public {
        // Arrange
        player.player = _helperGetAddressFromSeed(player.seed);
        player.balance = bound(player.balance, lotteryEntranceFee, (lotteryEntranceFee * 5));
        vm.deal(player.player, player.balance);
        vm.prank(player.player);

        // Act / Assert
        vm.expectEmit(true, false, false, false, address(lottery));
        emit LotteryEntered(player.player, _keepTrackOfEntries(player));
        lottery.enterLottery{value: player.balance}();
    }

    function testFuzzDontAllowPlayersToEnterWhileLotteryIsCalculating(Player memory player) public {
        // Arrange
        player.player = _helperGetAddressFromSeed(player.seed);
        player.balance = bound(player.balance, lotteryEntranceFee, (lotteryEntranceFee * 4));
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
        player.player = _helperGetAddressFromSeed(player.seed);
        player.balance = bound(player.balance, lotteryEntranceFee, (lotteryEntranceFee * 4));
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

    function _helperFuzzUpkeep(Player[] memory players) internal enterLotteryWithMultiplePlayers(players) {}

    function testFuzzCheckUpkeepReturnsFalseIfLotteryIsntOpen(Player[] memory players) public {
        // Arrange
        _helperFuzzUpkeep(players);
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
        _helperFuzzUpkeep(players);
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
        _helperFuzzUpkeep(players);
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
        _helperFuzzUpkeep(players);
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);

        // Act / Assert
        // It doesnt revert
        lottery.performUpkeep("");
    }

    function testFuzzPerformUpkeepRevertsIfCheckUpkeepIsFalse(Player[] memory players) public {
        // Arrange
        _helperFuzzUpkeep(players);

        // Act / Assert
        vm.expectPartialRevert(bytes4(Lottery.Lottery__UpkeepNotNeeded.selector));
        lottery.performUpkeep("");
    }

    function testFuzzPerformUpkeepUpdatesLotteryStateAndEmitsRequestId(Player[] memory players) public {
        // Arrange
        _helperFuzzUpkeep(players);
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);

        // Act
        vm.recordLogs();
        lottery.performUpkeep(""); // emits requestId
        Vm.Log[] memory logEntries = vm.getRecordedLogs();
        bytes32 requestId = logEntries[1].topics[1];

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
        _helperFuzzUpkeep(players);

        // Act / Assert
        vm.expectRevert("nonexistent request");
        VRFCoordinatorV2Mock(vrfCoordinatorV2).fulfillRandomWords(requestId, address(lottery));
    }

    function testFuzzFulfillRandomWordsPicksAWinnerResetsAndWinnerCanWithdraw(Player[] memory players) public {
        // Arrange
        _helperFuzzUpkeep(players);
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);
        address expectedWinner = _getExpectedwinner(players);
        uint256 startingTimeStamp = lottery.getLastTimeStamp();
        uint256 startingBalance = expectedWinner.balance;
        uint256 prize = lottery.getPrizeValueOfCurrentRound();
        uint256 numberOfPlayers = lottery.getNumberOfPlayers();

        // Act
        vm.recordLogs();
        lottery.performUpkeep(""); // emits requestId
        Vm.Log[] memory logEntries = vm.getRecordedLogs();
        bytes32 requestId = logEntries[1].topics[1]; // get the requestId from the logs
        emit ExpectedWinner(expectedWinner, players.length, numberOfPlayers);
        VRFCoordinatorV2Mock(vrfCoordinatorV2).fulfillRandomWords(uint256(requestId), address(lottery));
        vm.prank(expectedWinner);
        lottery.withdrawPrize();

        // Assert
        address recentWinner = lottery.getRecentWinner();
        Lottery.LotteryState lotteryState = lottery.getLotteryState();
        uint256 winnerBalance = recentWinner.balance;
        uint256 endingTimeStamp = lottery.getLastTimeStamp();
        console.log("Number of Players: ", numberOfPlayers, " <> ", players.length);
        assert(numberOfPlayers == players.length);
        console.log("Winner: ", recentWinner, " <> ", expectedWinner);
        assert(recentWinner == expectedWinner);
        console.log("Lottery state: ", uint256(lotteryState));
        assert(uint256(lotteryState) == 0);
        console.log("Winner Balance: ", winnerBalance, " <> ", (startingBalance + prize));
        assert(winnerBalance == startingBalance + prize);
        console.log("Timestamp: ", endingTimeStamp, " <> ", startingTimeStamp);
        assert(endingTimeStamp > startingTimeStamp);
    }
}
