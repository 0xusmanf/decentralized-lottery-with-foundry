<!-- @format -->

### Disclaimer: This is an unaudited project made for skill demonstration purposes, DO NOT USE IT IN PRODUCTION.

# Decentralized Raffle Smart Contract

![Foundry Tests](https://img.shields.io/badge/Foundry-Tests%20Passing-brightgreen) ![Solidity](https://img.shields.io/badge/Solidity-v0.8.19-blue) ![License](https://img.shields.io/badge/License-MIT-green)

A provably fair, automated, and decentralized smart contract for running a raffle or lottery on the Ethereum blockchain. This project leverages industry-standard tools like Foundry for development and testing, and integrates Chainlink's suite of oracle services to ensure security and reliability without a centralized operator.

This project is designed to demonstrate a comprehensive understanding of the full smart contract development lifecycle, from initial design and robust testing to deployment and on-chain interaction.

## How It Works

The raffle operates in a simple, cyclical state machine managed by code, time, and external triggers, ensuring fairness and transparency.

1.  **Open State**: Players can enter the raffle by calling the `enterRaffle()` function and paying the minimum entrance fee in ETH. The contract uses Chainlink Price Feeds to accurately calculate the equivalent ETH amount for a fixed USD fee.
2.  **Automation Trigger**: Chainlink Automation (formerly Keepers) continuously monitors the contract. Once a predefined time interval has passed since the last raffle, the Automation network calls the `performUpkeep()` function.
3.  **Calculating State**: The contract transitions to a `CALCULATING` state. `performUpkeep()` requests a provably random number from the Chainlink VRF (Verifiable Random Function) v2 coordinator.
4.  **Winner Selection**: The Chainlink VRF coordinator provides a truly random number back to the contract via the `fulfillRandomWords()` callback function. This function uses the random number to select a winner from the array of participants.
5.  **Prize Distribution & Reset**: The contract automatically transfers the entire prize pool to the winner's address. It then resets its state back to `OPEN` for the next round, updating the timestamp and clearing the list of players.

## Key Features

This project demonstrates proficiency in several key areas of smart contract development:

*   **Provably Fair Randomness**: By using **Chainlink VRF v2**, the winner selection is cryptographically secure and verifiable on-chain, preventing any form of manipulation by the contract owner or oracle operators.
*   **Decentralized Automation**: The raffle is fully automated via **Chainlink Automation**. This removes the need for a centralized admin to manually trigger winner selection, reducing operational risk and enhancing decentralization.
*   **Stable Value Entry Fee**: Integrates **Chainlink Price Feeds** to allow the entry fee to be denominated in USD while being paid in ETH, protecting users from ETH price volatility.
*   **Advanced Testing with Foundry**:
    *   **Unit Testing**: Core functions are validated with precise and isolated tests.
    *   **Fuzz Testing**: The contract is hardened against unexpected inputs by running property-based tests with a wide range of random data, ensuring resilience and security.
    *   **Fork Testing**: Tests are run on a fork of a live testnet to ensure correct interaction with real-world contracts.
*   **Modern Solidity Practices**: Written in Solidity v0.8.19, incorporating custom errors for gas efficiency and a clear C-style contract layout.
*   **Robust Scripting**: Deployment and interaction are managed through modular scripts within the Foundry framework, allowing for repeatable and reliable contract management.

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
cast send <RAFFLE_CONTRACT_ADDRESS> "enterRaffle()" --value 0.1ether --private-key <PRIVATE_KEY> --rpc-url $SEPOLIA_RPC_URL
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
