// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2} from "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title Decentralized Raffle Contract
 * @author 0xusman
 * @notice This contract is unaudited and should not be used in production.
 * This is for demonstration purposes only
 * @dev This implements the Chainlink VRF Version 2
 */
contract Raffle is VRFConsumerBaseV2, AutomationCompatibleInterface {
    /* Errors */
    error Raffle__UpkeepNotNeeded(uint256 currentBalance, uint256 numPlayers, uint256 raffleState);
    error Raffle__TransferFailed();
    error Raffle__SendMoreToEnterRaffle();
    error Raffle__RaffleNotOpen();
    error Raffle__PlayerAlreadyEntered();

    /* TYPE DECLARATIONS */
    enum RaffleState {
        OPEN,
        CALCULATING
    }

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
    uint256 private immutable i_entranceFee;
    uint256 private s_lastTimeStamp;
    address private s_recentWinner;
    address payable[] private s_players;
    RaffleState private s_raffleState;
    uint256 private s_totalEthValue;
    uint256 private s_currentRoundId;
    mapping(address => uint256) private s_isEntered;

    /* Events */
    event RequestedRaffleWinner(uint256 indexed requestId);
    event RaffleEntered(address indexed player);
    event WinnerPicked(address indexed player);

    /* Functions */
    constructor(
        uint64 subscriptionId,
        bytes32 gasLane, // keyHash
        uint256 interval,
        uint256 entranceFee, // Should be in USD with 8 decimals
        uint32 callbackGasLimit,
        address vrfCoordinatorV2,
        address priceFeed
    ) VRFConsumerBaseV2(vrfCoordinatorV2) {
        i_vrfCoordinator = VRFCoordinatorV2Interface(vrfCoordinatorV2);
        i_priceFeed = AggregatorV3Interface(priceFeed);
        i_gasLane = gasLane;
        i_interval = interval;
        i_subscriptionId = subscriptionId;
        i_entranceFee = entranceFee;
        s_raffleState = RaffleState.OPEN;
        s_lastTimeStamp = block.timestamp;
        i_callbackGasLimit = callbackGasLimit;
        s_currentRoundId = 1;
    }

    /**
     * @dev This is the function users will call with Eth to enter the raffle
     */
    function enterRaffle() external payable {
        if (getUsdAmountFromEth(msg.value) < i_entranceFee) {
            revert Raffle__SendMoreToEnterRaffle();
        }
        if (s_raffleState != RaffleState.OPEN) {
            revert Raffle__RaffleNotOpen();
        }
        if (s_isEntered[msg.sender] == s_currentRoundId) {
            revert Raffle__PlayerAlreadyEntered();
        }

        // Implement a fee feature
        s_isEntered[msg.sender]++;
        s_players.push(payable(msg.sender));
        s_totalEthValue += msg.value;
        emit RaffleEntered(msg.sender);
    }

    /**
     * @dev Once `checkUpkeep` is returning `true`, this function is called
     * and it kicks off a Chainlink VRF call to get a random winner.
     */
    function performUpkeep(bytes calldata /* performData */ ) external override {
        (bool upkeepNeeded,) = checkUpkeep("");
        if (!upkeepNeeded) {
            revert Raffle__UpkeepNotNeeded(address(this).balance, s_players.length, uint256(s_raffleState));
        }
        s_raffleState = RaffleState.CALCULATING;
        uint256 requestId = i_vrfCoordinator.requestRandomWords(
            i_gasLane, i_subscriptionId, REQUEST_CONFIRMATIONS, i_callbackGasLimit, NUM_WORDS
        );
        emit RequestedRaffleWinner(requestId);
    }

    /**
     * @notice This is the function that will use
     * Chainlink price feed to convert Eth to its Usd value
     * @param valueInEth is the Eth value
     * @return valueInUsd returns USD value of Eth, USD value has 8 decimals.
     */
    function getUsdAmountFromEth(uint256 valueInEth) public view returns (uint256 valueInUsd) {
        (, int256 price,,,) = i_priceFeed.latestRoundData();
        valueInUsd = valueInEth * uint256(price) / PRECISION;
    }

    /**
     * @dev This is the function that the Chainlink Keeper nodes call
     * they look for `upkeepNeeded` to return True.
     * the following should be true for this to return true:
     * 1. The time interval has passed between raffle runs.
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
        bool isOpen = RaffleState.OPEN == s_raffleState;
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
        //s_players = new address payable[](0);
        delete s_players;
        // Reset mapping
        s_currentRoundId++;
        s_raffleState = RaffleState.OPEN;
        s_lastTimeStamp = block.timestamp;
        s_totalEthValue = 0;
        (bool success,) = recentWinner.call{value: address(this).balance}("");
        // require(success, "Transfer failed");
        if (!success) {
            revert Raffle__TransferFailed();
        }
        emit WinnerPicked(recentWinner);
    }

    /**
     * Getter Functions
     */
    function getRaffleState() external view returns (RaffleState) {
        return s_raffleState;
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
        return i_entranceFee;
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

    function getPricion() external pure returns (uint256) {
        return PRECISION;
    }

    function getCurrentRoundId() external view returns (uint256) {
        return s_currentRoundId;
    }

    function getIsEntered(address player) external view returns (bool) {
        return s_isEntered[player] == s_currentRoundId;
    }
}
