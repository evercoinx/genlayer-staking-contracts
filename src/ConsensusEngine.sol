// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IConsensusEngine } from "./interfaces/IConsensusEngine.sol";
import { IProposalManager } from "./interfaces/IProposalManager.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";

/**
 * @title ConsensusEngine
 * @dev Orchestrates the consensus mechanism for the GenLayer system.
 * Manages voting rounds, signature validation, and consensus finalization.
 */
contract ConsensusEngine is IConsensusEngine, Ownable, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /**
     * @dev Voting period duration in blocks.
     */
    uint256 public constant VOTING_PERIOD = 100;

    /**
     * @dev Quorum percentage required for consensus (60% - at least 3/5 validators as per PRD).
     */
    uint256 public constant QUORUM_PERCENTAGE = 60;

    /**
     * @dev Counter for consensus round IDs.
     */
    uint256 private roundCounter;

    /**
     * @dev Mapping from round ID to consensus round data.
     */
    mapping(uint256 => ConsensusRound) private consensusRounds;

    /**
     * @dev Mapping from proposal ID to current round ID.
     */
    mapping(uint256 => uint256) private proposalToCurrentRound;

    /**
     * @dev Mapping from round ID and validator to vote data.
     */
    mapping(uint256 => mapping(address => Vote)) private roundVotes;

    /**
     * @dev Validator registry contract.
     */
    IValidatorRegistry public immutable validatorRegistry;

    /**
     * @dev Proposal manager contract.
     */
    IProposalManager public immutable proposalManager;

    /**
     * @dev Address authorized to initiate consensus.
     */
    address public consensusInitiator;

    /**
     * @dev Modifier to restrict functions to active validators.
     */
    modifier onlyActiveValidator() {
        if (!validatorRegistry.isActiveValidator(msg.sender)) {
            revert NotActiveValidator();
        }
        _;
    }

    /**
     * @dev Modifier to restrict functions to consensus initiator.
     */
    modifier onlyConsensusInitiator() {
        if (msg.sender != consensusInitiator) {
            revert CallerNotConsensusInitiator();
        }
        _;
    }

    /**
     * @dev Modifier to validate round exists.
     */
    modifier roundExists(uint256 roundId) {
        if (consensusRounds[roundId].proposalId == 0) {
            revert RoundNotFound();
        }
        _;
    }

    /**
     * @dev Modifier to validate round is not finalized.
     */
    modifier roundNotFinalized(uint256 roundId) {
        if (consensusRounds[roundId].finalized) {
            revert RoundAlreadyFinalized();
        }
        _;
    }

    /**
     * @dev Initializes the ConsensusEngine with required contracts.
     * @param _validatorRegistry Address of the validator registry contract.
     * @param _proposalManager Address of the proposal manager contract.
     * @param _consensusInitiator Address authorized to initiate consensus.
     */
    constructor(
        address _validatorRegistry,
        address _proposalManager,
        address _consensusInitiator
    ) Ownable(msg.sender) {
        if (_validatorRegistry == address(0) || 
            _proposalManager == address(0) || 
            _consensusInitiator == address(0)) {
            revert ZeroAddress();
        }
        validatorRegistry = IValidatorRegistry(_validatorRegistry);
        proposalManager = IProposalManager(_proposalManager);
        consensusInitiator = _consensusInitiator;
    }

    /**
     * @dev Sets a new consensus initiator address. Only callable by owner.
     * @param newInitiator The address to grant consensus initiation privileges to.
     */
    function setConsensusInitiator(address newInitiator) external onlyOwner {
        if (newInitiator == address(0)) {
            revert ZeroAddress();
        }
        consensusInitiator = newInitiator;
    }

    /**
     * @inheritdoc IConsensusEngine
     */
    function initiateConsensus(uint256 proposalId) external onlyConsensusInitiator returns (uint256 roundId) {
        // Verify proposal exists and is in appropriate state
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        if (proposal.state != IProposalManager.ProposalState.Challenged) {
            revert ProposalNotInChallengedState();
        }

        // Check if proposal already has active round
        uint256 currentRound = proposalToCurrentRound[proposalId];
        if (currentRound != 0) {
            ConsensusRound storage existingRound = consensusRounds[currentRound];
            if (!existingRound.finalized) {
                revert ProposalAlreadyInConsensus();
            }
        }

        roundId = ++roundCounter;
        
        ConsensusRound storage newRound = consensusRounds[roundId];
        newRound.proposalId = proposalId;
        newRound.startBlock = block.number;
        newRound.endBlock = block.number + VOTING_PERIOD;
        newRound.votesFor = 0;
        newRound.votesAgainst = 0;
        newRound.finalized = false;

        proposalToCurrentRound[proposalId] = roundId;

        emit ConsensusRoundStarted(proposalId, roundId, newRound.startBlock, newRound.endBlock);

        return roundId;
    }

    /**
     * @inheritdoc IConsensusEngine
     */
    function castVote(
        uint256 roundId,
        bool support,
        bytes calldata signature
    ) external onlyActiveValidator nonReentrant roundExists(roundId) roundNotFinalized(roundId) {
        ConsensusRound storage round = consensusRounds[roundId];
        if (block.number > round.endBlock) {
            revert VotingPeriodEnded();
        }
        if (round.hasVoted[msg.sender]) {
            revert AlreadyVoted();
        }

        // Verify signature
        if (!_verifyVoteSignature(roundId, msg.sender, support, signature)) {
            revert InvalidSignature();
        }

        // Record vote
        round.hasVoted[msg.sender] = true;
        roundVotes[roundId][msg.sender] = Vote({
            validator: msg.sender,
            support: support,
            signature: signature,
            timestamp: block.timestamp
        });

        // Update vote counts
        if (support) {
            round.votesFor++;
        } else {
            round.votesAgainst++;
        }

        emit VoteCast(roundId, msg.sender, support);
    }

    /**
     * @inheritdoc IConsensusEngine
     */
    function finalizeConsensus(uint256 roundId) external nonReentrant roundExists(roundId) roundNotFinalized(roundId) returns (bool approved) {
        ConsensusRound storage round = consensusRounds[roundId];
        if (block.number <= round.endBlock) {
            revert VotingPeriodActive();
        }

        round.finalized = true;

        // Calculate if proposal is approved
        address[] memory activeValidators = validatorRegistry.getActiveValidators();
        uint256 totalValidators = activeValidators.length;
        uint256 totalVotes = round.votesFor + round.votesAgainst;

        // Check quorum
        bool hasQuorum = (totalVotes * 100) >= (totalValidators * QUORUM_PERCENTAGE);
        
        // Proposal is approved if it has quorum and majority support
        approved = hasQuorum && (round.votesFor > round.votesAgainst);

        emit ConsensusFinalized(roundId, round.proposalId, approved, round.votesFor, round.votesAgainst);

        return approved;
    }

    /**
     * @inheritdoc IConsensusEngine
     */
    function getCurrentRound(uint256 proposalId) external view returns (uint256) {
        return proposalToCurrentRound[proposalId];
    }

    /**
     * @inheritdoc IConsensusEngine
     */
    function getVote(
        uint256 roundId,
        address validator
    ) external view returns (bool hasVoted, bool support) {
        ConsensusRound storage round = consensusRounds[roundId];
        hasVoted = round.hasVoted[validator];
        if (hasVoted) {
            support = roundVotes[roundId][validator].support;
        }
    }

    /**
     * @inheritdoc IConsensusEngine
     */
    function getVoteCounts(
        uint256 roundId
    ) external view roundExists(roundId) returns (uint256 votesFor, uint256 votesAgainst, uint256 totalValidators) {
        ConsensusRound storage round = consensusRounds[roundId];
        votesFor = round.votesFor;
        votesAgainst = round.votesAgainst;
        totalValidators = validatorRegistry.getActiveValidators().length;
    }

    /**
     * @inheritdoc IConsensusEngine
     */
    function getVotingPeriod() external pure returns (uint256) {
        return VOTING_PERIOD;
    }

    /**
     * @inheritdoc IConsensusEngine
     */
    function getQuorumPercentage() external pure returns (uint256) {
        return QUORUM_PERCENTAGE;
    }

    /**
     * @inheritdoc IConsensusEngine
     */
    function canFinalizeRound(uint256 roundId) external view returns (bool) {
        ConsensusRound storage round = consensusRounds[roundId];
        return round.proposalId != 0 && 
               !round.finalized && 
               block.number > round.endBlock;
    }

    /**
     * @inheritdoc IConsensusEngine
     */
    function verifyVoteSignature(
        uint256 roundId,
        address validator,
        bool support,
        bytes calldata signature
    ) external view returns (bool) {
        return _verifyVoteSignature(roundId, validator, support, signature);
    }

    /**
     * @dev Internal function to verify a vote signature.
     * @param roundId The consensus round ID.
     * @param validator The validator address.
     * @param support The vote support value.
     * @param signature The signature to verify.
     * @return True if the signature is valid.
     */
    function _verifyVoteSignature(
        uint256 roundId,
        address validator,
        bool support,
        bytes memory signature
    ) private view returns (bool) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "GenLayerConsensusVote",
                roundId,
                validator,
                support,
                address(this),
                block.chainid
            )
        );
        
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address recoveredSigner = ethSignedMessageHash.recover(signature);
        
        return recoveredSigner == validator;
    }
}