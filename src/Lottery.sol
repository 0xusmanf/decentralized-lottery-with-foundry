// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2} from "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title Decentralized Lottery
 * @author 0xusmanf
 * @notice This contract is unaudited and should not be used in production.
 * This is for demonstration purposes only
 * @dev This implements the Chainlink VRF Version 2, Automation and Price Feed.
 */
contract Lottery is VRFConsumerBaseV2, AutomationCompatibleInterface {
    /* Errors */
    error Lottery__UpkeepNotNeeded(uint256 currentBalance, uint256 numPlayers, uint256 LotteryState);
    error Lottery__TransferFailed();
    error Lottery__SendMoreToEnterLottery();
    error Lottery__LotteryNotOpen();
    error Lottery__PlayerAlreadyEntered();
    error Lottery__NoPrizeToWithdraw();
    error Lottery__ReturnAmountTransferFailed();

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
    uint256 private immutable i_interval;
    uint256 private immutable i_minimumEntranceFeeInUSD;
    uint256 private s_lastTimeStamp;
    address private s_recentWinner;
    address payable[] private s_players;
    LotteryState private s_lotteryState;
    uint256 private s_totalEthValue;
    uint256 private s_ethValueOfCurrentRound;
    uint256 private s_currentRoundId;
    mapping(address => uint256) private s_winnersPrize;
    mapping(address => uint256) private s_hasEntered;
    mapping(address => uint256) private s_entriesPerPlayer;

    /* Events */
    event RequestedLotteryWinner(uint256 indexed requestId);
    event LotteryEntered(address indexed player);
    event WinnerPicked(address indexed player);
    event PrizeSent(address indexed player, uint256 indexed amount);

    /* Functions */
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
    }

    /**
     * @dev This is the function users will call with Eth to enter the lottery
     */
    function enterLottery() external payable {
        uint256 totalEthSent = msg.value;
        uint256 minimumEthAmount = getMinimumEthAmountToEnter();
        if (totalEthSent < minimumEthAmount) {
            revert Lottery__SendMoreToEnterLottery();
        }
        if (s_lotteryState != LotteryState.OPEN) {
            revert Lottery__LotteryNotOpen();
        }
        if (s_hasEntered[msg.sender] == s_currentRoundId) {
            revert Lottery__PlayerAlreadyEntered();
        }

        uint256 totalEntries = totalEthSent / minimumEthAmount;
        uint256 ethToReturn = totalEthSent % minimumEthAmount;

        // Implement a fee feature
        s_hasEntered[msg.sender] = s_currentRoundId;
        if (totalEntries > 1) {
            for (uint256 i = 1; i < totalEntries;) {
                s_players.push(payable(msg.sender));
                unchecked {
                    i += 1;
                }
            }
        }
        s_players.push(payable(msg.sender));
        s_totalEthValue += (minimumEthAmount * totalEntries);
        s_ethValueOfCurrentRound += (minimumEthAmount * totalEntries);
        s_entriesPerPlayer[msg.sender] = totalEntries;
        emit LotteryEntered(msg.sender);

        if (ethToReturn > 0) {
            (bool success,) = payable(msg.sender).call{value: ethToReturn}("");
            if (!success) {
                revert Lottery__ReturnAmountTransferFailed();
            }
        }
    }

    /**
     * @dev Once `checkUpkeep` is returning `true`, this function is called
     * and it kicks off a Chainlink VRF call to get a random winner.
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
     * @notice This is the function that will use
     * Chainlink price feed to convert i_minimumEntranceFeeInUSD from usd to its Eth value
     * @return ethAmount returns ETH value of i_minimumEntranceFeeInUSD.
     */
    function getMinimumEthAmountToEnter() public view returns (uint256 ethAmount) {
        (, int256 price,,,) = i_priceFeed.staleCheckLatestRoundData();
        ethAmount = i_minimumEntranceFeeInUSD * PRECISION / uint256(price);
    }

    /**
     * @dev This is the function that the Chainlink Keeper nodes call
     * they look for `upkeepNeeded` to return True.
     * the following should be true for this to return true:
     * 1. The time interval has passed between lottery runs.
     * 2. The lottery is open.
     * 3. The contract has ETH.
     * 4. Implicity, your subscription is funded with LINK.
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
        return (upkeepNeeded, "0x0"); // you dont neccessarily need to return anything as it will automatically return
    }

    /**
     * @dev This is the function that Chainlink VRF node
     * calls to send the money to the random winner.
     */
    function fulfillRandomWords(uint256, /* requestId */ uint256[] memory randomWords) internal override {
        uint256 indexOfWinner = randomWords[0] % s_players.length;
        address payable recentWinner = s_players[indexOfWinner];
        s_recentWinner = recentWinner;
        s_winnersPrize[recentWinner] += s_ethValueOfCurrentRound;

        // Reset state
        delete s_players;
        s_currentRoundId++;
        s_lotteryState = LotteryState.OPEN;
        s_lastTimeStamp = block.timestamp;
        s_ethValueOfCurrentRound = 0;

        emit WinnerPicked(recentWinner);
    }

    /**
     * @dev This is the function that users will call to withdraw their prize
     */
    function withdrawPrize() external {
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
     * Getter Functions
     */
    function getLotteryState() external view returns (LotteryState) {
        return s_lotteryState;
    }

    function getNumWords() external pure returns (uint256) {
        return NUM_WORDS;
    }

    function getRequestConfirmations() external pure returns (uint256) {
        return REQUEST_CONFIRMATIONS;
    }

    function getRecentWinner() external view returns (address) {
        return s_recentWinner;
    }

    function getPlayer(uint256 index) external view returns (address) {
        return s_players[index];
    }

    function getLastTimeStamp() external view returns (uint256) {
        return s_lastTimeStamp;
    }

    function getInterval() external view returns (uint256) {
        return i_interval;
    }

    function getEntranceFee() external view returns (uint256) {
        return i_minimumEntranceFeeInUSD;
    }

    function getNumberOfPlayers() external view returns (uint256) {
        return s_players.length;
    }

    function getPriceFeedAddress() external view returns (address) {
        return address(i_priceFeed);
    }

    function getTotalEthValue() external view returns (uint256) {
        return s_totalEthValue;
    }

    function getSubscriptionId() external view returns (uint256) {
        return i_subscriptionId;
    }

    function getGasLane() external view returns (bytes32) {
        return i_gasLane;
    }

    function getCallbackGasLimit() external view returns (uint256) {
        return i_callbackGasLimit;
    }

    function getVrfCoordinatorV2() external view returns (address) {
        return address(i_vrfCoordinator);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getCurrentRoundId() external view returns (uint256) {
        return s_currentRoundId;
    }

    function getIsEntered(address player) external view returns (bool) {
        return s_hasEntered[player] == s_currentRoundId;
    }

    function getTimeOutLimit() external view returns (uint256) {
        return i_priceFeed.getTimeout();
    }

    function getEntriesPerPlayer(address player) external view returns (uint256) {
        return s_entriesPerPlayer[player];
    }
}
