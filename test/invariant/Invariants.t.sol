// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {DeployLottery} from "../../script/DeployLottery.s.sol";
import {Lottery} from "../../src/Lottery.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Handler} from "./Handler.sol";

contract LotteryInvariants is StdInvariant, Test {
    Lottery public lottery;
    HelperConfig public helperConfig;
    Handler public handler;

    function setUp() public {
        DeployLottery deployer = new DeployLottery();
        uint64 subscriptionId;
        (lottery, helperConfig, subscriptionId) = deployer.run();

        (,,,,, address vrfCoordinator,,, address priceFeed) = helperConfig.activeNetworkConfig();

        handler = new Handler(lottery, vrfCoordinator, priceFeed);

        targetContract(address(handler));
    }

    /// Invariant: total entries match recorded entries
    function invariant_totalEntriesMatchesSum() public view {
        uint256 sum = 0;
        uint256 numPlayers = lottery.getNumberOfPlayers();
        uint256 round = lottery.getCurrentRoundId();
        for (uint256 i = 0; i < numPlayers; i++) {
            address player = lottery.getPlayer(i);
            sum += lottery.getEntriesPerPlayer(round, player);
        }
        assertEq(sum, lottery.getTotalEntriesCurrentRound());
    }

    /// Invariant: State always valid
    function invariant_stateIsValid() public view {
        Lottery.LotteryState state = lottery.getLotteryState();
        assertTrue(state == Lottery.LotteryState.OPEN || state == Lottery.LotteryState.CALCULATING);
    }

    /// Invariant: minimum entry fee is > 0
    function invariant_minimumFeePositive() public view {
        assertGt(lottery.getMinimumEthAmountToEnter(), 0);
    }

    /// Invariant: Contract balance matches pot for current round
    function invariant_balanceMatchesPot() public view {
        uint256 round = lottery.getCurrentRoundId();
        assertEq(address(lottery).balance, handler.roundPot(round));
    }
}
