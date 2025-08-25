// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {Lottery} from "../../src/Lottery.sol";
import {VRFCoordinatorV2Mock} from "../mocks/VRFCoordinatorV2Mock.sol";
import {MockV3Aggregator} from "../mocks//MockV3Aggregator.sol";
import {Vm} from "forge-std/Vm.sol";

contract Handler is Test {
    Lottery public lottery;
    VRFCoordinatorV2Mock public vrfCoordinator;
    MockV3Aggregator public priceFeed;

    // === STATE TRACKING ===
    mapping(uint256 => address[]) public roundPlayers; // roundId => players
    mapping(uint256 => uint256) public roundPot; // roundId => total ETH
    mapping(address => uint256) public totalEthContributed;
    mapping(address => uint256) public totalEntries; // across all rounds
    mapping(address => bool) public hasEntered;

    uint256 public constant MAX_PLAYERS = 50;
    uint256 public constant STARTING_BALANCE = 10 ether;

    uint256 public lastRequestId;
    uint256 public lastRoundWithWinner;
    address public lastWinner;
    address[] public winners;

    constructor(Lottery _lottery, address _vrfCoordinator, address _priceFeed) {
        lottery = _lottery;
        vrfCoordinator = VRFCoordinatorV2Mock(_vrfCoordinator);
        priceFeed = MockV3Aggregator(_priceFeed);
    }

    // === FUZZ ACTIONS ===

    function enterLottery(uint256 seed, uint256 value) public {
        uint256 currentRound = lottery.getCurrentRoundId();
        if (roundPlayers[currentRound].length >= MAX_PLAYERS) return;

        address player = _makeAddr(seed);

        vm.assume(!hasEntered[player]);

        if (player.balance == 0) {
            vm.deal(player, STARTING_BALANCE);
        }

        uint256 minFee = lottery.getMinimumEthAmountToEnter();
        value = bound(value, minFee, minFee * 3);
        uint256 entries = value / minFee;

        vm.prank(player);
        lottery.enterLottery{value: value}();
        roundPlayers[currentRound].push(player);
        roundPot[currentRound] += (entries * minFee);
        totalEthContributed[player] += value;

        // Track entries from contract directly (assume 1 entry per minFee paid)
        uint256 entriesBought = value / minFee;
        totalEntries[player] += entriesBought;
        hasEntered[player] = true;
    }

    function warpForward(uint256 secondsForward, int256 ethPrice) public {
        secondsForward = bound(secondsForward, 1, 1 days);
        ethPrice = bound(ethPrice, 1000e8, 4000e8);
        vm.warp(block.timestamp + secondsForward);
        vm.roll(block.number + 1);
        priceFeed.updateAnswer(ethPrice);
    }

    function performUpkeep() public {
        (bool upkeepNeeded,) = lottery.checkUpkeep("");
        if (upkeepNeeded) {
            vm.recordLogs();
            lottery.performUpkeep("");
            lastRequestId = _lastRequestId();
            if (lastRequestId > 0) {
                vrfCoordinator.fulfillRandomWords(lastRequestId, address(lottery));
                lastWinner = lottery.getRecentWinner();
                winners.push(lastWinner);
                lastRoundWithWinner = lottery.getCurrentRoundId() - 1;
                lastRequestId = 0;
            }
        }
    }

    function withdraw(uint256 seed) public {
        if (winners.length == 0) return;
        uint256 winnerIndex = seed % winners.length;
        address winner = winners[winnerIndex];

        vm.prank(winner);
        lottery.withdrawPrize();
        winners[winnerIndex] = winners[winners.length - 1];
        winners.pop();
    }

    // === HELPERS ===
    function _makeAddr(uint256 seed) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(seed)))));
    }

    function _lastRequestId() internal returns (uint256) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 requestId = logs[1].topics[1];

        return uint256(requestId);
    }
}
