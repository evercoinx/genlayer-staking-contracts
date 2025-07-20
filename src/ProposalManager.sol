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
        require(
            validatorRegistry.isActiveValidator(msg.sender),
            "ProposalManager: caller is not an active validator"
        );
        _;
    }

    /**
     * @dev Modifier to restrict functions to proposal manager.
     */
    modifier onlyProposalManager() {
        require(msg.sender == proposalManager, "ProposalManager: caller is not the proposal manager");
        _;
    }

    /**
     * @dev Initializes the ProposalManager with required contracts.
     * @param _validatorRegistry Address of the validator registry contract.
     * @param _llmOracle Address of the LLM oracle contract.
     * @param _proposalManager Address authorized to manage proposals.
     */
    constructor(
        address _validatorRegistry,
        address _llmOracle,
        address _proposalManager
    ) Ownable(msg.sender) {
        require(
            _validatorRegistry != address(0) && _llmOracle != address(0) && _proposalManager != address(0),
            "ProposalManager: zero address"
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
        require(newProposalManager != address(0), "ProposalManager: zero address");
        proposalManager = newProposalManager;
    }

    /**
     * @inheritdoc IProposalManager
     */
    function createProposal(
        bytes32 contentHash,
        string calldata metadata
    ) external returns (uint256 proposalId) {
        if (contentHash == bytes32(0)) {
            revert InvalidContentHash();
        }
        if (bytes(metadata).length == 0) {
            revert EmptyMetadata();
        }

        proposalId = ++proposalCounter;

        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            contentHash: contentHash,
            metadata: metadata,
            state: ProposalState.Proposed,
            createdAt: block.timestamp,
            challengeWindowEnd: 0,
            validatorApprovals: 0,
            llmValidated: false
        });

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
        if (proposal.id == 0) {
            revert ProposalNotFound();
        }
        if (proposal.state != ProposalState.Proposed) {
            revert InvalidStateTransition();
        }

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
        if (proposal.id == 0) {
            revert ProposalNotFound();
        }
        if (proposal.state != ProposalState.OptimisticApproved) {
            revert ProposalNotChallengeable();
        }
        if (block.number > proposal.challengeWindowEnd) {
            revert ChallengeWindowExpired();
        }

        proposal.state = ProposalState.Challenged;
        _updateProposalStateArrays(proposalId, ProposalState.OptimisticApproved, ProposalState.Challenged);

        emit ProposalChallenged(proposalId, msg.sender);
    }

    /**
     * @inheritdoc IProposalManager
     */
    function finalizeProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.id == 0) {
            revert ProposalNotFound();
        }
        if (proposal.state != ProposalState.OptimisticApproved) {
            revert InvalidStateTransition();
        }
        if (block.number <= proposal.challengeWindowEnd) {
            revert ChallengeWindowActive();
        }

        proposal.state = ProposalState.Finalized;
        _updateProposalStateArrays(proposalId, ProposalState.OptimisticApproved, ProposalState.Finalized);

        emit ProposalFinalized(proposalId, ProposalState.Finalized);
    }

    /**
     * @inheritdoc IProposalManager
     */
    function rejectProposal(uint256 proposalId, string calldata reason) external onlyProposalManager {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.id == 0) {
            revert ProposalNotFound();
        }
        if (proposal.state == ProposalState.Finalized || proposal.state == ProposalState.Rejected) {
            revert InvalidStateTransition();
        }

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
        if (proposal.id == 0) {
            revert ProposalNotFound();
        }

        proposal.llmValidated = validated;
    }

    /**
     * @inheritdoc IProposalManager
     */
    function recordValidatorApproval(uint256 proposalId) external onlyActiveValidator {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.id == 0) {
            revert ProposalNotFound();
        }
        if (proposal.state != ProposalState.Proposed && proposal.state != ProposalState.OptimisticApproved) {
            revert InvalidStateTransition();
        }

        proposal.validatorApprovals++;
    }

    /**
     * @inheritdoc IProposalManager
     */
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        Proposal memory proposal = proposals[proposalId];
        if (proposal.id == 0) {
            revert ProposalNotFound();
        }
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
        return proposal.id != 0 &&
            proposal.state == ProposalState.OptimisticApproved &&
            block.number <= proposal.challengeWindowEnd;
    }

    /**
     * @inheritdoc IProposalManager
     */
    function canFinalize(uint256 proposalId) external view returns (bool) {
        Proposal memory proposal = proposals[proposalId];
        return proposal.id != 0 &&
            proposal.state == ProposalState.OptimisticApproved &&
            block.number > proposal.challengeWindowEnd;
    }

    /**
     * @dev Updates the proposal state arrays when state changes.
     * @param proposalId The ID of the proposal.
     * @param fromState The previous state.
     * @param toState The new state.
     */
    function _updateProposalStateArrays(
        uint256 proposalId,
        ProposalState fromState,
        ProposalState toState
    ) private {
        // Remove from old state array
        uint256[] storage fromArray = proposalsByState[fromState];
        for (uint256 i = 0; i < fromArray.length; i++) {
            if (fromArray[i] == proposalId) {
                fromArray[i] = fromArray[fromArray.length - 1];
                fromArray.pop();
                break;
            }
        }

        // Add to new state array
        proposalsByState[toState].push(proposalId);
    }
}