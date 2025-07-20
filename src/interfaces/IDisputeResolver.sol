// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IDisputeResolver
 * @dev Interface for the dispute resolution mechanism in the GenLayer consensus system.
 * Handles challenges, voting, slashing, and reward distribution.
 */
interface IDisputeResolver {
    /**
     * @dev Enum representing the state of a dispute.
     */
    enum DisputeState {
        Active,
        VotingComplete,
        Resolved,
        Cancelled
    }

    /**
     * @dev Struct containing dispute information.
     */
    struct Dispute {
        uint256 proposalId;
        address challenger;
        address proposer;
        uint256 challengeStake;
        DisputeState state;
        uint256 createdAt;
        uint256 votingEndTime;
        uint256 votesFor;
        uint256 votesAgainst;
        bool challengerWon;
        uint256 slashAmount;
    }

    /**
     * @dev Struct containing dispute vote information.
     */
    struct DisputeVote {
        address validator;
        bool supportChallenge;
        bytes signature;
        uint256 timestamp;
    }

    /**
     * @dev Emitted when a dispute is created.
     * @param disputeId The ID of the dispute.
     * @param proposalId The ID of the disputed proposal.
     * @param challenger The address that initiated the challenge.
     * @param challengeStake The amount staked for the challenge.
     */
    event DisputeCreated(
        uint256 indexed disputeId,
        uint256 indexed proposalId,
        address indexed challenger,
        uint256 challengeStake
    );

    /**
     * @dev Emitted when a vote is cast on a dispute.
     * @param disputeId The ID of the dispute.
     * @param validator The address of the voting validator.
     * @param supportChallenge Whether the validator supports the challenge.
     */
    event DisputeVoteCast(uint256 indexed disputeId, address indexed validator, bool supportChallenge);

    /**
     * @dev Emitted when a dispute is resolved.
     * @param disputeId The ID of the dispute.
     * @param challengerWon Whether the challenger won the dispute.
     * @param slashAmount The amount slashed from the losing party.
     */
    event DisputeResolved(uint256 indexed disputeId, bool challengerWon, uint256 slashAmount);

    /**
     * @dev Emitted when rewards are distributed after dispute resolution.
     * @param disputeId The ID of the dispute.
     * @param recipient The address receiving the reward.
     * @param amount The reward amount.
     */
    event RewardDistributed(uint256 indexed disputeId, address indexed recipient, uint256 amount);

    /**
     * @dev Error thrown when dispute is not found.
     */
    error DisputeNotFound();

    /**
     * @dev Error thrown when dispute state is invalid for the operation.
     */
    error InvalidDisputeState();

    /**
     * @dev Error thrown when insufficient stake is provided.
     */
    error InsufficientChallengeStake();

    /**
     * @dev Error thrown when caller is not authorized.
     */
    error UnauthorizedCaller();

    /**
     * @dev Error thrown when voting period has ended.
     */
    error DisputeVotingEnded();

    /**
     * @dev Error thrown when voting period is still active.
     */
    error DisputeVotingActive();

    /**
     * @dev Error thrown when validator has already voted.
     */
    error ValidatorAlreadyVoted();

    /**
     * @dev Error thrown when proposal is not challengeable.
     */
    error ProposalNotDisputable();

    /**
     * @dev Error thrown when challenge stake is zero.
     */
    error ZeroChallengeStake();

    /**
     * @dev Error thrown when caller is not an active validator.
     */
    error CallerNotActiveValidator();

    /**
     * @dev Error thrown when zero address is provided.
     */
    error ZeroAddress();

    /**
     * @dev Error thrown when signature is invalid.
     */
    error InvalidSignature();

    /**
     * @dev Creates a new dispute for a proposal.
     * @param proposalId The ID of the proposal to dispute.
     * @param challengeStake The amount to stake for the challenge.
     * @return disputeId The ID of the created dispute.
     */
    function createDispute(uint256 proposalId, uint256 challengeStake) external returns (uint256 disputeId);

    /**
     * @dev Casts a vote on an active dispute.
     * @param disputeId The ID of the dispute.
     * @param supportChallenge Whether to support the challenge.
     * @param signature The validator's signature.
     */
    function voteOnDispute(uint256 disputeId, bool supportChallenge, bytes calldata signature) external;

    /**
     * @dev Resolves a dispute after voting period ends.
     * @param disputeId The ID of the dispute to resolve.
     */
    function resolveDispute(uint256 disputeId) external;

    /**
     * @dev Cancels a dispute (admin function).
     * @param disputeId The ID of the dispute to cancel.
     * @param reason The reason for cancellation.
     */
    function cancelDispute(uint256 disputeId, string calldata reason) external;

    /**
     * @dev Returns the details of a specific dispute.
     * @param disputeId The ID of the dispute.
     * @return dispute The dispute details.
     */
    function getDispute(uint256 disputeId) external view returns (Dispute memory dispute);

    /**
     * @dev Returns all disputes for a specific proposal.
     * @param proposalId The ID of the proposal.
     * @return disputeIds Array of dispute IDs.
     */
    function getDisputesByProposal(uint256 proposalId) external view returns (uint256[] memory disputeIds);

    /**
     * @dev Returns vote information for a dispute and validator.
     * @param disputeId The dispute ID.
     * @param validator The validator address.
     * @return hasVoted Whether the validator has voted.
     * @return supportChallenge Whether the validator supported the challenge.
     */
    function getDisputeVote(
        uint256 disputeId,
        address validator
    ) external view returns (bool hasVoted, bool supportChallenge);

    /**
     * @dev Returns the minimum challenge stake required.
     * @return minStake The minimum stake amount.
     */
    function getMinimumChallengeStake() external view returns (uint256 minStake);

    /**
     * @dev Returns the dispute voting period duration.
     * @return duration The voting period in seconds.
     */
    function getDisputeVotingPeriod() external view returns (uint256 duration);

    /**
     * @dev Returns the slash percentage for losing disputes.
     * @return percentage The slash percentage (e.g., 10 for 10%).
     */
    function getSlashPercentage() external view returns (uint256 percentage);

    /**
     * @dev Checks if a dispute can be resolved.
     * @param disputeId The dispute ID.
     * @return canResolve True if the dispute can be resolved.
     */
    function canResolveDispute(uint256 disputeId) external view returns (bool canResolve);

    /**
     * @dev Returns the total number of disputes.
     * @return count The total dispute count.
     */
    function getTotalDisputes() external view returns (uint256 count);
}