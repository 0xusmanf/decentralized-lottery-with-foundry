// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {Raffle} from "../../src/Raffle.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {VRFCoordinatorV2Mock} from "../mocks/VRFCoordinatorV2Mock.sol";
import {CreateSubscription} from "../../script/Interactions.s.sol";
import {LibString} from "@solmate/utils/LibString.sol";
import {MockV3Aggregator} from "../mocks//MockV3Aggregator.sol";

contract PlayerIsAContract {}

contract RaffleFuzzTest is StdCheats, Test {
    struct Player {
        address player;
        uint256 balance;
    }
    /* Events */

    event RandomWordsFulfilled(uint256 indexed requestId, uint256 outputSeed, uint96 payment, bool success);
    event RequestedRaffleWinner(uint256 indexed requestId);
    event RaffleEntered(address indexed player);
    event WinnerPicked(address indexed player);

    Raffle public raffle;
    HelperConfig public helperConfig;

    uint64 subscriptionId;
    bytes32 gasLane;
    uint256 automationUpdateInterval;
    uint256 raffleEntranceFee = 3e16;
    uint256 minimumEntracneFee;
    uint32 callbackGasLimit;
    address vrfCoordinatorV2;
    address priceFeed;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant NUMBER_OF_PLAYERS = 10;
    address[NUMBER_OF_PLAYERS] public PLAYERS;
    uint256 public constant PRECISION = 1e18;
    mapping(address => bool) public hasEntered;

    PlayerIsAContract public playerIsAContract = new PlayerIsAContract();

    function setUp() external {
        DeployRaffle deployer = new DeployRaffle();
        (raffle, helperConfig, subscriptionId) = deployer.run();
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
    }

    /////////////////////////
    // enterRaffle         //
    /////////////////////////

    modifier enterRaffleWithMultiplePlayers(Player[] memory players) {
        //Arrange
        vm.assume(players.length > 0);
        for (uint256 i = 0; i < players.length; i++) {
            vm.assume(players[i].player.code.length == 0);
            vm.assume(!hasEntered[players[i].player]);
            players[i].balance = bound(players[i].balance, raffle.getMinimumEthAmountToEnter(), PRECISION);
            vm.deal(players[i].player, players[i].balance);
            vm.prank(players[i].player);
            raffle.enterRaffle{value: players[i].balance}();
            hasEntered[players[i].player] = true;
        }
        _;
    }

    function testFuzzRaffleRevertsWhenYouDontPayEnough(address player, uint256 value) public {
        // Arrange
        value = bound(value, 0, (raffle.getMinimumEthAmountToEnter() - 1));
        vm.deal(player, value);
        vm.prank(player);
        // Act / Assert
        vm.expectRevert(Raffle.Raffle__SendMoreToEnterRaffle.selector);
        raffle.enterRaffle{value: value}();
    }

    function helperFuzzRaffleRecordsPlayerWhenTheyEnter(Player[] memory players, uint256 index)
        internal
        enterRaffleWithMultiplePlayers(players)
    {
        // Arrange
        index = bound(index, 0, (players.length - 1));
        address playerRecorded = raffle.getPlayer(index);
        //Assert
        assert(playerRecorded == players[index].player);
    }

    function testFuzzRaffleRecordsPlayerWhenTheyEnter(Player[] memory players, uint256 index) public {
        helperFuzzRaffleRecordsPlayerWhenTheyEnter(players, index);
    }

    function testFuzzEmitsEventOnEntrance(Player memory player) public {
        // Arrange
        player.balance = bound(player.balance, raffle.getMinimumEthAmountToEnter(), PRECISION);
        vm.deal(player.player, player.balance);
        vm.prank(player.player);

        // Act / Assert
        vm.expectEmit(true, false, false, false, address(raffle));
        emit RaffleEntered(player.player);
        raffle.enterRaffle{value: player.balance}();
    }

    function testFuzzDontAllowPlayersToEnterWhileRaffleIsCalculating(Player memory player) public {
        // Arrange
        player.balance = bound(player.balance, raffle.getMinimumEthAmountToEnter(), PRECISION);
        vm.deal(player.player, (player.balance * 2));
        vm.prank(player.player);
        raffle.enterRaffle{value: player.balance}();
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);
        raffle.performUpkeep("");

        // Act / Assert
        vm.expectRevert(Raffle.Raffle__RaffleNotOpen.selector);
        vm.prank(player.player);
        raffle.enterRaffle{value: player.balance}();
    }

    function testFuzzPlayerCanNotEnterInTheSameRoundAgain(Player memory player) public {
        // Arrange
        player.balance = bound(player.balance, raffle.getMinimumEthAmountToEnter(), PRECISION);
        vm.deal(player.player, (player.balance * 2));
        vm.prank(player.player);
        raffle.enterRaffle{value: player.balance}();

        // Act / Assert
        vm.expectRevert(Raffle.Raffle__PlayerAlreadyEntered.selector);
        vm.prank(player.player);
        raffle.enterRaffle{value: player.balance}();
    }

    /////////////////////////
    // checkUpkeep         //
    /////////////////////////

    function helperFuzzUpkeep(Player[] memory players) internal enterRaffleWithMultiplePlayers(players) {}

    function testFuzzCheckUpkeepReturnsFalseIfRaffleIsntOpen(Player[] memory players) public {
        // Arrange
        helperFuzzUpkeep(players);
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);
        raffle.performUpkeep("");
        Raffle.RaffleState raffleState = raffle.getRaffleState();
        // Act
        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        // Assert
        assert(raffleState == Raffle.RaffleState.CALCULATING);
        assert(upkeepNeeded == false);
    }

    function testFuzzCheckUpkeepReturnsFalseIfEnoughTimeHasntPassed(Player[] memory players) public {
        // Arrange
        helperFuzzUpkeep(players);
        vm.warp(block.timestamp + automationUpdateInterval - 1);
        vm.roll(block.number + 1);
        Raffle.RaffleState raffleState = raffle.getRaffleState();
        // Act
        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        // Assert
        assert(raffleState == Raffle.RaffleState.OPEN);
        assert(upkeepNeeded == false);
    }

    function testFuzzCheckUpkeepReturnsTrueWhenParametersGood(Player[] memory players) public {
        // Arrange
        helperFuzzUpkeep(players);
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);

        // Act
        (bool upkeepNeeded,) = raffle.checkUpkeep("");

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
        raffle.performUpkeep("");
    }

    function testFuzzPerformUpkeepRevertsIfCheckUpkeepIsFalse(Player[] memory players) public {
        // Arrange
        helperFuzzUpkeep(players);

        // Act / Assert
        vm.expectPartialRevert(bytes4(Raffle.Raffle__UpkeepNotNeeded.selector));
        raffle.performUpkeep("");
    }

    function testFuzzPerformUpkeepUpdatesRaffleStateAndEmitsRequestId(Player[] memory players) public {
        // Arrange
        helperFuzzUpkeep(players);
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);

        // Act
        vm.recordLogs();
        raffle.performUpkeep(""); // emits requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        // Assert
        Raffle.RaffleState raffleState = raffle.getRaffleState();
        assert(uint256(requestId) > 0);
        assert(uint256(raffleState) == 1); // 0 = open, 1 = calculating
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
        VRFCoordinatorV2Mock(vrfCoordinatorV2).fulfillRandomWords(requestId, address(raffle));
    }

    function testFuzzFulfillRandomWordsPicksAWinnerResetsAndSendsMoney(Player[] memory players) public {
        // Arrange
        helperFuzzUpkeep(players);
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);
        uint256 expectedWinnerIndex = uint256(keccak256(abi.encode(1, 0))) % players.length;
        address expectedWinner = players[expectedWinnerIndex].player;
        uint256 startingTimeStamp = raffle.getLastTimeStamp();
        uint256 startingBalance = expectedWinner.balance;
        uint256 prize = raffle.getTotalEthValue();

        // Act
        vm.recordLogs();
        raffle.performUpkeep(""); // emits requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1]; // get the requestId from the logs

        VRFCoordinatorV2Mock(vrfCoordinatorV2).fulfillRandomWords(uint256(requestId), address(raffle));

        // Assert
        address recentWinner = raffle.getRecentWinner();
        Raffle.RaffleState raffleState = raffle.getRaffleState();
        uint256 winnerBalance = recentWinner.balance;
        uint256 endingTimeStamp = raffle.getLastTimeStamp();
        assert(recentWinner == expectedWinner);
        assert(uint256(raffleState) == 0);
        assert(winnerBalance == startingBalance + prize);
        assert(endingTimeStamp > startingTimeStamp);
    }
}
