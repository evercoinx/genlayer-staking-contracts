// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IProposalManager
 * @dev Interface for managing proposals in the GenLayer consensus system.
 * Handles proposal creation, state management, and lifecycle tracking.
 */
interface IProposalManager {
    /**
     * @dev Enum representing the state of a proposal.
     */
    enum ProposalState {
        Proposed,
        OptimisticApproved,
        Challenged,
        Finalized,
        Rejected
    }

    /**
     * @dev Struct containing proposal information.
     */
    struct Proposal {
        uint256 id;
        address proposer;
        bytes32 contentHash;
        string metadata;
        ProposalState state;
        uint256 createdAt;
        uint256 challengeWindowEnd;
        uint256 validatorApprovals;
        bool llmValidated;
    }

    /**
     * @dev Emitted when a new proposal is created.
     * @param proposalId The ID of the created proposal.
     * @param proposer The address that created the proposal.
     * @param contentHash The hash of the proposal content.
     */
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, bytes32 contentHash);

    /**
     * @dev Emitted when a proposal transitions to optimistic approval.
     * @param proposalId The ID of the proposal.
     * @param challengeWindowEnd The timestamp when the challenge window ends.
     */
    event ProposalOptimisticallyApproved(uint256 indexed proposalId, uint256 challengeWindowEnd);

    /**
     * @dev Emitted when a proposal is challenged.
     * @param proposalId The ID of the proposal.
     * @param challenger The address that challenged the proposal.
     */
    event ProposalChallenged(uint256 indexed proposalId, address indexed challenger);

    /**
     * @dev Emitted when a proposal is finalized.
     * @param proposalId The ID of the proposal.
     * @param state The final state of the proposal.
     */
    event ProposalFinalized(uint256 indexed proposalId, ProposalState state);

    /**
     * @dev Emitted when a proposal is rejected.
     * @param proposalId The ID of the proposal.
     * @param reason The reason for rejection.
     */
    event ProposalRejected(uint256 indexed proposalId, string reason);

    /**
     * @dev Emitted when a validator records their approval.
     * @param proposalId The ID of the proposal.
     * @param validator The address of the validator.
     * @param totalApprovals The total number of approvals after this one.
     */
    event ValidatorApprovalRecorded(uint256 indexed proposalId, address indexed validator, uint256 totalApprovals);

    /**
     * @dev Emitted when LLM validation is updated.
     * @param proposalId The ID of the proposal.
     * @param validated The validation status.
     */
    event LLMValidationUpdated(uint256 indexed proposalId, bool validated);

    /**
     * @dev Error thrown when a proposal is not found.
     */
    error ProposalNotFound();

    /**
     * @dev Error thrown when attempting an invalid state transition.
     */
    error InvalidStateTransition();

    /**
     * @dev Error thrown when the challenge window has not expired.
     */
    error ChallengeWindowActive();

    /**
     * @dev Error thrown when the challenge window has expired.
     */
    error ChallengeWindowExpired();

    /**
     * @dev Error thrown when zero content hash is provided.
     */
    error InvalidContentHash();

    /**
     * @dev Error thrown when metadata is empty.
     */
    error EmptyMetadata();

    /**
     * @dev Error thrown when unauthorized access is attempted.
     */
    error Unauthorized();

    /**
     * @dev Error thrown when trying to challenge an unchallengeable proposal.
     */
    error ProposalNotChallengeable();

    /**
     * @dev Error thrown when caller is not an active validator.
     */
    error CallerNotActiveValidator();

    /**
     * @dev Error thrown when caller is not the proposal manager.
     */
    error CallerNotProposalManager();

    /**
     * @dev Error thrown when zero address is provided.
     */
    error ZeroAddress();

    /**
     * @dev Error thrown when validator has already approved a proposal.
     */
    error ValidatorAlreadyApproved();

    /**
     * @dev Creates a new proposal.
     * @param contentHash The hash of the proposal content.
     * @param metadata Additional metadata for the proposal.
     * @return proposalId The ID of the created proposal.
     */
    function createProposal(bytes32 contentHash, string calldata metadata) external returns (uint256 proposalId);

    /**
     * @dev Moves a proposal to optimistic approval state.
     * @param proposalId The ID of the proposal.
     */
    function approveOptimistically(uint256 proposalId) external;

    /**
     * @dev Challenges an optimistically approved proposal.
     * @param proposalId The ID of the proposal to challenge.
     */
    function challengeProposal(uint256 proposalId) external;

    /**
     * @dev Finalizes a proposal after the challenge window.
     * @param proposalId The ID of the proposal to finalize.
     */
    function finalizeProposal(uint256 proposalId) external;

    /**
     * @dev Rejects a proposal.
     * @param proposalId The ID of the proposal to reject.
     * @param reason The reason for rejection.
     */
    function rejectProposal(uint256 proposalId, string calldata reason) external;

    /**
     * @dev Updates the LLM validation status of a proposal.
     * @param proposalId The ID of the proposal.
     * @param validated Whether the proposal passed LLM validation.
     */
    function updateLLMValidation(uint256 proposalId, bool validated) external;

    /**
     * @dev Records validator approval for a proposal.
     * @param proposalId The ID of the proposal.
     */
    function recordValidatorApproval(uint256 proposalId) external;

    /**
     * @dev Returns the details of a specific proposal.
     * @param proposalId The ID of the proposal.
     * @return proposal The proposal details.
     */
    function getProposal(uint256 proposalId) external view returns (Proposal memory proposal);

    /**
     * @dev Returns all proposals by a specific proposer.
     * @param proposer The address of the proposer.
     * @return proposalIds Array of proposal IDs.
     */
    function getProposalsByProposer(address proposer) external view returns (uint256[] memory proposalIds);

    /**
     * @dev Returns all proposals in a specific state.
     * @param state The state to filter by.
     * @return proposalIds Array of proposal IDs.
     */
    function getProposalsByState(ProposalState state) external view returns (uint256[] memory proposalIds);

    /**
     * @dev Returns the total number of proposals.
     * @return count The total proposal count.
     */
    function getTotalProposals() external view returns (uint256 count);

    /**
     * @dev Returns the challenge window duration.
     * @return duration The challenge window duration in seconds.
     */
    function getChallengeWindowDuration() external view returns (uint256 duration);

    /**
     * @dev Checks if a proposal can be challenged.
     * @param proposalId The ID of the proposal.
     * @return canChallenge True if the proposal can be challenged.
     */
    function canChallenge(uint256 proposalId) external view returns (bool canChallenge);

    /**
     * @dev Checks if a proposal can be finalized.
     * @param proposalId The ID of the proposal.
     * @return canFinalize True if the proposal can be finalized.
     */
    function canFinalize(uint256 proposalId) external view returns (bool canFinalize);

    /**
     * @dev Checks if a validator has already approved a proposal.
     * @param proposalId The ID of the proposal.
     * @param validator The address of the validator.
     * @return approved True if the validator has approved the proposal.
     */
    function hasApproved(uint256 proposalId, address validator) external view returns (bool approved);

    /**
     * @dev Batch function to get multiple proposals at once.
     * @param proposalIds Array of proposal IDs to retrieve.
     * @return proposals Array of proposals.
     */
    function getProposals(uint256[] calldata proposalIds) external view returns (Proposal[] memory proposals);
}
