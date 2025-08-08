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
import {OracleLib} from "../../src/libraries/OracleLib.sol";

contract PlayerIsAContract {}

contract LotteryUnitTest is StdCheats, Test {
    /* Events */
    event RandomWordsFulfilled(uint256 indexed requestId, uint256 outputSeed, uint96 payment, bool indexed success);
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
    uint256 public constant NUMBER_OF_PLAYERS = 10;
    address[NUMBER_OF_PLAYERS] public PLAYERS;
    uint256 public constant PRECISION = 1e18;

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

    function testLotteryInitializesInOpenState() public view {
        assert(lottery.getLotteryState() == Lottery.LotteryState.OPEN);
    }

    /////////////////////////
    // enterLottery         //
    /////////////////////////

    modifier enterLotteryWithMultiplePlayers() {
        for (uint256 i = 0; i < PLAYERS.length; i++) {
            string memory userName = string(abi.encodePacked("player", LibString.toString(i)));
            PLAYERS[i] = makeAddr(userName);
            vm.deal(PLAYERS[i], STARTING_USER_BALANCE);
            vm.prank(PLAYERS[i]);
            lottery.enterLottery{value: lotteryEntranceFee}();
        }

        _;
    }

    function testLotteryRevertsWhenYouDontPayEnough() public {
        // Arrange
        vm.prank(PLAYER);
        // Act / Assert
        vm.expectRevert(Lottery.Lottery__SendMoreToEnterLottery.selector);
        lottery.enterLottery();
    }

    function testLotteryRecordsPlayerWhenTheyEnter() public {
        // Arrange
        vm.prank(PLAYER);
        // Act
        lottery.enterLottery{value: lotteryEntranceFee}();
        // Assert
        address playerRecorded = lottery.getPlayer(0);
        assert(playerRecorded == PLAYER);
    }

    function testLotteryRecordsPlayerEntriesAndReturnsRemainingBalance() public {
        // Arrange
        vm.deal(PLAYER, (lotteryEntranceFee * 5) + 2e10);
        vm.prank(PLAYER);
        // Act
        lottery.enterLottery{value: (lotteryEntranceFee * 5) + 2e10}();
        // Assert
        address playerRecorded1 = lottery.getPlayer(0);
        address playerRecorded2 = lottery.getPlayer(1);
        address playerRecorded3 = lottery.getPlayer(2);
        address playerRecorded4 = lottery.getPlayer(3);
        address playerRecorded5 = lottery.getPlayer(4);
        assert(playerRecorded1 == PLAYER);
        assert(playerRecorded2 == PLAYER);
        assert(playerRecorded3 == PLAYER);
        assert(playerRecorded4 == PLAYER);
        assert(playerRecorded5 == PLAYER);
        assert(PLAYER.balance == 2e10);
        assert(lottery.getEntriesPerPlayer(PLAYER) == 5);
    }

    function testEmitsEventOnEntrance() public {
        // Arrange
        vm.prank(PLAYER);

        // Act / Assert
        vm.expectEmit(true, false, false, false, address(lottery));
        emit LotteryEntered(PLAYER);
        lottery.enterLottery{value: lotteryEntranceFee}();
    }

    function testDontAllowPlayersToEnterWhileLotteryIsCalculating() public {
        // Arrange
        vm.prank(PLAYER);
        lottery.enterLottery{value: lotteryEntranceFee}();
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);
        lottery.performUpkeep("");

        // Act / Assert
        vm.expectRevert(Lottery.Lottery__LotteryNotOpen.selector);
        vm.prank(PLAYER);
        lottery.enterLottery{value: lotteryEntranceFee}();
    }

    function testPlayerCanNotEnterInTheSameRoundAgain() public {
        // Arrange
        vm.prank(PLAYER);
        lottery.enterLottery{value: lotteryEntranceFee}();

        // Act / Assert
        vm.expectRevert(Lottery.Lottery__PlayerAlreadyEntered.selector);
        vm.prank(PLAYER);
        lottery.enterLottery{value: lotteryEntranceFee}();
    }

    function testGetMinimumEthAmountToEnter() public view {
        (, int256 price,,,) = MockV3Aggregator(priceFeed).latestRoundData();
        uint256 EthAmount = minimumEntracneFee * PRECISION / uint256(price);
        assert(lottery.getMinimumEthAmountToEnter() == EthAmount);
    }

    function testEnterLotteryRevertsIfPriceIsStale() public {
        // Arrange
        vm.warp(block.timestamp + 3 hours + 1);
        vm.roll(block.number + 1);

        // Act / Assert
        vm.prank(PLAYER);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        lottery.enterLottery{value: lotteryEntranceFee}();
    }

    /////////////////////////
    // checkUpkeep         //
    /////////////////////////
    function testCheckUpkeepReturnsFalseIfItHasNoBalance() public {
        // Arrange
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);

        // Act
        (bool upkeepNeeded,) = lottery.checkUpkeep("");

        // Assert
        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsFalseIfLotteryIsntOpen() public {
        // Arrange
        vm.prank(PLAYER);
        lottery.enterLottery{value: lotteryEntranceFee}();
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

    function testCheckUpkeepReturnsFalseIfEnoughTimeHasntPassed() public {
        // Arrange
        vm.prank(PLAYER);
        lottery.enterLottery{value: lotteryEntranceFee}();
        vm.warp(block.timestamp + automationUpdateInterval - 1);
        vm.roll(block.number + 1);
        Lottery.LotteryState lotteryState = lottery.getLotteryState();
        // Act
        (bool upkeepNeeded,) = lottery.checkUpkeep("");
        // Assert
        assert(lotteryState == Lottery.LotteryState.OPEN);
        assert(upkeepNeeded == false);
    }

    function testCheckUpkeepReturnsTrueWhenParametersGood() public {
        // Arrange
        vm.prank(PLAYER);
        lottery.enterLottery{value: lotteryEntranceFee}();
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

    function testPerformUpkeepCanOnlyRunIfCheckUpkeepIsTrue() public {
        // Arrange
        vm.prank(PLAYER);
        lottery.enterLottery{value: lotteryEntranceFee}();
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);

        // Act / Assert
        // It doesnt revert
        lottery.performUpkeep("");
    }

    function testPerformUpkeepRevertsIfCheckUpkeepIsFalse() public {
        // Arrange
        uint256 currentBalance = 0;
        uint256 numPlayers = 0;
        Lottery.LotteryState rState = lottery.getLotteryState();
        // Act / Assert
        vm.expectRevert(
            abi.encodeWithSelector(Lottery.Lottery__UpkeepNotNeeded.selector, currentBalance, numPlayers, rState)
        );
        lottery.performUpkeep("");
    }

    function testPerformUpkeepUpdatesLotteryStateAndEmitsRequestId() public {
        // Arrange
        vm.prank(PLAYER);
        lottery.enterLottery{value: lotteryEntranceFee}();
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

    modifier lotteryEntered() {
        vm.prank(PLAYER);
        lottery.enterLottery{value: lotteryEntranceFee}();
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);
        _;
    }

    modifier skipFork() {
        if (block.chainid != 31337) {
            return;
        }
        _;
    }

    function testFulfillRandomWordsCanOnlyBeCalledAfterPerformUpkeep() public lotteryEntered skipFork {
        // Arrange
        // Act / Assert
        vm.expectRevert("nonexistent request");
        // vm.mockCall could be used here...
        VRFCoordinatorV2Mock(vrfCoordinatorV2).fulfillRandomWords(0, address(lottery));

        vm.expectRevert("nonexistent request");

        VRFCoordinatorV2Mock(vrfCoordinatorV2).fulfillRandomWords(1, address(lottery));
    }

    function testFulfillRandomWordsPicksAWinnerResetsAndWinnerCanWithdraw() public lotteryEntered skipFork {
        address expectedWinner = address(1);

        // Arrange
        uint256 additionalEntrances = 3;
        uint256 startingIndex = 1; // We have starting index be 1 so we can start with address(1) and not address(0)

        for (uint256 i = startingIndex; i < startingIndex + additionalEntrances; i++) {
            address player = address(uint160(i));
            hoax(player, 1 ether); // deal 1 eth to the player
            lottery.enterLottery{value: lotteryEntranceFee}();
        }

        uint256 startingTimeStamp = lottery.getLastTimeStamp();
        uint256 startingBalance = expectedWinner.balance;

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
        uint256 prize = lotteryEntranceFee * (additionalEntrances + 1);

        console.log("Recent Winner: ", recentWinner, " <> ", expectedWinner);
        assert(recentWinner == expectedWinner);
        console.log("Lottery State: ", uint256(lotteryState));
        assert(uint256(lotteryState) == 0);
        console.log("Winner Balance: ", winnerBalance, " <> ", (startingBalance + prize));
        assert(winnerBalance == startingBalance + prize);
        console.log("Timestamp: ", endingTimeStamp, " <> ", startingTimeStamp);
        assert(endingTimeStamp > startingTimeStamp);
    }

    function testUserCannotWithdrawIfNotTheWinner() public lotteryEntered skipFork {
        address nonWinner = makeAddr("nonwinner");

        // Arrange
        uint256 additionalEntrances = 3;
        uint256 startingIndex = 1; // We have starting index be 1 so we can start with address(1) and not address(0)

        for (uint256 i = startingIndex; i < startingIndex + additionalEntrances; i++) {
            address player = address(uint160(i));
            hoax(player, 1 ether); // deal 1 eth to the player
            lottery.enterLottery{value: lotteryEntranceFee}();
        }
        // Act
        vm.recordLogs();
        lottery.performUpkeep(""); // emits requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1]; // get the requestId from the logs

        VRFCoordinatorV2Mock(vrfCoordinatorV2).fulfillRandomWords(uint256(requestId), address(lottery));

        // Assert
        vm.prank(nonWinner);
        vm.expectRevert(Lottery.Lottery__NoPrizeToWithdraw.selector);
        lottery.withdrawPrize();
    }

    function testWithdrawPrizeRevertsIfTransferFails() public {
        // Arrange
        vm.deal(address(playerIsAContract), lotteryEntranceFee);
        vm.prank(address(playerIsAContract));
        lottery.enterLottery{value: lotteryEntranceFee}();
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);

        // Act
        vm.recordLogs();
        lottery.performUpkeep(""); // emits requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1]; // get the requestId from the logs

        VRFCoordinatorV2Mock(vrfCoordinatorV2).fulfillRandomWords(uint256(requestId), address(lottery));

        // Assert
        vm.prank(address(playerIsAContract));
        vm.expectRevert(Lottery.Lottery__TransferFailed.selector);
        lottery.withdrawPrize();
    }

    function testWithdrawPrizeRevertsIfLotteryCalculating() public {
        // Arrange
        vm.prank(PLAYER);
        lottery.enterLottery{value: lotteryEntranceFee}();
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);

        // Act
        vm.recordLogs();
        lottery.performUpkeep(""); // emits requestId

        // Assert
        vm.prank(PLAYER);
        vm.expectRevert(Lottery.Lottery__LotteryNotOpen.selector);
        lottery.withdrawPrize();
    }

    ///////////////////////
    // getter functions //
    //////////////////////

    function testGetEntranceFee() public view {
        assert(lottery.getEntranceFee() == minimumEntracneFee);
    }

    function testGetNumberOfPlayers() public enterLotteryWithMultiplePlayers {
        assert(lottery.getNumberOfPlayers() == NUMBER_OF_PLAYERS);
    }

    function testGetTotalEthValue() public enterLotteryWithMultiplePlayers {
        assert(lottery.getTotalEthValue() == lotteryEntranceFee * NUMBER_OF_PLAYERS);
    }

    function testGetInterval() public view {
        assert(lottery.getInterval() == automationUpdateInterval);
    }

    function testGetPriceFeedAddress() public view {
        assert(lottery.getPriceFeedAddress() == priceFeed);
    }

    function testGetCallbackGasLimit() public view {
        assert(lottery.getCallbackGasLimit() == callbackGasLimit);
    }

    function testGetVrfCoordinatorV2() public view {
        assert(lottery.getVrfCoordinatorV2() == vrfCoordinatorV2);
    }

    function testGetGasLane() public view {
        assert(lottery.getGasLane() == gasLane);
    }

    function testGetNumWords() public view {
        assert(lottery.getNumWords() == 1);
    }

    function testGetRequestConfirmation() public view {
        assert(lottery.getRequestConfirmations() == 3);
    }

    function testGetPrecision() public view {
        assert(lottery.getPrecision() == PRECISION);
    }

    function testGetCurrentRoundId() public enterLotteryWithMultiplePlayers {
        assert(lottery.getCurrentRoundId() == 1);
    }

    function testGetIsEntered() public {
        // arrange
        vm.prank(PLAYER);
        lottery.enterLottery{value: lotteryEntranceFee}();

        // act / assert
        assert(lottery.getIsEntered(PLAYER) == true);
    }

    function testGetSubscriptionId() public view {
        assert(lottery.getSubscriptionId() == subscriptionId);
    }

    function testGetTimeOutLimit() public view {
        assert(lottery.getTimeOutLimit() == 3 hours);
    }
}
