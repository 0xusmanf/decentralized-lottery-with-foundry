// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2} from "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title Decentralized Lottery
 * @author 0xusmanf
 * @notice A simple decentralized lottery demonstrating Chainlink VRF v2, Chainlink Automation (Keepers),
 *         and a price feed for ETH/USD conversions.
 *
 * @dev This contract is unaudited and intended for demonstration/learning purposes only.
 *      - Users call `enterLottery()` with ETH to participate.
 *      - An upkeep (Chainlink Automation) periodically calls `performUpkeep` which requests randomness.
 *      - Chainlink VRF calls `fulfillRandomWords` which selects a winner based on entries.
 *      - Winners withdraw their prize via `withdrawPrize()` (or `withdrawPrizeToAnAddress` if enabled).
 *
 *      The contract uses `Ownable` for protocol fee withdrawal by the owner.
 */
contract Lottery is VRFConsumerBaseV2, AutomationCompatibleInterface, ReentrancyGuard, Ownable2Step {
    /* Errors */

    error Lottery__LotteryIsFull();
    error Lottery__TransferFailed();
    error Lottery__LotteryNotOpen();
    error Lottery__NoFeeToWithdraw();
    error Lottery__NoPrizeToWithdraw();
    error Lottery__PlayerAlreadyEntered();
    error Lottery__SendMoreToEnterLottery();
    error Lottery__ReturnAmountTransferFailed();
    error Lottery__WithdrawToAnAddressNotEnabled();
    error Lottery__MoreThenFiveEntriesNotAllowed();
    error Lottery__TransferNotAllowedToZeroAddress();
    error Lottery__UpkeepNotNeeded(uint256 currentBalance, uint256 numPlayers, uint256 LotteryState);

    /* TYPE DECLARATIONS */
    enum LotteryState {
        OPEN,
        CALCULATING
    }

    using OracleLib for AggregatorV3Interface;

    /* State variables */
    // Chainlink VRF Variables
    VRFCoordinatorV2Interface private immutable i_vrfCoordinator;
    uint64 private immutable i_subscriptionId;
    bytes32 private immutable i_gasLane;
    uint32 private immutable i_callbackGasLimit;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;
    uint256 public constant PRECISION = 1e18;

    // Chainlink Aggregator Variables
    AggregatorV3Interface private immutable i_priceFeed;

    // Lottery Variables
    uint256 private constant MAX_PLAYERS = 50;
    uint256 private constant MAX_ENTRIES_PER_PLAYER = 5;
    uint256 private constant PROTOCOL_FEE_PERCENTAGE = 5e16;
    uint256 private immutable i_interval;
    uint256 private immutable i_minimumEntranceFeeInUSD;
    uint256 private s_totalFeeCollected;
    uint256 private s_lastTimeStamp;
    uint256 private s_totalEthValue;
    uint256 private s_ethValueOfCurrentRound;
    uint256 private s_currentRoundId;
    uint256 private s_totalEntriesCurrentRound;
    uint256 private s_numberOfPlayersInARound;
    LotteryState private s_lotteryState;
    bool private s_withdrawPrizeToAnAddressState;
    address private s_recentWinner;
    address payable[] private s_players;
    mapping(address => uint256) private s_winnersPrize;
    mapping(uint256 => mapping(address => uint256)) private s_entriesPerRoundPerPlayer;

    /* Events */

    /**
     * @dev Emitted when a winner is chosen.
     * @param player The winner address.
     */
    event WinnerPicked(address indexed player);

    /**
     * @dev Emitted when a VRF request for a lottery winner is made.
     * @param requestId The Chainlink VRF request id.
     */
    event RequestedLotteryWinner(uint256 indexed requestId);

    /**
     * @dev Emitted when a prize is sent (or withdrawn) to an address.
     * @param player The recipient of the prize.
     * @param amount The amount of wei sent.
     */
    event PrizeSent(address indexed player, uint256 indexed amount);

    /**
     * @dev Emitted when a player enters the lottery.
     * @param player The entering player's address.
     * @param numberOfEntries Number of entries the player purchased this round.
     */
    event LotteryEntered(address indexed player, uint256 numberOfEntries);

    /**
     * @dev Emitted when protocol fees are withdrawn by the owner.
     * @param Owner Owner who withdrew.
     * @param amount Amount withdrawn in wei.
     */
    event FeeWithdrawn(address indexed Owner, uint256 amount);

    /**
     * @dev Emitted when withdrawing the prize to an address other than the winner is enabled.
     * @param withdrawPrizeToAnAddress True means withdrawing the prize to an address other than the winner is enabled.
     */
    event WitdharToAnAddressEnabled(bool withdrawPrizeToAnAddress);

    /* Functions */

    /**
     * @notice Deploys the Lottery contract.
     * @dev Initializes Chainlink VRF/price feed variables and sets the initial owner via Ownable.
     * @param subscriptionId Chainlink VRF v2 subscription id.
     * @param gasLane The keyHash / gas lane for VRF.
     * @param interval Time interval (in seconds) between lotteries checked by keepers.
     * @param minimumEntranceFeeInUSD Entrance fee in USD (with 8 decimals, matching Aggregator decimals).
     * @param callbackGasLimit Callback gas limit for VRF fulfillRandomWords.
     * @param vrfCoordinatorV2 Address of the VRFCoordinatorV2 contract.
     * @param priceFeed Address of the Chainlink AggregatorV3Interface price feed (ETH/USD).
     */
    constructor(
        uint64 subscriptionId,
        bytes32 gasLane, // keyHash
        uint256 interval,
        uint256 minimumEntranceFeeInUSD, // Should be in USD with 8 decimals
        uint32 callbackGasLimit,
        address vrfCoordinatorV2,
        address priceFeed
    ) VRFConsumerBaseV2(vrfCoordinatorV2) {
        i_vrfCoordinator = VRFCoordinatorV2Interface(vrfCoordinatorV2);
        i_priceFeed = AggregatorV3Interface(priceFeed);
        i_gasLane = gasLane;
        i_interval = interval;
        i_subscriptionId = subscriptionId;
        i_minimumEntranceFeeInUSD = minimumEntranceFeeInUSD; // has 8 decimals
        s_lotteryState = LotteryState.OPEN;
        s_lastTimeStamp = block.timestamp;
        i_callbackGasLimit = callbackGasLimit;
        s_currentRoundId = 1;
        s_withdrawPrizeToAnAddressState = false;
    }

    /**
     * @notice Enter the lottery by sending ETH.
     * @dev Each player may enter with multiple entries (up to 5) and 50 players per round.
     *      Excess ETH (less than a full entry) is returned.
     *      Requires lottery to be OPEN. Reverts on failure conditions documented in custom errors.
     *
     * Emits {LotteryEntered}.
     */
    function enterLottery() external payable nonReentrant {
        // Limit max players and entries per player per round
        if (s_lotteryState != LotteryState.OPEN) {
            revert Lottery__LotteryNotOpen();
        }

        if (s_numberOfPlayersInARound >= MAX_PLAYERS) {
            revert Lottery__LotteryIsFull();
        }

        uint256 totalEthSent = msg.value;
        uint256 minimumEthAmount = getMinimumEthAmountToEnter();

        if (totalEthSent < minimumEthAmount) {
            revert Lottery__SendMoreToEnterLottery();
        }

        if (s_entriesPerRoundPerPlayer[s_currentRoundId][msg.sender] > 0) {
            revert Lottery__PlayerAlreadyEntered();
        }

        uint256 totalEntries = totalEthSent / minimumEthAmount;

        if (totalEntries > MAX_ENTRIES_PER_PLAYER) {
            revert Lottery__MoreThenFiveEntriesNotAllowed();
        }

        uint256 ethToReturn = totalEthSent % minimumEthAmount;
        s_players.push(payable(msg.sender));
        s_totalEthValue += (minimumEthAmount * totalEntries);
        s_ethValueOfCurrentRound += (minimumEthAmount * totalEntries);
        s_entriesPerRoundPerPlayer[s_currentRoundId][msg.sender] = totalEntries;
        s_totalEntriesCurrentRound += totalEntries;
        s_numberOfPlayersInARound++;
        emit LotteryEntered(msg.sender, totalEntries);

        if (ethToReturn > 0) {
            (bool success,) = payable(msg.sender).call{value: ethToReturn}("");
            if (!success) {
                revert Lottery__ReturnAmountTransferFailed();
            }
        }
    }

    /**
     * @notice Called by Chainlink Automation when upkeep is needed.
     * @dev This implementation requests randomness from Chainlink VRF and sets the lottery state to CALCULATING.
     *      Reverts if `checkUpkeep` returns false.
     *
     * Emits {RequestedLotteryWinner}.
     */
    function performUpkeep(bytes calldata /* performData */ ) external override {
        (bool upkeepNeeded,) = checkUpkeep("");
        if (!upkeepNeeded) {
            revert Lottery__UpkeepNotNeeded(address(this).balance, s_players.length, uint256(s_lotteryState));
        }
        s_lotteryState = LotteryState.CALCULATING;
        uint256 requestId = i_vrfCoordinator.requestRandomWords(
            i_gasLane, i_subscriptionId, REQUEST_CONFIRMATIONS, i_callbackGasLimit, NUM_WORDS
        );
        emit RequestedLotteryWinner(requestId);
    }

    /**
     * @notice Set whether the winner can withdraw the lottery prize to an address (time use only).
     *         only meant for special cases i.e. player endered with non payable address.
     * @param enabled True to enable, false to disable.
     */
    function setWithdrawPrizeToAnAddressEnabled(bool enabled) external onlyOwner {
        s_withdrawPrizeToAnAddressState = enabled;
        emit WitdharToAnAddressEnabled(s_withdrawPrizeToAnAddressState);
    }

    /**
     * @notice Get the prize value of the current round.
     * @return Prize value in wei.
     */
    function getPrizeValueOfCurrentRound() external view returns (uint256) {
        uint256 fee = s_ethValueOfCurrentRound * PROTOCOL_FEE_PERCENTAGE / PRECISION;
        return s_ethValueOfCurrentRound - fee;
    }

    /**
     * @notice Withdraw your prize for a round you won.
     * @dev Reverts if lottery is not OPEN, or if caller has no prize.
     *
     * Emits {PrizeSent} on successful withdrawal.
     */
    function withdrawPrize() external nonReentrant {
        if (s_lotteryState != LotteryState.OPEN) {
            revert Lottery__LotteryNotOpen();
        }
        if (s_winnersPrize[msg.sender] == 0) {
            revert Lottery__NoPrizeToWithdraw();
        }

        uint256 prize = s_winnersPrize[msg.sender];

        emit PrizeSent(msg.sender, prize);
        s_winnersPrize[msg.sender] = 0;
        s_totalEthValue -= prize;
        (bool success,) = payable(msg.sender).call{value: prize}("");
        if (!success) {
            revert Lottery__TransferFailed();
        }
    }

    /**
     * @notice Withdraw your prize to a different address (if enabled).
     * @dev Only allowed if `withdrawPrizeToAnAddressState` is true. After one call it disables the feature.
     * @param receiver Address to receive the prize.
     *
     * Emits {PrizeSent} on successful withdrawal.
     */
    function withdrawPrizeToAnAddress(address receiver) external nonReentrant {
        if (!s_withdrawPrizeToAnAddressState) {
            revert Lottery__WithdrawToAnAddressNotEnabled();
        }
        if (receiver == address(0)) {
            revert Lottery__TransferNotAllowedToZeroAddress();
        }
        if (s_lotteryState != LotteryState.OPEN) {
            revert Lottery__LotteryNotOpen();
        }
        if (s_winnersPrize[msg.sender] == 0) {
            revert Lottery__NoPrizeToWithdraw();
        }

        uint256 prize = s_winnersPrize[msg.sender];

        emit PrizeSent(receiver, prize);
        s_winnersPrize[msg.sender] = 0;
        s_totalEthValue -= prize;
        s_withdrawPrizeToAnAddressState = false;
        (bool success,) = payable(receiver).call{value: prize}("");
        if (!success) {
            revert Lottery__TransferFailed();
        }
    }

    /**
     * @notice Withdraw collected protocol fees to the contract owner.
     * @dev Only callable by the owner.
     *
     * Emits {FeeWithdrawn}.
     */
    function withdrawProtocolFee() external nonReentrant onlyOwner {
        if (s_totalFeeCollected == 0) {
            revert Lottery__NoFeeToWithdraw();
        }
        uint256 fee = s_totalFeeCollected;
        s_totalFeeCollected = 0;
        s_totalEthValue -= fee;
        emit FeeWithdrawn(msg.sender, fee);
        (bool success,) = payable(msg.sender).call{value: fee}("");
        if (!success) {
            revert Lottery__TransferFailed();
        }
    }

    /**
     * @notice Convert the configured minimum USD fee to its ETH equivalent using the price feed.
     * @dev Uses `OracleLib.staleCheckLatestRoundData()` which may revert/handle stale feed logic.
     * @return ethAmount ETH amount in wei that corresponds to `i_minimumEntranceFeeInUSD`.
     */
    function getMinimumEthAmountToEnter() public view returns (uint256 ethAmount) {
        (, int256 price,,,) = i_priceFeed.staleCheckLatestRoundData();
        ethAmount = i_minimumEntranceFeeInUSD * PRECISION / uint256(price);
    }

    /**
     * @notice Check whether upkeep is needed for Chainlink Automation.
     * @dev Conditions:
     *       1) Enough time passed since last run.
     *       2) Lottery is OPEN.
     *       3) Players are present.
     *       4) Contract has ETH and players are present.
     * @return upkeepNeeded True if upkeep should be performed.
     * @return performData Currently unused and always returns an empty bytes ("0x0").
     */
    function checkUpkeep(bytes memory /* checkData */ )
        public
        view
        override
        returns (bool upkeepNeeded, bytes memory /* performData */ )
    {
        bool isOpen = LotteryState.OPEN == s_lotteryState;
        bool timePassed = ((block.timestamp - s_lastTimeStamp) > i_interval);
        bool hasPlayers = s_players.length > 0;
        bool hasBalance = address(this).balance > 0;
        upkeepNeeded = (timePassed && isOpen && hasBalance && hasPlayers);
        return (upkeepNeeded, "0x0");
    }

    /**
     * @notice Callback used by Chainlink VRF to deliver randomness and settle the lottery.
     * @dev Picks a winner proportional to entries, charges protocol fee, and resets round state.
     *      Internal function called by VRFCoordinator.
     * @param , Unused requestId parameter as its not mapped to requests.
     * @param randomWords Array of random words returned by VRF (only index 0 is used).
     *
     * Emits {WinnerPicked}.
     */
    function fulfillRandomWords(uint256, /* requestId */ uint256[] memory randomWords) internal override {
        address payable[] memory m_players = s_players;
        uint256 winningTicket = randomWords[0] % s_totalEntriesCurrentRound;
        uint256 cumulative = 0;
        for (uint256 i = 0; i < m_players.length;) {
            cumulative += s_entriesPerRoundPerPlayer[s_currentRoundId][m_players[i]];
            if (winningTicket < cumulative) {
                s_recentWinner = m_players[i];
                break;
            }
            unchecked {
                ++i;
            }
        }
        uint256 fee = s_ethValueOfCurrentRound * PROTOCOL_FEE_PERCENTAGE / PRECISION;
        s_totalFeeCollected += fee;
        s_winnersPrize[s_recentWinner] += (s_ethValueOfCurrentRound - fee);

        // Reset state
        s_players = new address payable[](0);
        s_currentRoundId++;
        s_numberOfPlayersInARound = 0;
        s_lotteryState = LotteryState.OPEN;
        s_lastTimeStamp = block.timestamp;
        s_ethValueOfCurrentRound = 0;
        s_totalEntriesCurrentRound = 0;

        emit WinnerPicked(s_recentWinner);
    }

    /**
     * Getter Functions
     */

    /**
     * @notice Get the current lottery state.
     * @return The LotteryState enum value (OPEN or CALCULATING).
     */
    function getLotteryState() external view returns (LotteryState) {
        return s_lotteryState;
    }

    /**
     * @notice Number of VRF words requested (constant).
     * @return The number of words (NUM_WORDS).
     */
    function getNumWords() external pure returns (uint256) {
        return NUM_WORDS;
    }

    /**
     * @notice Number of confirmations required by the VRF request (constant).
     * @return The request confirmations (REQUEST_CONFIRMATIONS).
     */
    function getRequestConfirmations() external pure returns (uint256) {
        return REQUEST_CONFIRMATIONS;
    }

    /**
     * @notice Address of the most recent winner.
     * @return Address of recent winner.
     */
    function getRecentWinner() external view returns (address) {
        return s_recentWinner;
    }

    /**
     * @notice Get a player by index for the current round.
     * @param index Index into players array.
     * @return Address of the player at `index`.
     */
    function getPlayer(uint256 index) external view returns (address) {
        return s_players[index];
    }

    /**
     * @notice Timestamp of the last lottery run.
     * @return Timestamp in seconds.
     */
    function getLastTimeStamp() external view returns (uint256) {
        return s_lastTimeStamp;
    }

    /**
     * @notice Get the configured time interval between lotteries.
     * @return Interval in seconds.
     */
    function getInterval() external view returns (uint256) {
        return i_interval;
    }

    /**
     * @notice Entrance fee (USD) as configured on deploy.
     * @return Entrance fee in USD (8-decimal convention).
     */
    function getEntranceFee() external view returns (uint256) {
        return i_minimumEntranceFeeInUSD;
    }

    /**
     * @notice Number of active players in the current round.
     * @return Number of players.
     */
    function getNumberOfPlayers() external view returns (uint256) {
        return s_players.length;
    }

    /**
     * @notice The address of the price feed used.
     * @return Price feed contract address.
     */
    function getPriceFeedAddress() external view returns (address) {
        return address(i_priceFeed);
    }

    /**
     * @notice Total ETH value held by the contract (including prizes and fees).
     * @return Total ETH value in wei.
     */
    function getTotalEthValue() external view returns (uint256) {
        return s_totalEthValue;
    }

    /**
     * @notice The Chainlink VRF subscription id used.
     * @return Subscription id.
     */
    function getSubscriptionId() external view returns (uint256) {
        return i_subscriptionId;
    }

    /**
     * @notice The gas lane (key hash) used for VRF requests.
     * @return Gas lane / keyHash as bytes32.
     */
    function getGasLane() external view returns (bytes32) {
        return i_gasLane;
    }

    /**
     * @notice The callback gas limit configured for VRF fulfillRandomWords.
     * @return Callback gas limit in gas units.
     */
    function getCallbackGasLimit() external view returns (uint256) {
        return i_callbackGasLimit;
    }

    /**
     * @notice Address of the VRFCoordinatorV2 used.
     * @return Address of the VRFCoordinator.
     */
    function getVrfCoordinatorV2() external view returns (address) {
        return address(i_vrfCoordinator);
    }

    /**
     * @notice The PRECISION constant used for internal math (1e18).
     * @return Precision constant.
     */
    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    /**
     * @notice Current lottery round id.
     * @return Current round id.
     */
    function getCurrentRoundId() external view returns (uint256) {
        return s_currentRoundId;
    }

    /**
     * @notice Returns the configured timeout value of the price feed (via OracleLib).
     * @return Price feed timeout in seconds.
     */
    function getTimeOutLimit() external view returns (uint256) {
        return i_priceFeed.getTimeout();
    }

    /**
     * @notice Returns how many entries a `player` has in a given `roundId`.
     * @param roundId The round to query.
     * @param player The player address.
     * @return Number of entries the player has for the round.
     */
    function getEntriesPerPlayer(uint256 roundId, address player) external view returns (uint256) {
        return s_entriesPerRoundPerPlayer[roundId][player];
    }

    /**
     * @notice Returns the protocol fee percentage taken from the prize pool.
     * @dev This value is a constant expressed with 18 decimals (e.g., 5e16 = 5%).
     */
    function getProtocolFeePercentage() external pure returns (uint256) {
        return PROTOCOL_FEE_PERCENTAGE;
    }

    /**
     * @notice Returns the total fee amount collected by the protocol so far.
     * @dev Value is in wei and increases with each lottery round's collected fees.
     */
    function getTotalFeeCollected() external view returns (uint256) {
        return s_totalFeeCollected;
    }

    /**
     * @notice Returns the total ETH value accumulated in the current round.
     * @dev Value is in wei and resets at the start of a new round.
     */
    function getEthValueOfCurrentRound() external view returns (uint256) {
        return s_ethValueOfCurrentRound;
    }

    /**
     * @notice Returns the number of players currently participating in the ongoing round.
     * @dev This count resets at the start of each round.
     */
    function getNumberOfPlayersInCurrentRound() external view returns (uint256) {
        return s_numberOfPlayersInARound;
    }

    /**
     * @notice Returns the state flag for allowing prize withdrawal to a specific address.
     * @dev True means withdrawing the prize to an address other than the winner is enabled.
     */
    function getWithdrawPrizeToAnAddressState() external view returns (bool) {
        return s_withdrawPrizeToAnAddressState;
    }

    /**
     * @notice Returns the prize amount assigned to a specific player.
     * @param player The address of the player whose prize amount is being queried.
     * @dev Value is in wei and is available only if the player has won a prize in a past round
     *      and hasn't been withdrawn yet.
     */
    function getWinnerPrize(address player) external view returns (uint256) {
        return s_winnersPrize[player];
    }

    /**
     * @notice Returns the total number of entries in the current round.
     * @dev Value is in wei and resets at the start of a new round.
     */
    function getTotalEntriesCurrentRound() external view returns (uint256) {
        return s_totalEntriesCurrentRound;
    }
}
