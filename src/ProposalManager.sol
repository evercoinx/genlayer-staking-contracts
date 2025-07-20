// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IMockLLMOracle } from "./interfaces/IMockLLMOracle.sol";
import { IProposalManager } from "./interfaces/IProposalManager.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";

/**
 * @title ProposalManager
 * @dev Manages proposals in the GenLayer consensus system.
 * Handles proposal creation, state transitions, and lifecycle management.
 */
contract ProposalManager is IProposalManager, Ownable, ReentrancyGuard {
    /**
     * @dev Challenge window duration (10 blocks as per requirements).
     */
    uint256 public constant CHALLENGE_WINDOW_DURATION = 10;

    /**
     * @dev Counter for proposal IDs.
     */
    uint256 private proposalCounter;

    /**
     * @dev Mapping from proposal ID to proposal data.
     */
    mapping(uint256 => Proposal) private proposals;

    /**
     * @dev Mapping from proposer address to their proposal IDs.
     */
    mapping(address => uint256[]) private proposerToProposals;

    /**
     * @dev Array of proposal IDs by state for efficient querying.
     */
    mapping(ProposalState => uint256[]) private proposalsByState;

    /**
     * @dev Mapping to track if a validator has approved a proposal.
     */
    mapping(uint256 => mapping(address => bool)) private hasValidatorApproved;

    /**
     * @dev Validator registry contract.
     */
    IValidatorRegistry public immutable validatorRegistry;

    /**
     * @dev Mock LLM oracle contract.
     */
    IMockLLMOracle public immutable llmOracle;

    /**
     * @dev Address authorized to manage proposals.
     */
    address public proposalManager;

    /**
     * @dev Modifier to restrict functions to active validators.
     */
    modifier onlyActiveValidator() {
        require(validatorRegistry.isActiveValidator(msg.sender), CallerNotActiveValidator());
        _;
    }

    /**
     * @dev Modifier to restrict functions to proposal manager.
     */
    modifier onlyProposalManager() {
        require(msg.sender == proposalManager, CallerNotProposalManager());
        _;
    }

    /**
     * @dev Initializes the ProposalManager with required contracts.
     * @param _validatorRegistry Address of the validator registry contract.
     * @param _llmOracle Address of the LLM oracle contract.
     * @param _proposalManager Address authorized to manage proposals.
     */
    constructor(address _validatorRegistry, address _llmOracle, address _proposalManager) Ownable(msg.sender) {
        require(
            _validatorRegistry != address(0) && _llmOracle != address(0) && _proposalManager != address(0),
            ZeroAddress()
        );
        validatorRegistry = IValidatorRegistry(_validatorRegistry);
        llmOracle = IMockLLMOracle(_llmOracle);
        proposalManager = _proposalManager;
    }

    /**
     * @dev Sets a new proposal manager address. Only callable by owner.
     * @param newProposalManager The address to grant proposal management privileges to.
     */
    function setProposalManager(address newProposalManager) external onlyOwner {
        require(newProposalManager != address(0), ZeroAddress());
        proposalManager = newProposalManager;
    }

    /**
     * @inheritdoc IProposalManager
     */
    function createProposal(
        bytes32 contentHash,
        string calldata metadata
    )
        external
        nonReentrant
        returns (uint256 proposalId)
    {
        require(contentHash != bytes32(0), InvalidContentHash());
        require(bytes(metadata).length != 0, EmptyMetadata());

        proposalId = ++proposalCounter;

        Proposal storage newProposal = proposals[proposalId];
        newProposal.id = proposalId;
        newProposal.proposer = msg.sender;
        newProposal.contentHash = contentHash;
        newProposal.metadata = metadata;
        newProposal.state = ProposalState.Proposed;
        newProposal.createdAt = block.timestamp;
        newProposal.challengeWindowEnd = 0;
        newProposal.validatorApprovals = 0;
        newProposal.llmValidated = false;

        proposerToProposals[msg.sender].push(proposalId);
        proposalsByState[ProposalState.Proposed].push(proposalId);

        emit ProposalCreated(proposalId, msg.sender, contentHash);

        return proposalId;
    }

    /**
     * @inheritdoc IProposalManager
     */
    function approveOptimistically(uint256 proposalId) external onlyProposalManager {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.id != 0, ProposalNotFound());
        require(proposal.state == ProposalState.Proposed, InvalidStateTransition());

        proposal.state = ProposalState.OptimisticApproved;
        proposal.challengeWindowEnd = block.number + CHALLENGE_WINDOW_DURATION;

        _updateProposalStateArrays(proposalId, ProposalState.Proposed, ProposalState.OptimisticApproved);

        emit ProposalOptimisticallyApproved(proposalId, proposal.challengeWindowEnd);
    }

    /**
     * @inheritdoc IProposalManager
     */
    function challengeProposal(uint256 proposalId) external onlyActiveValidator {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.id != 0, ProposalNotFound());
        require(proposal.state == ProposalState.OptimisticApproved, ProposalNotChallengeable());
        require(block.number <= proposal.challengeWindowEnd, ChallengeWindowExpired());

        proposal.state = ProposalState.Challenged;
        _updateProposalStateArrays(proposalId, ProposalState.OptimisticApproved, ProposalState.Challenged);

        emit ProposalChallenged(proposalId, msg.sender);
    }

    /**
     * @inheritdoc IProposalManager
     */
    function finalizeProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.id != 0, ProposalNotFound());
        require(proposal.state == ProposalState.OptimisticApproved, InvalidStateTransition());
        require(block.number > proposal.challengeWindowEnd, ChallengeWindowActive());

        proposal.state = ProposalState.Finalized;
        _updateProposalStateArrays(proposalId, ProposalState.OptimisticApproved, ProposalState.Finalized);

        emit ProposalFinalized(proposalId, ProposalState.Finalized);
    }

    /**
     * @inheritdoc IProposalManager
     */
    function rejectProposal(uint256 proposalId, string calldata reason) external onlyProposalManager {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.id != 0, ProposalNotFound());
        require(
            proposal.state != ProposalState.Finalized && proposal.state != ProposalState.Rejected,
            InvalidStateTransition()
        );

        ProposalState previousState = proposal.state;
        proposal.state = ProposalState.Rejected;
        _updateProposalStateArrays(proposalId, previousState, ProposalState.Rejected);

        emit ProposalRejected(proposalId, reason);
    }

    /**
     * @inheritdoc IProposalManager
     */
    function updateLLMValidation(uint256 proposalId, bool validated) external onlyProposalManager {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.id != 0, ProposalNotFound());

        proposal.llmValidated = validated;
        emit LLMValidationUpdated(proposalId, validated);
    }

    /**
     * @inheritdoc IProposalManager
     */
    function recordValidatorApproval(uint256 proposalId) external onlyActiveValidator {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.id != 0, ProposalNotFound());
        require(
            proposal.state == ProposalState.Proposed || proposal.state == ProposalState.OptimisticApproved,
            InvalidStateTransition()
        );

        // Prevent double approval from same validator
        require(!hasValidatorApproved[proposalId][msg.sender], ValidatorAlreadyApproved());

        hasValidatorApproved[proposalId][msg.sender] = true;
        proposal.validatorApprovals++;

        emit ValidatorApprovalRecorded(proposalId, msg.sender, proposal.validatorApprovals);
    }

    /**
     * @inheritdoc IProposalManager
     */
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        Proposal memory proposal = proposals[proposalId];
        require(proposal.id != 0, ProposalNotFound());
        return proposal;
    }

    /**
     * @inheritdoc IProposalManager
     */
    function getProposalsByProposer(address proposer) external view returns (uint256[] memory) {
        return proposerToProposals[proposer];
    }

    /**
     * @inheritdoc IProposalManager
     */
    function getProposalsByState(ProposalState state) external view returns (uint256[] memory) {
        return proposalsByState[state];
    }

    /**
     * @inheritdoc IProposalManager
     */
    function getTotalProposals() external view returns (uint256) {
        return proposalCounter;
    }

    /**
     * @inheritdoc IProposalManager
     */
    function getChallengeWindowDuration() external pure returns (uint256) {
        return CHALLENGE_WINDOW_DURATION;
    }

    /**
     * @inheritdoc IProposalManager
     */
    function canChallenge(uint256 proposalId) external view returns (bool) {
        Proposal memory proposal = proposals[proposalId];
        return proposal.id != 0 && proposal.state == ProposalState.OptimisticApproved
            && block.number <= proposal.challengeWindowEnd;
    }

    /**
     * @inheritdoc IProposalManager
     */
    function canFinalize(uint256 proposalId) external view returns (bool) {
        Proposal memory proposal = proposals[proposalId];
        return proposal.id != 0 && proposal.state == ProposalState.OptimisticApproved
            && block.number > proposal.challengeWindowEnd;
    }

    /**
     * @dev Checks if a validator has already approved a proposal.
     * @param proposalId The ID of the proposal.
     * @param validator The address of the validator.
     * @return True if the validator has approved the proposal.
     */
    function hasApproved(uint256 proposalId, address validator) external view returns (bool) {
        return hasValidatorApproved[proposalId][validator];
    }

    /**
     * @dev Batch function to get multiple proposals at once.
     * @param proposalIds Array of proposal IDs to retrieve.
     * @return Array of proposals.
     */
    function getProposals(uint256[] calldata proposalIds) external view returns (Proposal[] memory) {
        uint256 length = proposalIds.length;
        Proposal[] memory result = new Proposal[](length);

        for (uint256 i = 0; i < length;) {
            result[i] = proposals[proposalIds[i]];
            if (result[i].id == 0) {
                revert ProposalNotFound();
            }
            unchecked {
                ++i;
            }
        }

        return result;
    }

    /**
     * @dev Updates the proposal state arrays when state changes.
     * @param proposalId The ID of the proposal.
     * @param fromState The previous state.
     * @param toState The new state.
     */
    function _updateProposalStateArrays(uint256 proposalId, ProposalState fromState, ProposalState toState) private {
        // Remove from old state array
        uint256[] storage fromArray = proposalsByState[fromState];
        uint256 length = fromArray.length;
        for (uint256 i = 0; i < length;) {
            if (fromArray[i] == proposalId) {
                fromArray[i] = fromArray[length - 1];
                fromArray.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }

        // Add to new state array
        proposalsByState[toState].push(proposalId);
    }
}
