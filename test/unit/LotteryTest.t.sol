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
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract PlayerIsAContract {}

contract LotteryUnitTest is StdCheats, Test {
    /* Events */
    event RandomWordsFulfilled(uint256 indexed requestId, uint256 outputSeed, uint96 payment, bool indexed success);
    event RequestedLotteryWinner(uint256 indexed requestId);
    event LotteryEntered(address indexed player, uint256 numberOfEntries);
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
    uint256 public PROTOCOL_FEE_PERCENTAGE;

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
        PROTOCOL_FEE_PERCENTAGE = lottery.getProtocolFeePercentage();
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
        uint256 expectedReturnBalance = 2e10;
        vm.deal(PLAYER, (lotteryEntranceFee * 5) + expectedReturnBalance);
        vm.prank(PLAYER);
        // Act
        lottery.enterLottery{value: (lotteryEntranceFee * 5) + expectedReturnBalance}();
        // Assert
        address playerRecorded1 = lottery.getPlayer(0);
        assert(playerRecorded1 == PLAYER);
        assert(PLAYER.balance == expectedReturnBalance);
        assert(lottery.getEntriesPerPlayer(1, PLAYER) == 5);
    }

    function testEmitsEventOnEntrance() public {
        // Arrange
        vm.prank(PLAYER);

        // Act / Assert
        vm.expectEmit(true, false, false, false, address(lottery));
        emit LotteryEntered(PLAYER, 1);
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

    function testEnterLotteryRevertsWhenMaxPlayersReached() public {
        uint256 maxPlayers = 50;

        for (uint256 i = 0; i < maxPlayers; i++) {
            address player = address(uint160(1000 + i));
            hoax(player, 1 ether);
            lottery.enterLottery{value: lotteryEntranceFee}();
        }

        address extra = address(uint160(9999));
        hoax(extra, 1 ether);
        vm.expectRevert(Lottery.Lottery__LotteryIsFull.selector);
        lottery.enterLottery{value: lotteryEntranceFee}();
    }

    function testEnterLotteryRevertsWhenMoreThanFiveEntries() public {
        vm.deal(PLAYER, (lotteryEntranceFee * 6));
        vm.prank(PLAYER);
        vm.expectRevert(Lottery.Lottery__MoreThenFiveEntriesNotAllowed.selector);
        lottery.enterLottery{value: lotteryEntranceFee * 6}();
    }

    function testEnterRefundRevertsWhenRefundToContractFails() public {
        uint256 overpay = (lotteryEntranceFee * 2) + 1;
        vm.deal(address(playerIsAContract), overpay);
        vm.prank(address(playerIsAContract));
        vm.expectRevert(Lottery.Lottery__ReturnAmountTransferFailed.selector);
        lottery.enterLottery{value: overpay}();
    }

    function testGetMinimumEthAmountToEnter() public view {
        (, int256 price,,,) = MockV3Aggregator(priceFeed).latestRoundData();
        uint256 EthAmount = minimumEntracneFee * PRECISION / uint256(price);
        assert(lottery.getMinimumEthAmountToEnter() == EthAmount);
    }

    function testGetPrizeValueOfCurrentRoundCalculation() public {
        // No entries => prize should be zero
        assert(lottery.getPrizeValueOfCurrentRound() == 0);

        // Let one player enter with 2 entries, check prize value matches formula
        vm.deal(PLAYER, (lotteryEntranceFee * 2));
        vm.prank(PLAYER);
        lottery.enterLottery{value: lotteryEntranceFee * 2}();
        // fee = ethValueOfRound * 5% ; prize = ethValueOfRound - fee
        uint256 ethValue = lottery.getEthValueOfCurrentRound(); // after enter it's populated
        uint256 fee = (ethValue * PROTOCOL_FEE_PERCENTAGE) / PRECISION;
        uint256 expectedPrize = ethValue - fee;
        assert(lottery.getPrizeValueOfCurrentRound() == expectedPrize);
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
    // withdraw            //
    /////////////////////////

    function testWithdrawPrizeToAnAddressFlowAndRevertPaths() public lotteryEntered skipFork {
        // Arrange: add additional entrants so there is a prize and fee
        // add more entrants to increase pool
        for (uint256 i = 2; i < 5; i++) {
            address player = address(uint160(i));
            hoax(player, 1 ether);
            lottery.enterLottery{value: lotteryEntranceFee}();
        }

        // Move time, call upkeep, get request id and fulfill
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);

        vm.recordLogs();
        lottery.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];
        VRFCoordinatorV2Mock(vrfCoordinatorV2).fulfillRandomWords(uint256(requestId), address(lottery));

        // get winner and prize amount
        address recentWinner = lottery.getRecentWinner();
        uint256 prize = lottery.getWinnerPrize(recentWinner);
        assert(prize > 0);

        // Only owner can enable withdraw-to-an-address
        // fetch deployerKey to obtain owner address
        (,,,,,,, uint256 deployerKey,) = helperConfig.activeNetworkConfig();
        address owner = vm.addr(deployerKey);

        // Non-owner enabling should revert (sanity)
        vm.prank(PLAYER); // random non-owner
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        lottery.setWithdrawPrizeToAnAddressEnabled(true);

        // Owner enables flag
        vm.prank(owner);
        lottery.setWithdrawPrizeToAnAddressEnabled(true);
        assert(lottery.getWithdrawPrizeToAnAddressState() == true);

        // Should revert if transfer fails
        vm.prank(recentWinner);
        vm.expectRevert(Lottery.Lottery__TransferFailed.selector);
        lottery.withdrawPrizeToAnAddress(address(playerIsAContract));

        // Withdraw to zero address should revert
        vm.prank(recentWinner);
        vm.expectRevert(Lottery.Lottery__TransferNotAllowedToZeroAddress.selector);
        lottery.withdrawPrizeToAnAddress(address(0));

        // Should revert if caller has no prize
        vm.prank(PLAYER);
        vm.expectRevert(Lottery.Lottery__NoPrizeToWithdraw.selector);
        lottery.withdrawPrizeToAnAddress(PLAYER);

        // Withdraw to a different receiver should succeed and disable the flag
        address receiver = makeAddr("receiver");
        uint256 receiverStarting = receiver.balance;
        vm.prank(recentWinner);
        lottery.withdrawPrizeToAnAddress(receiver);
        assert(lottery.getWithdrawPrizeToAnAddressState() == false);
        assert(lottery.getWinnerPrize(recentWinner) == 0);
        assert(receiver.balance == receiverStarting + prize);
    }

    function testWithdrawProtocolFeeOnlyOwnerAndResetsCollectedFeeAndRevetPaths() public lotteryEntered skipFork {
        // Arrange: create a small pool, perform upkeep and fulfill to collect fee
        // Add an extra entrant so totalEntries > 0
        address extra = address(uint160(1234));
        hoax(extra, 1 ether);
        lottery.enterLottery{value: lotteryEntranceFee}();

        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);
        vm.recordLogs();
        lottery.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        // owner withdraws and fee resets
        (,,,,,,, uint256 deployerKey,) = helperConfig.activeNetworkConfig();
        address owner = vm.addr(deployerKey);
        vm.prank(owner);
        vm.expectRevert(Lottery.Lottery__NoFeeToWithdraw.selector);
        lottery.withdrawProtocolFee();

        VRFCoordinatorV2Mock(vrfCoordinatorV2).fulfillRandomWords(uint256(requestId), address(lottery));

        // compute expected fee (read from contract state)
        uint256 feeCollected = lottery.getTotalFeeCollected();
        assert(feeCollected > 0);

        // non-owner cannot call withdrawProtocolFee
        vm.prank(PLAYER);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        lottery.withdrawProtocolFee();

        uint256 ownerStarting = owner.balance;
        vm.prank(owner);
        lottery.withdrawProtocolFee();
        assert(lottery.getTotalFeeCollected() == 0);
        assert(owner.balance == ownerStarting + feeCollected);
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
        uint256 fee = ((lotteryEntranceFee * (additionalEntrances + 1)) * PROTOCOL_FEE_PERCENTAGE) / PRECISION;
        uint256 prize = (lotteryEntranceFee * (additionalEntrances + 1)) - fee;

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

    function testGetTotalFeeCollectedMatchesExpected() public lotteryEntered skipFork {
        // add another player to generate a bigger pool
        address p2 = makeAddr("p2");
        hoax(p2, 1 ether);
        lottery.enterLottery{value: lotteryEntranceFee}();

        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);
        vm.recordLogs();
        lottery.performUpkeep("");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 reqId = logs[1].topics[1];
        VRFCoordinatorV2Mock(vrfCoordinatorV2).fulfillRandomWords(uint256(reqId), address(lottery));

        uint256 fee = lottery.getTotalFeeCollected();
        uint256 ethValue = lottery.getTotalEthValue();
        assertGt(fee, 0);
        // protocol fee should be <= total ethValue of round
        assertLe(fee, ethValue);
    }

    function testProtocolFeePercentageAndPrecisionConstants() public view {
        uint256 percentage = lottery.getProtocolFeePercentage();
        uint256 precision = lottery.getPrecision();
        assertEq(percentage, 5e16); // example: 5% if PRECISION=10000
        assertEq(precision, 1e18);
    }

    function testGetWinnerPrizeAndRecentWinner() public lotteryEntered skipFork {
        // add another player so there's a random outcome
        address p2 = makeAddr("p2");
        hoax(p2, 1 ether);
        lottery.enterLottery{value: lotteryEntranceFee}();

        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);
        vm.recordLogs();
        lottery.performUpkeep("");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 reqId = logs[1].topics[1];
        VRFCoordinatorV2Mock(vrfCoordinatorV2).fulfillRandomWords(uint256(reqId), address(lottery));

        address winner = lottery.getRecentWinner();
        uint256 prize = lottery.getWinnerPrize(winner);
        assertTrue(winner != address(0));
        assertGt(prize, 0);
    }

    function testGetEthValueOfCurrentRoundAfterEntries() public {
        vm.deal(PLAYER, lotteryEntranceFee * 2);
        vm.prank(PLAYER);
        lottery.enterLottery{value: lotteryEntranceFee * 2}();
        assertEq(lottery.getEthValueOfCurrentRound(), lotteryEntranceFee * 2);
    }

    function testGetWithdrawPrizeToAnAddressStateDefaultsToFalse() public view {
        assertFalse(lottery.getWithdrawPrizeToAnAddressState());
    }

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

    function testGetSubscriptionId() public view {
        assert(lottery.getSubscriptionId() == subscriptionId);
    }

    function testGetTimeOutLimit() public view {
        assert(lottery.getTimeOutLimit() == 3 hours);
    }

    function testgetNumberOfPlayersInCurrentRound() public lotteryEntered {
        assert(lottery.getNumberOfPlayersInCurrentRound() == 1);
    }
}
