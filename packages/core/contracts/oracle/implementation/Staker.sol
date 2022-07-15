// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/StakerInterface.sol";

import "./VotingToken.sol";
import "../../common/implementation/Testable.sol";

import "@openzeppelin/contracts/access/Ownable.sol";

import "hardhat/console.sol";

contract Staker is StakerInterface, Ownable, Testable {
    /****************************************
     *           STAKING TRACKERS           *
     ****************************************/

    uint256 public emissionRate;
    uint256 public cumulativeActiveStake;
    uint256 public cumulativePendingStake;
    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateTime;

    uint256 unstakeCoolDown;

    struct VoterStake {
        uint256 activeStake;
        uint256 pendingUnstake;
        uint256 pendingStake;
        uint256 rewardsPaidPerToken;
        uint256 outstandingRewards;
        uint256 unstakeRequestTime;
        uint256 lastRequestIndexConsidered;
        address delegate;
    }

    mapping(address => VoterStake) public voterStakes;

    // Mapping of delegates to the stakers (accounts who can vote on behalf of the stakers mapped to the staker).
    mapping(address => address) public delegateToStaker;

    // Reference to the voting token.
    VotingToken public override votingToken;

    /****************************************
     *                EVENTS                *
     ****************************************/

    event Staked(
        address indexed voter,
        uint256 amount,
        uint256 voterActiveStake,
        uint256 voterPendingStake,
        uint256 voterPendingUnStake,
        uint256 cumulativeActiveStake,
        uint256 cumulativePendingStake
    );

    event RequestedUnstake(
        address indexed voter,
        uint256 amount,
        uint256 unstakeTime,
        uint256 voterActiveStake,
        uint256 voterPendingStake
    );

    event ExecutedUnstake(
        address indexed voter,
        uint256 tokensSent,
        uint256 voterActiveStake,
        uint256 voterPendingStake
    );

    event WithdrawnRewards(address indexed voter, uint256 tokensWithdrawn);

    event UpdatedReward(address indexed voter, uint256 newReward, uint256 lastUpdateTime);

    event UpdatedActiveStake(
        address indexed voter,
        uint256 voterActiveStake,
        uint256 voterPendingStake,
        uint256 cumulativeActiveStake,
        uint256 cumulativePendingStake
    );

    event SetNewEmissionRate(uint256 newEmissionRate);

    event SetNewUnstakeCooldown(uint256 newUnstakeCooldown);

    constructor(
        uint256 _emissionRate,
        uint256 _unstakeCoolDown,
        address _votingToken,
        address _timerAddress
    ) Testable(_timerAddress) {
        emissionRate = _emissionRate;
        unstakeCoolDown = _unstakeCoolDown;
        votingToken = VotingToken(_votingToken);
    }

    // Pulls tokens from users wallet and stakes them.
    function stake(uint256 amount) public override {
        VoterStake storage voterStake = voterStakes[msg.sender];
        // If the staker has a cumulative staked balance of 0 then we can shortcut their lastRequestIndexConsidered to
        // the most recent index. This means we don't need to traverse requests where the staker was not staked.
        if (getVoterStake(msg.sender) + voterStake.pendingStake == 0)
            voterStake.lastRequestIndexConsidered = getStartingIndexForStaker();

        _updateTrackers(msg.sender);
        if (inActiveReveal()) {
            voterStake.pendingStake += amount;
            cumulativePendingStake += amount;
        } else {
            voterStake.activeStake += amount;
            cumulativeActiveStake += amount;
        }

        votingToken.transferFrom(msg.sender, address(this), amount);
        emit Staked(
            msg.sender,
            amount,
            voterStake.activeStake,
            voterStake.pendingStake,
            voterStake.pendingUnstake,
            cumulativeActiveStake,
            cumulativePendingStake
        );
    }

    //You cant request to unstake during an active reveal phase.
    function requestUnstake(uint256 amount) public override {
        require(!inActiveReveal(), "In an active reveal phase");
        _updateTrackers(msg.sender);
        VoterStake storage voterStake = voterStakes[msg.sender];

        // Staker signals that they want to unstake. After signalling, their total voting balance is decreased by the
        // signaled amount. This amount is not vulnerable to being slashed but also does not accumulate rewards.
        require(voterStake.activeStake >= amount, "Bad request amount");
        require(voterStake.pendingUnstake == 0, "Have previous request unstake");

        cumulativeActiveStake -= amount;
        voterStake.pendingUnstake = amount;
        voterStake.activeStake -= amount;
        voterStake.unstakeRequestTime = getCurrentTime();

        emit RequestedUnstake(
            msg.sender,
            amount,
            voterStake.unstakeRequestTime,
            voterStake.activeStake,
            voterStake.pendingStake
        );
    }

    // Note there is no way to cancel your unstake; you must wait until after unstakeRequestTime and re-stake.

    // If: a staker requested an unstake and time > unstakeRequestTime then send funds to staker. Note that this method assumes
    // that the `updateTrackers()
    function executeUnstake() public override {
        _updateTrackers(msg.sender);
        VoterStake storage voterStake = voterStakes[msg.sender];
        require(
            voterStake.unstakeRequestTime != 0 && getCurrentTime() >= voterStake.unstakeRequestTime + unstakeCoolDown,
            "Unstake time not passed"
        );
        uint256 tokensToSend = voterStake.pendingUnstake;

        if (tokensToSend > 0) {
            voterStake.pendingUnstake = 0;
            voterStake.unstakeRequestTime = 0;
            votingToken.transfer(msg.sender, tokensToSend);
        }

        emit ExecutedUnstake(msg.sender, tokensToSend, voterStake.activeStake, voterStake.pendingStake);
    }

    // Send accumulated rewards to the voter. If the voter has gained rewards from others slashing then this is included
    // here. If the total slashing is larger than the outstanding rewards then this method does nothing.
    function withdrawRewards() public override returns (uint256) {
        _updateTrackers(msg.sender);
        VoterStake storage voterStake = voterStakes[msg.sender];

        uint256 tokensToMint = voterStake.outstandingRewards;
        if (tokensToMint > 0) {
            voterStake.outstandingRewards = 0;
            require(votingToken.mint(msg.sender, tokensToMint), "Voting token issuance failed");
        }
        emit WithdrawnRewards(msg.sender, tokensToMint);

        return (tokensToMint);
    }

    function exit() public {
        executeUnstake();
        withdrawRewards();
    }

    function _updateTrackers(address voterAddress) internal virtual {
        _updateReward(voterAddress);
        _updateActiveStake(voterAddress);
    }

    function inActiveReveal() public virtual returns (bool) {
        return false;
    }

    function getStartingIndexForStaker() internal virtual returns (uint256) {
        return 0;
    }

    // Calculate the reward per token based on last time the reward was updated.
    function _updateReward(address voterAddress) internal {
        uint256 currentTime = getCurrentTime();
        uint256 newRewardPerToken = rewardPerToken();
        rewardPerTokenStored = newRewardPerToken;
        lastUpdateTime = currentTime;
        if (voterAddress != address(0)) {
            VoterStake storage voterStake = voterStakes[voterAddress];
            voterStake.outstandingRewards = outstandingRewards(voterAddress);
            voterStake.rewardsPaidPerToken = newRewardPerToken;
        }
        emit UpdatedReward(voterAddress, newRewardPerToken, lastUpdateTime);
    }

    function _updateActiveStake(address voterAddress) internal {
        if (inActiveReveal()) return;
        cumulativeActiveStake += voterStakes[voterAddress].pendingStake;
        cumulativePendingStake -= voterStakes[voterAddress].pendingStake;
        voterStakes[voterAddress].activeStake += voterStakes[voterAddress].pendingStake;
        voterStakes[voterAddress].pendingStake = 0;
        emit UpdatedActiveStake(
            voterAddress,
            voterStakes[voterAddress].activeStake,
            voterStakes[voterAddress].pendingStake,
            cumulativeActiveStake,
            cumulativePendingStake
        );
    }

    function outstandingRewards(address voterAddress) public view returns (uint256) {
        VoterStake storage voterStake = voterStakes[voterAddress];

        return
            ((getVoterStake(voterAddress) * (rewardPerToken() - voterStake.rewardsPaidPerToken)) / 1e18) +
            voterStake.outstandingRewards;
    }

    function rewardPerToken() public view returns (uint256) {
        if (getCumulativeStake() == 0) return rewardPerTokenStored;
        return
            rewardPerTokenStored + ((getCurrentTime() - lastUpdateTime) * emissionRate * 1e18) / getCumulativeStake();
    }

    function getCumulativeStake() public view returns (uint256) {
        return cumulativeActiveStake + cumulativePendingStake;
    }

    function getVoterStake(address voterAddress) public view returns (uint256) {
        return voterStakes[voterAddress].activeStake + voterStakes[voterAddress].pendingStake;
    }

    // Owner methods
    function setEmissionRate(uint256 _emissionRate) public onlyOwner {
        _updateReward(address(0));
        emissionRate = _emissionRate;
        emit SetNewEmissionRate(emissionRate);
    }

    function setUnstakeCoolDown(uint256 _unstakeCoolDown) public onlyOwner {
        unstakeCoolDown = _unstakeCoolDown;
        emit SetNewUnstakeCooldown(unstakeCoolDown);
    }
}
