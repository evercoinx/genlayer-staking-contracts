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

    uint256 public constant VOTING_PERIOD = 100;
    uint256 public constant QUORUM_PERCENTAGE = 60;

    IValidatorRegistry public immutable validatorRegistry;
    IProposalManager public immutable proposalManager;

    address public consensusInitiator;

    uint256 private roundCounter;
    mapping(uint256 => ConsensusRound) private consensusRounds;
    mapping(uint256 => uint256) private proposalToCurrentRound;
    mapping(uint256 => mapping(address => Vote)) private roundVotes;

    modifier onlyActiveValidator() {
        require(validatorRegistry.isActiveValidator(msg.sender), NotActiveValidator());
        _;
    }

    modifier onlyConsensusInitiator() {
        require(msg.sender == consensusInitiator, CallerNotConsensusInitiator());
        _;
    }

    modifier roundExists(uint256 roundId) {
        require(consensusRounds[roundId].proposalId != 0, RoundNotFound());
        _;
    }

    modifier roundNotFinalized(uint256 roundId) {
        require(!consensusRounds[roundId].finalized, RoundAlreadyFinalized());
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
    )
        Ownable(msg.sender)
    {
        require(_validatorRegistry != address(0), ZeroValidatorRegistry());
        require(_proposalManager != address(0), ZeroProposalManager());
        require(_consensusInitiator != address(0), ZeroConsensusInitiator());
        validatorRegistry = IValidatorRegistry(_validatorRegistry);
        proposalManager = IProposalManager(_proposalManager);
        consensusInitiator = _consensusInitiator;
    }

    /**
     * @inheritdoc IConsensusEngine
     */
    function setConsensusInitiator(address newInitiator) external override onlyOwner {
        require(newInitiator != address(0), ZeroConsensusInitiator());
        address oldInitiator = consensusInitiator;
        consensusInitiator = newInitiator;
        emit ConsensusInitiatorUpdated(oldInitiator, newInitiator);
    }

    /**
     * @inheritdoc IConsensusEngine
     */
    function initiateConsensus(uint256 proposalId) external override onlyConsensusInitiator returns (uint256 roundId) {
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        require(proposal.state == IProposalManager.ProposalState.Challenged, ProposalNotInChallengedState());

        uint256 currentRound = proposalToCurrentRound[proposalId];
        if (currentRound != 0) {
            ConsensusRound storage existingRound = consensusRounds[currentRound];
            require(existingRound.finalized, ProposalAlreadyInConsensus());
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
    )
        external
        override
        onlyActiveValidator
        nonReentrant
        roundExists(roundId)
        roundNotFinalized(roundId)
    {
        ConsensusRound storage round = consensusRounds[roundId];
        require(block.number <= round.endBlock, VotingPeriodEnded());
        require(!round.hasVoted[msg.sender], AlreadyVoted());

        require(_verifyVoteSignature(roundId, msg.sender, support, signature), InvalidSignature());

        round.hasVoted[msg.sender] = true;
        roundVotes[roundId][msg.sender] =
            Vote({ validator: msg.sender, support: support, signature: signature, timestamp: block.timestamp });

        if (support) {
            ++round.votesFor;
        } else {
            ++round.votesAgainst;
        }

        emit VoteCast(roundId, msg.sender, support);
    }

    /**
     * @inheritdoc IConsensusEngine
     */
    function finalizeConsensus(uint256 roundId)
        external
        override
        nonReentrant
        roundExists(roundId)
        roundNotFinalized(roundId)
        returns (bool approved)
    {
        ConsensusRound storage round = consensusRounds[roundId];
        require(block.number > round.endBlock, VotingPeriodActive());

        round.finalized = true;

        address[] memory activeValidators = validatorRegistry.getActiveValidators();
        uint256 totalValidators = activeValidators.length;
        uint256 totalVotes = round.votesFor + round.votesAgainst;

        // Check quorum: at least 60% participation required
        bool hasQuorum = (totalVotes * 100) >= (totalValidators * QUORUM_PERCENTAGE);

        // Proposal is approved if it has quorum and majority support
        approved = hasQuorum && (round.votesFor > round.votesAgainst);

        emit ConsensusFinalized(roundId, round.proposalId, approved, round.votesFor, round.votesAgainst);

        return approved;
    }

    /**
     * @inheritdoc IConsensusEngine
     */
    function getCurrentRound(uint256 proposalId) external view override returns (uint256) {
        return proposalToCurrentRound[proposalId];
    }

    /**
     * @inheritdoc IConsensusEngine
     */
    function getVote(uint256 roundId, address validator) external view override returns (bool hasVoted, bool support) {
        ConsensusRound storage round = consensusRounds[roundId];
        hasVoted = round.hasVoted[validator];
        if (hasVoted) {
            support = roundVotes[roundId][validator].support;
        }
    }

    /**
     * @inheritdoc IConsensusEngine
     */
    function getVoteCounts(uint256 roundId)
        external
        view
        override
        roundExists(roundId)
        returns (uint256 votesFor, uint256 votesAgainst, uint256 totalValidators)
    {
        ConsensusRound storage round = consensusRounds[roundId];
        votesFor = round.votesFor;
        votesAgainst = round.votesAgainst;
        totalValidators = validatorRegistry.getActiveValidators().length;
    }

    /**
     * @inheritdoc IConsensusEngine
     */
    function canFinalizeRound(uint256 roundId) external view returns (bool) {
        ConsensusRound storage round = consensusRounds[roundId];
        return round.proposalId != 0 && !round.finalized && block.number > round.endBlock;
    }

    /**
     * @inheritdoc IConsensusEngine
     */
    function verifyVoteSignature(
        uint256 roundId,
        address validator,
        bool support,
        bytes calldata signature
    )
        external
        view
        returns (bool)
    {
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
    )
        private
        view
        returns (bool)
    {
        bytes32 messageHash = keccak256(
            abi.encodePacked("GenLayerConsensusVote", roundId, validator, support, address(this), block.chainid)
        );

        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address recoveredSigner = ethSignedMessageHash.recover(signature);

        return recoveredSigner == validator;
    }
}
