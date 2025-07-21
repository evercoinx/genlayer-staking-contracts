// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { IMockLLMOracle } from "./interfaces/IMockLLMOracle.sol";
import { IProposalManager } from "./interfaces/IProposalManager.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";

/**
 * @title ProposalManager
 * @dev Manages proposals in the GenLayer consensus system with optimized data structures
 * for O(1) state transitions and efficient proposal tracking.
 */
contract ProposalManager is IProposalManager, Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.UintSet;

    uint256 public constant CHALLENGE_WINDOW_DURATION = 10;

    IValidatorRegistry public immutable validatorRegistry;
    IMockLLMOracle public immutable llmOracle;

    address public proposalManager;
    uint256 public totalProposals;
    mapping(uint256 proposalId => Proposal) private _proposals;
    mapping(address proposer => EnumerableSet.UintSet) private _proposerToProposals;
    mapping(ProposalState state => EnumerableSet.UintSet) private _proposalsByState;
    mapping(uint256 proposalId => mapping(address validator => bool approved)) private _hasValidatorApproved;

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
        require(_validatorRegistry != address(0), ZeroValidatorRegistry());
        validatorRegistry = IValidatorRegistry(_validatorRegistry);

        require(_llmOracle != address(0), ZeroLLMOracle());
        llmOracle = IMockLLMOracle(_llmOracle);

        require(_proposalManager != address(0), ZeroProposalManager());
        proposalManager = _proposalManager;
    }

    /**
     * @inheritdoc IProposalManager
     */
    function setProposalManager(address newProposalManager) external override onlyOwner {
        require(newProposalManager != address(0), ZeroProposalManager());
        address oldManager = proposalManager;
        proposalManager = newProposalManager;
        emit ProposalManagerUpdated(oldManager, newProposalManager);
    }

    /**
     * @inheritdoc IProposalManager
     */
    function createProposal(
        bytes32 contentHash,
        string calldata metadata
    )
        external
        override
        nonReentrant
        returns (uint256 proposalId)
    {
        require(contentHash != bytes32(0), InvalidContentHash());
        require(bytes(metadata).length != 0, EmptyMetadata());

        proposalId = ++totalProposals;

        Proposal storage newProposal = _proposals[proposalId];
        newProposal.id = proposalId;
        newProposal.proposer = msg.sender;
        newProposal.contentHash = contentHash;
        newProposal.metadata = metadata;
        newProposal.state = ProposalState.Proposed;
        newProposal.createdAt = block.timestamp;
        newProposal.challengeWindowEnd = 0;
        newProposal.validatorApprovals = 0;
        newProposal.llmValidated = false;

        _proposerToProposals[msg.sender].add(proposalId);
        _proposalsByState[ProposalState.Proposed].add(proposalId);

        emit ProposalCreated(proposalId, msg.sender, contentHash);

        return proposalId;
    }

    /**
     * @inheritdoc IProposalManager
     */
    function approveOptimistically(uint256 proposalId) external override onlyProposalManager {
        Proposal storage proposal = _proposals[proposalId];
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
    function challengeProposal(uint256 proposalId) external override onlyActiveValidator {
        Proposal storage proposal = _proposals[proposalId];
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
    function finalizeProposal(uint256 proposalId) external override {
        Proposal storage proposal = _proposals[proposalId];
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
    function rejectProposal(uint256 proposalId, string calldata reason) external override onlyProposalManager {
        Proposal storage proposal = _proposals[proposalId];
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
    function updateLLMValidation(uint256 proposalId, bool validated) external override onlyProposalManager {
        Proposal storage proposal = _proposals[proposalId];
        require(proposal.id != 0, ProposalNotFound());

        proposal.llmValidated = validated;
        emit LLMValidationUpdated(proposalId, validated);
    }

    /**
     * @inheritdoc IProposalManager
     */
    function recordValidatorApproval(uint256 proposalId) external override onlyActiveValidator {
        Proposal storage proposal = _proposals[proposalId];
        require(proposal.id != 0, ProposalNotFound());
        require(
            proposal.state == ProposalState.Proposed || proposal.state == ProposalState.OptimisticApproved,
            InvalidStateTransition()
        );
        require(!_hasValidatorApproved[proposalId][msg.sender], ValidatorAlreadyApproved());

        _hasValidatorApproved[proposalId][msg.sender] = true;
        proposal.validatorApprovals++;

        emit ValidatorApprovalRecorded(proposalId, msg.sender, proposal.validatorApprovals);
    }

    /**
     * @inheritdoc IProposalManager
     */
    function getProposal(uint256 proposalId) external view override returns (Proposal memory) {
        Proposal memory proposal = _proposals[proposalId];
        require(proposal.id != 0, ProposalNotFound());
        return proposal;
    }

    /**
     * @inheritdoc IProposalManager
     */
    function getProposalsByProposer(address proposer) external view override returns (uint256[] memory) {
        return _proposerToProposals[proposer].values();
    }

    /**
     * @inheritdoc IProposalManager
     */
    function getProposalsByState(ProposalState state) external view override returns (uint256[] memory) {
        return _proposalsByState[state].values();
    }

    /**
     * @inheritdoc IProposalManager
     */
    function canChallenge(uint256 proposalId) external view override returns (bool) {
        Proposal memory proposal = _proposals[proposalId];
        return proposal.id != 0 && proposal.state == ProposalState.OptimisticApproved
            && block.number <= proposal.challengeWindowEnd;
    }

    /**
     * @inheritdoc IProposalManager
     */
    function canFinalize(uint256 proposalId) external view override returns (bool) {
        Proposal memory proposal = _proposals[proposalId];
        return proposal.id != 0 && proposal.state == ProposalState.OptimisticApproved
            && block.number > proposal.challengeWindowEnd;
    }

    /**
     * @inheritdoc IProposalManager
     */
    function hasApproved(uint256 proposalId, address validator) external view override returns (bool) {
        return _hasValidatorApproved[proposalId][validator];
    }

    /**
     * @inheritdoc IProposalManager
     */
    function getProposals(uint256[] calldata proposalIds) external view override returns (Proposal[] memory) {
        uint256 length = proposalIds.length;
        Proposal[] memory result = new Proposal[](length);

        for (uint256 i = 0; i < length; ++i) {
            result[i] = _proposals[proposalIds[i]];
            require(result[i].id != 0, ProposalNotFound());
        }

        return result;
    }

    /**
     * @dev Updates the proposal state sets when state changes.
     * @param proposalId The ID of the proposal.
     * @param fromState The previous state.
     * @param toState The new state.
     */
    function _updateProposalStateArrays(uint256 proposalId, ProposalState fromState, ProposalState toState) private {
        _proposalsByState[fromState].remove(proposalId);
        _proposalsByState[toState].add(proposalId);
    }
}
