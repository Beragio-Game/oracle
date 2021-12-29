import { task } from "hardhat/config";
import { CombinedHRE } from "./types";
const assert = require("assert");

task("setup-l1-arbitrum-xchain", "Configures L1 cross chain smart contracts for Arbitrum bridge").setAction(
  async function (_, hre_) {
    const hre = hre_ as CombinedHRE;
    const { deployments, getNamedAccounts, web3, companionNetworks } = hre;
    const { toBN } = web3.utils;
    const { deployer } = await getNamedAccounts();

    const ParentMessenger = await deployments.get("Arbitrum_ParentMessenger");
    const messenger = new web3.eth.Contract(ParentMessenger.abi, ParentMessenger.address);
    const OracleHub = await deployments.get("OracleHub");
    const oracleHub = new web3.eth.Contract(OracleHub.abi, OracleHub.address);
    const GovernorHub = await deployments.get("GovernorHub");
    const governorHub = new web3.eth.Contract(GovernorHub.abi, GovernorHub.address);

    console.log(`Found ParentMessenger @ ${messenger.options.address}`);
    console.log(`Found OracleHub @ ${oracleHub.options.address}`);
    console.log(`Found GovernorHub @ ${governorHub.options.address}`);

    const OracleSpoke = await companionNetworks.arbitrum.deployments.get("OracleSpoke");
    const ChildMessenger = await companionNetworks.arbitrum.deployments.get("Arbitrum_ChildMessenger");
    const GovernorSpoke = await companionNetworks.arbitrum.deployments.get("GovernorSpoke");

    console.group(
      "\nReading Arbitrum Inbox transaction params that will be used to send cross chain transactions to the ChildMessenger"
    );
    const [
      refundL2Address,
      defaultL2GasLimit,
      defaultL2GasPrice,
      defaultMaxSubmissionCost,
      requiredL1CallValue,
      messengerOwner,
      oracleHubOwner,
      governorHubOwner,
      messengerChildMessenger,
      messengerOracleHub,
      messengerOracleSpoke,
      messengerGovernorHub,
      messengerGovernorSpoke,
      oracleHubParentMessenger,
      governorHubParentMessenger,
    ] = await Promise.all([
      messenger.methods.refundL2Address().call(),
      messenger.methods.defaultGasLimit().call(),
      messenger.methods.defaultGasPrice().call(),
      messenger.methods.defaultMaxSubmissionCost().call(),
      messenger.methods.getL1CallValue().call(),
      messenger.methods.owner().call(),
      oracleHub.methods.owner().call(),
      governorHub.methods.owner().call(),
      messenger.methods.childMessenger().call(),
      messenger.methods.oracleHub().call(),
      messenger.methods.oracleSpoke().call(),
      messenger.methods.governorHub().call(),
      messenger.methods.governorSpoke().call(),
      oracleHub.methods.messengers(42161).call(),
      governorHub.methods.messengers(42161).call(),
    ]);
    console.log(`- Refund L2 address: ${refundL2Address}`);
    console.log(`- Default L2 gas limit: ${defaultL2GasLimit.toString()}`);
    console.log(`- Default L2 gas price: ${defaultL2GasPrice.toString()}`);
    console.log(`- Default L2 max submission cost: ${defaultMaxSubmissionCost.toString()}`);
    console.log(`- Required L1 call value: ${requiredL1CallValue.toString()}`);
    console.groupEnd();

    // The following calls require that the caller has enough gas to cover each cross chain transaction, which requires
    // at most (l2GasLimit * l2GasPrice + maxSubmissionCost) ETH to be included in the transaction. What will happen
    // is that the user will send ETH to the parent messenger, which will include it as msg.value in a transaction
    // to the inbox.
    const amountOfCrossChainTransactions = 2;
    const requiredEthForOneTransaction = toBN(requiredL1CallValue.toString());
    const requiredEth = requiredEthForOneTransaction.mul(toBN(amountOfCrossChainTransactions));
    const userEthBalance = await web3.eth.getBalance(deployer);
    console.log(
      `\n${amountOfCrossChainTransactions} cross chain transactions each require ${requiredEthForOneTransaction.toString()} ETH (gasLimit * gasPrice + submissionCost)`
    );
    assert(
      toBN(userEthBalance).gt(requiredEth),
      "User has insufficient ETH balance to pay for cross chain transactions"
    );

    // Submit parent messenger local transactions:
    assert(
      messengerOwner === deployer,
      `Accounts[0] (${deployer}) is not equal to parent messenger owner (${messengerOwner})`
    );
    if (messengerChildMessenger !== ChildMessenger.address) {
      console.log(`Setting child messenger to ${ChildMessenger.address}...`);
      const setChildMessengerTxn = await messenger.methods
        .setChildMessenger(ChildMessenger.address)
        .send({ from: deployer });
      console.log(`...txn: ${setChildMessengerTxn.transactionHash}`);
    }
    if (messengerOracleHub !== OracleHub.address) {
      console.log(`Setting oracle hub to ${OracleHub.address}...`);
      const setOracleHubTxn = await messenger.methods.setOracleHub(OracleHub.address).send({ from: deployer });
      console.log(`...txn: ${setOracleHubTxn.transactionHash}`);
    }
    if (messengerGovernorHub !== GovernorHub.address) {
      console.log(`Setting governor hub to ${GovernorHub.address}...`);
      const setGovernorHubTxn = await messenger.methods.setGovernorHub(GovernorHub.address).send({ from: deployer });
      console.log(`...txn: ${setGovernorHubTxn.transactionHash}`);
    }
    if (messengerOracleSpoke !== OracleSpoke.address) {
      console.log(`Setting oracle spoke to ${OracleSpoke.address}...`);
      const setOracleSpokeTxn = await messenger.methods.setOracleSpoke(OracleSpoke.address).send({ from: deployer });
      console.log(`...txn: ${setOracleSpokeTxn.transactionHash}`);
    }
    if (messengerGovernorSpoke !== GovernorSpoke.address) {
      console.log(`Setting governor spoke to ${GovernorSpoke.address}...`);
      const setGovernorSpokeTxn = await messenger.methods
        .setGovernorSpoke(GovernorSpoke.address)
        .send({ from: deployer });
      console.log(`...txn: ${setGovernorSpokeTxn.transactionHash}`);
    }

    // Submit parent messenger cross-chain transactions:
    // First, send ETH to the parent messenger to cover both transactions.
    let messengerBalance = await web3.eth.getBalance(messenger.options.address);
    if (toBN(messengerBalance.toString()).lt(requiredEthForOneTransaction)) {
      console.log(`Sending ${requiredEthForOneTransaction.toString()} ETH to the messenger`);
      const sendEthTxn = await web3.eth.sendTransaction({
        to: messenger.options.address,
        from: deployer,
        value: requiredEthForOneTransaction.toString(),
      });
      console.log(`...txn: ${sendEthTxn.transactionHash}`);
    }
    console.log(`Setting child oracle spoke address to ${OracleSpoke.address}...`);
    const setChildOracleSpokeTxn = await messenger.methods
      .setChildOracleSpoke(OracleSpoke.address)
      .send({ from: deployer });
    console.log(`...txn: ${setChildOracleSpokeTxn.transactionHash}`);
    messengerBalance = await web3.eth.getBalance(messenger.options.address);
    if (toBN(messengerBalance.toString()).lt(requiredEthForOneTransaction)) {
      console.log(`Sending ${requiredEthForOneTransaction.toString()} ETH to the messenger`);
      const sendEthTxn = await web3.eth.sendTransaction({
        to: messenger.options.address,
        from: deployer,
        value: requiredEthForOneTransaction.toString(),
      });
      console.log(`...txn: ${sendEthTxn.transactionHash}`);
    }
    console.log(`Setting child parent messenger to ${messenger.options.address}...`);
    const setChildParentMessengerTxn = await messenger.methods
      .setChildParentMessenger(messenger.options.address)
      .send({ from: deployer });
    console.log(`...txn: ${setChildParentMessengerTxn.transactionHash}`);

    // Submit oracle hub transactions:
    assert(
      oracleHubOwner === deployer,
      `Accounts[0] (${deployer}) is not equal to oracle hub owner (${oracleHubOwner})`
    );
    if (oracleHubParentMessenger !== messenger.options.address) {
      console.log(`Setting oracle hub messenger for ID 42161 to ${messenger.options.address}...`);
      const setMessengerTxn = await oracleHub.methods
        .setMessenger(42161, messenger.options.address)
        .send({ from: deployer });
      console.log(`...txn: ${setMessengerTxn.transactionHash}`);
    }

    // Submit governor hub transactions:
    assert(
      governorHubOwner === deployer,
      `Accounts[0] (${deployer}) is not equal to governor hub owner (${governorHubOwner})`
    );
    if (governorHubParentMessenger !== messenger.options.address) {
      console.log(`Setting governor hub messenger for ID 42161 to ${messenger.options.address}...`);
      const setMessengerTxn2 = await governorHub.methods
        .setMessenger(42161, messenger.options.address)
        .send({ from: deployer });
      console.log(`...txn: ${setMessengerTxn2.transactionHash}`);
    }
  }
);

// task("setup-l2-arbitrum-xchain", "Configures L2 cross chain smart contracts for Arbitrum bridge")
//   .setAction(async function (_, hre_) {
//     const hre = hre_ as CombinedHRE;
//     const { deployments, getNamedAccounts, web3, companionNetworks } = hre;
//     const { toBN } = web3.utils
//     const { deployer } = await getNamedAccounts();

//     // Need to just set Finder addresses:
//     // - Registry
//     // - ChildMessenger
//   });
