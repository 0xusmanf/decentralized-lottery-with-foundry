// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {Lottery} from "../src/Lottery.sol";
import {DevOpsTools} from "../lib/foundry-devops/src/DevOpsTools.sol";
import {VRFCoordinatorV2Mock} from "../test/mocks/VRFCoordinatorV2Mock.sol";
import {LinkToken} from "../test/mocks/LinkToken.sol";

contract CreateSubscription is Script {
    function createSubscriptionUsingConfig() public returns (uint64) {
        HelperConfig helperConfig = new HelperConfig();
        (,,,,, address vrfCoordinatorV2,, uint256 deployerKey,) = helperConfig.activeNetworkConfig();
        return createSubscription(vrfCoordinatorV2, deployerKey);
    }

    /**
     * @dev This is added to exclude this contract from coverage.
     */
    function testExclude() public {}

    function createSubscription(address vrfCoordinatorV2, uint256 deployerKey) public returns (uint64) {
        console.log("Creating subscription on chainId: %d", block.chainid);
        vm.startBroadcast(deployerKey);
        uint64 subId = VRFCoordinatorV2Mock(vrfCoordinatorV2).createSubscription();
        vm.stopBroadcast();
        console.log("Your subscription Id is: %d", subId);
        console.log("Please update the subscriptionId in HelperConfig.s.sol");
        return subId;
    }

    function run() external returns (uint64) {
        return createSubscriptionUsingConfig();
    }
}

contract AddConsumer is Script {
    /**
     * @dev This is added to exclude this contract from coverage.
     */
    function testExclude() public {}

    function addConsumer(address contractToAddToVrf, address vrfCoordinator, uint64 subId, uint256 deployerKey)
        public
    {
        console.log("Adding consumer contract: ", contractToAddToVrf);
        console.log("Using vrfCoordinator: ", vrfCoordinator);
        console.log("On ChainID: %d", block.chainid);
        vm.startBroadcast(deployerKey);
        VRFCoordinatorV2Mock(vrfCoordinator).addConsumer(subId, contractToAddToVrf);
        vm.stopBroadcast();
    }

    function addConsumerUsingConfig(address mostRecentlyDeployed) public {
        HelperConfig helperConfig = new HelperConfig();
        (uint64 subId,,,,, address vrfCoordinatorV2,, uint256 deployerKey,) = helperConfig.activeNetworkConfig();
        addConsumer(mostRecentlyDeployed, vrfCoordinatorV2, subId, deployerKey);
    }

    function run() external {
        address mostRecentlyDeployed = DevOpsTools.get_most_recent_deployment("Lottery", block.chainid);
        addConsumerUsingConfig(mostRecentlyDeployed);
    }
}

contract FundSubscription is Script {
    /**
     * @dev This is added to exclude this contract from coverage.
     */
    function testExclude() public {}

    uint96 public constant FUND_AMOUNT = 3 ether;

    function fundSubscriptionUsingConfig() public {
        HelperConfig helperConfig = new HelperConfig();
        (uint64 subId,,,,, address vrfCoordinatorV2, address link, uint256 deployerKey,) =
            helperConfig.activeNetworkConfig();
        fundSubscription(vrfCoordinatorV2, subId, link, deployerKey);
    }

    function fundSubscription(address vrfCoordinatorV2, uint64 subId, address link, uint256 deployerKey) public {
        console.log("Funding subscription: ", subId);
        console.log("Using vrfCoordinator: ", vrfCoordinatorV2);
        console.log("On ChainID: %d", block.chainid);
        if (block.chainid == 31337) {
            vm.startBroadcast(deployerKey);
            VRFCoordinatorV2Mock(vrfCoordinatorV2).fundSubscription(subId, FUND_AMOUNT);
            vm.stopBroadcast();
        } else {
            console.log(LinkToken(link).balanceOf(msg.sender));
            console.log(msg.sender);
            console.log(LinkToken(link).balanceOf(address(this)));
            console.log(address(this));
            vm.startBroadcast(deployerKey);
            LinkToken(link).transferAndCall(vrfCoordinatorV2, FUND_AMOUNT, abi.encode(subId));
            vm.stopBroadcast();
        }
    }

    function run() external {
        fundSubscriptionUsingConfig();
    }
}
