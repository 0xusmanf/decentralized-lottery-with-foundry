<!-- @format -->

### Disclaimer: This is an **unaudited** project made for skill demonstration purposes. **DO NOT USE IN PRODUCTION.**

# Decentralized Lottery

![Foundry Tests](https://img.shields.io/badge/Foundry-Tests%20Passing-brightgreen)
![Solidity](https://img.shields.io/badge/Solidity-v0.8.20-blue)
![License](https://img.shields.io/badge/License-MIT-green)

A **provably fair**, **automated**, and **decentralized** lottery smart contract for Ethereum.  
Built with [Foundry](https://book.getfoundry.sh/) and powered by [Chainlink VRF](https://docs.chain.link/vrf), [Chainlink Automation](https://docs.chain.link/chainlink-automation/introduction), and [Chainlink Price Feeds](https://docs.chain.link/data-feeds/price-feeds).  

This project started as the [Cyfrin Foundry Smart Contract Lottery](https://github.com/Cyfrin/foundry-smart-contract-lottery-cu) from the *Cyfrin Updraft* course, then evolved with new features, improved architecture, and more robust testing.


## 🚀 Improvements Over the Original Cyfrin Starter

**Core Changes**
- **Multi-entry per player** — 1–5 entries allowed per player per round.
- **Max player cap** — up to 50 players per round.
- **Protocol fee** — 5% fee on the prize pool, withdrawable by the owner.
- **Prize accounting** — winnings tracked per address; winners withdraw manually.
- **Withdraw-to-an-address** — owner can temporarily enable winners to withdraw to another address.
- **Stale price protection** — via `OracleLib` (3h Chainlink price feed timeout).
- **Expanded getters & events** — better front-end and analytics integration.

**Technical / Dev Changes**
- Modular deployment scripts for:
  - Creating/funding VRF subscriptions
  - Adding lottery contract as VRF consumer
  - Local mock deployment for testing
- More extensive event logging:
  - `LotteryEntered`
  - `RequestedLotteryWinner`
  - `WinnerPicked`
  - `PrizeSent`
  - `FeeWithdrawn`
- Improved test suite with Foundry:
  - Unit tests for core flows
  - Upkeep & VRF fulfillment testing
  - Stale oracle handling
  - Getter coverage

## 📜 How It Works

The lottery runs in **rounds** managed by a simple state machine:

1. **Open State**
   - Players call `enterLottery()` with ETH worth 1–5 entries.
   - ETH value for entries is calculated from USD fee via Chainlink Price Feed.
   - Entry refunds excess ETH (if sent).
   - Max 50 players per round.

2. **Automation Trigger**
   - Chainlink Automation monitors for:
     - Enough time passed (`interval`)
     - At least one player
     - Contract in `OPEN` state
   - Calls `performUpkeep()` when conditions met.

3. **Calculating State**
   - `performUpkeep()` requests randomness from Chainlink VRF v2.

4. **Winner Selection**
   - VRF response triggers `fulfillRandomWords()`.
   - Winner chosen proportional to number of entries.
   - Protocol fee deducted; prize assigned to winner mapping.

5. **Prize Withdrawal**
   - Winner calls `withdrawPrize()` to claim.
   - Owner can call `withdrawProtocolFee()` to collect fees.
   - Special: Owner can enable `withdrawPrizeToAnAddress()` for non-payable winner addresses.

## 🔑 Key Features

- **Provably fair randomness** via Chainlink VRF v2.
- **Decentralized automation** with Chainlink Automation (Keepers).
- **Stable USD-denominated entry fee** with ETH conversion via Chainlink Price Feeds.
- **Gas-efficient design** using custom errors and modern Solidity patterns.
- **Extensive events & getters** for easy UI integration.
- **Advanced Foundry testing**:
  - Unit testing
  - Fuzz testing
  - Intigration testing
  - Invariant testing (In progress)

## Getting Started

### Prerequisites

- [git](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git)
  - You'll know you did it right if you can run `git --version` and you see a response like `git version x.x.x`
- [foundry](https://getfoundry.sh/)
  - You'll know you did it right if you can run `forge --version` and you see a response like `forge 0.2.0 (816e00b 2023-03-16T00:05:26.396218Z)`

## Quickstart

```
git clone https://github.com/0xusmanf/decentralized-lottery-with-foundry
cd decentralized-lottery-with-foundry
forge build
```

### Optional Gitpod

If you can't or don't want to run and install locally, you can work with this repo in Gitpod. If you do this, you can skip the `clone this repo` part.

[![Open in Gitpod](https://gitpod.io/button/open-in-gitpod.svg)](https://gitpod.io/#github.com/ChainAccelOrg/foundry-smart-contract-lottery-f23)

# Usage

## Start a local node

```
make anvil
```

## Library

If you're having a hard time installing the chainlink library, you can optionally run this command. 

```
forge install smartcontractkit/chainlink-brownie-contracts@0.6.1
```

## Deploy

This will default to your local node. You need to have it running in another terminal in order for it to deploy.

```
make deploy
```

## Deploy - Other Network

[See below](#deployment-to-a-testnet-or-mainnet)

## Testing

```
forge test
```

or

```
forge test --fork-url $SEPOLIA_RPC_URL
```

### Test Coverage

```
forge coverage
```

# Deployment to a testnet

1. Setup environment variables

You'll want to set your `SEPOLIA_RPC_URL` and `PRIVATE_KEY` as environment variables. You can add them to a `.env` file, similar to what you see in `.env.example`.

- `PRIVATE_KEY`: The private key of your account (like from [metamask](https://metamask.io/)). **NOTE:** FOR DEVELOPMENT, PLEASE USE A KEY THAT DOESN'T HAVE ANY REAL FUNDS ASSOCIATED WITH IT.
  - You can [learn how to export it here](https://metamask.zendesk.com/hc/en-us/articles/360015289632-How-to-Export-an-Account-Private-Key).
- `SEPOLIA_RPC_URL`: This is url of the sepolia testnet node you're working with. You can get setup with one for free from [Alchemy](https://alchemy.com/?a=673c802981)

Optionally, add your `ETHERSCAN_API_KEY` if you want to verify your contract on [Etherscan](https://etherscan.io/).

1. Get testnet ETH

Head over to [faucets.chain.link](https://faucets.chain.link/) and get some testnet ETH. You should see the ETH show up in your metamask.

2. Deploy

```
make deploy ARGS="--network sepolia"
```

This will setup a ChainlinkVRF Subscription for you. If you already have one, update it in the `scripts/HelperConfig.s.sol` file. It will also automatically add your contract as a consumer.

3. Register a Chainlink Automation Upkeep

[You can follow the documentation if you get lost.](https://docs.chain.link/chainlink-automation/compatible-contracts)

Go to [automation.chain.link](https://automation.chain.link/new) and register a new upkeep. Choose `Custom logic` as your trigger mechanism for automation.

## Scripts

After deploying to a testnet or local net, you can run the scripts.

Using cast deployed locally example:

```
cast send <RAFFLE_CONTRACT_ADDRESS> "enterLottery()" --value 0.1ether --private-key <PRIVATE_KEY> --rpc-url $SEPOLIA_RPC_URL
```

or, to create a ChainlinkVRF Subscription:

```
make createSubscription ARGS="--network sepolia"
```

## Estimate gas

You can estimate how much gas things cost by running:

```
forge snapshot
```

And you'll see an output file called `.gas-snapshot`

# Formatting

To run code formatting:

```
forge fmt
```

# Thank you!
