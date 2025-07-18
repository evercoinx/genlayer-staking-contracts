// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IConsensusEngine
 * @dev Interface for the consensus engine that orchestrates the GenLayer consensus mechanism.
 * Manages proposal validation, validator voting, and consensus finalization.
 */
interface IConsensusEngine {
    /**
     * @dev Struct containing vote information.
     */
    struct Vote {
        address validator;
        bool support;
        bytes signature;
        uint256 timestamp;
    }

    /**
     * @dev Struct containing consensus round information.
     */
    struct ConsensusRound {
        uint256 proposalId;
        uint256 startBlock;
        uint256 endBlock;
        uint256 votesFor;
        uint256 votesAgainst;
        bool finalized;
        mapping(address => bool) hasVoted;
    }

    /**
     * @dev Emitted when a new consensus round starts.
     * @param proposalId The ID of the proposal being voted on.
     * @param roundId The ID of the consensus round.
     * @param startBlock The starting block number.
     * @param endBlock The ending block number.
     */
    event ConsensusRoundStarted(
        uint256 indexed proposalId,
        uint256 indexed roundId,
        uint256 startBlock,
        uint256 endBlock
    );

    /**
     * @dev Emitted when a validator casts a vote.
     * @param roundId The consensus round ID.
     * @param validator The address of the voting validator.
     * @param support Whether the validator supports the proposal.
     */
    event VoteCast(uint256 indexed roundId, address indexed validator, bool support);

    /**
     * @dev Emitted when a consensus round is finalized.
     * @param roundId The consensus round ID.
     * @param proposalId The proposal ID.
     * @param approved Whether the proposal was approved.
     * @param votesFor Number of votes in favor.
     * @param votesAgainst Number of votes against.
     */
    event ConsensusFinalized(
        uint256 indexed roundId,
        uint256 indexed proposalId,
        bool approved,
        uint256 votesFor,
        uint256 votesAgainst
    );

    /**
     * @dev Error thrown when round is not found.
     */
    error RoundNotFound();

    /**
     * @dev Error thrown when voting period has ended.
     */
    error VotingPeriodEnded();

    /**
     * @dev Error thrown when voting period is still active.
     */
    error VotingPeriodActive();

    /**
     * @dev Error thrown when validator has already voted.
     */
    error AlreadyVoted();

    /**
     * @dev Error thrown when caller is not an active validator.
     */
    error NotActiveValidator();

    /**
     * @dev Error thrown when signature is invalid.
     */
    error InvalidSignature();

    /**
     * @dev Error thrown when round is already finalized.
     */
    error RoundAlreadyFinalized();

    /**
     * @dev Error thrown when proposal is already in consensus.
     */
    error ProposalAlreadyInConsensus();

    /**
     * @dev Initiates a consensus round for a proposal.
     * @param proposalId The ID of the proposal.
     * @return roundId The ID of the created consensus round.
     */
    function initiateConsensus(uint256 proposalId) external returns (uint256 roundId);

    /**
     * @dev Casts a vote in a consensus round.
     * @param roundId The ID of the consensus round.
     * @param support Whether to support the proposal.
     * @param signature The validator's signature.
     */
    function castVote(uint256 roundId, bool support, bytes calldata signature) external;

    /**
     * @dev Finalizes a consensus round after voting period ends.
     * @param roundId The ID of the consensus round to finalize.
     * @return approved Whether the proposal was approved.
     */
    function finalizeConsensus(uint256 roundId) external returns (bool approved);

    /**
     * @dev Returns the current consensus round for a proposal.
     * @param proposalId The ID of the proposal.
     * @return roundId The current round ID, or 0 if none exists.
     */
    function getCurrentRound(uint256 proposalId) external view returns (uint256 roundId);

    /**
     * @dev Returns vote information for a specific round and validator.
     * @param roundId The consensus round ID.
     * @param validator The validator address.
     * @return hasVoted Whether the validator has voted.
     * @return support Whether the validator supported the proposal.
     */
    function getVote(uint256 roundId, address validator) external view returns (bool hasVoted, bool support);

    /**
     * @dev Returns the vote counts for a consensus round.
     * @param roundId The consensus round ID.
     * @return votesFor Number of votes in favor.
     * @return votesAgainst Number of votes against.
     * @return totalValidators Total number of eligible validators.
     */
    function getVoteCounts(
        uint256 roundId
    ) external view returns (uint256 votesFor, uint256 votesAgainst, uint256 totalValidators);

    /**
     * @dev Returns the voting period duration in blocks.
     * @return duration The voting period duration.
     */
    function getVotingPeriod() external view returns (uint256 duration);

    /**
     * @dev Returns the quorum percentage required for consensus.
     * @return percentage The quorum percentage (e.g., 66 for 66%).
     */
    function getQuorumPercentage() external view returns (uint256 percentage);

    /**
     * @dev Checks if a consensus round can be finalized.
     * @param roundId The consensus round ID.
     * @return canFinalize True if the round can be finalized.
     */
    function canFinalizeRound(uint256 roundId) external view returns (bool canFinalize);

    /**
     * @dev Verifies a validator's signature for a vote.
     * @param roundId The consensus round ID.
     * @param validator The validator address.
     * @param support The vote support value.
     * @param signature The signature to verify.
     * @return isValid True if the signature is valid.
     */
    function verifyVoteSignature(
        uint256 roundId,
        address validator,
        bool support,
        bytes calldata signature
    ) external view returns (bool isValid);
}