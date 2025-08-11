// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {Lottery} from "../src/Lottery.sol";
import {AddConsumer, CreateSubscription, FundSubscription} from "./Interactions.s.sol";

contract DeployLottery is Script {
    function run() external returns (Lottery, HelperConfig, uint64) {
        HelperConfig helperConfig = new HelperConfig(); // This comes with our mocks!
        AddConsumer addConsumer = new AddConsumer();
        (
            uint64 subscriptionId,
            bytes32 gasLane,
            uint256 automationUpdateInterval,
            uint256 lotteryEntranceFee,
            uint32 callbackGasLimit,
            address vrfCoordinatorV2,
            address link,
            uint256 deployerKey,
            address priceFeed
        ) = helperConfig.activeNetworkConfig();

        if (subscriptionId == 0) {
            CreateSubscription createSubscription = new CreateSubscription();
            subscriptionId = createSubscription.createSubscription(vrfCoordinatorV2, deployerKey);

            FundSubscription fundSubscription = new FundSubscription();
            fundSubscription.fundSubscription(vrfCoordinatorV2, subscriptionId, link, deployerKey);
        }

        vm.startBroadcast(deployerKey);
        Lottery lottery = new Lottery(
            subscriptionId,
            gasLane,
            automationUpdateInterval,
            lotteryEntranceFee,
            callbackGasLimit,
            vrfCoordinatorV2,
            priceFeed
        );
        vm.stopBroadcast();

        // We already have a broadcast in here
        addConsumer.addConsumer(address(lottery), vrfCoordinatorV2, subscriptionId, deployerKey);
        return (lottery, helperConfig, subscriptionId);
    }
}
