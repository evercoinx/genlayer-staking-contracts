// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IDisputeResolver } from "./interfaces/IDisputeResolver.sol";
import { IProposalManager } from "./interfaces/IProposalManager.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";

/**
 * @title DisputeResolver
 * @dev Handles dispute resolution for challenged proposals in the GenLayer system.
 * Manages challenge stakes, voting, slashing, and reward distribution.
 */
contract DisputeResolver is IDisputeResolver, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    uint256 public constant MINIMUM_CHALLENGE_STAKE = 100e18;
    uint256 public constant DISPUTE_VOTING_PERIOD = 50;
    uint256 public constant SLASH_PERCENTAGE = 10;
    uint256 private constant PERCENTAGE_DIVISOR = 100;
    uint256 private constant VOTE_THRESHOLD_DIVISOR = 2; // 50% threshold

    uint256 private disputeCounter;
    mapping(uint256 => Dispute) private disputes;
    mapping(uint256 => uint256[]) private proposalToDisputes;
    mapping(uint256 => mapping(address => DisputeVote)) private disputeVotes;
    mapping(uint256 => mapping(address => bool)) private hasVoted;

    IERC20 public immutable gltToken;
    IValidatorRegistry public immutable validatorRegistry;
    IProposalManager public immutable proposalManager;

    modifier onlyActiveValidator() {
        require(validatorRegistry.isActiveValidator(msg.sender), CallerNotActiveValidator());
        _;
    }

    /**
     * @dev Initializes the DisputeResolver with required contracts.
     * @param _gltToken Address of the GLT token contract.
     * @param _validatorRegistry Address of the validator registry contract.
     * @param _proposalManager Address of the proposal manager contract.
     */
    constructor(address _gltToken, address _validatorRegistry, address _proposalManager) Ownable(msg.sender) {
        require(
            _gltToken != address(0) && _validatorRegistry != address(0) && _proposalManager != address(0), ZeroAddress()
        );
        gltToken = IERC20(_gltToken);
        validatorRegistry = IValidatorRegistry(_validatorRegistry);
        proposalManager = IProposalManager(_proposalManager);
    }

    /**
     * @inheritdoc IDisputeResolver
     */
    function createDispute(
        uint256 proposalId,
        uint256 challengeStake
    )
        external
        onlyActiveValidator
        nonReentrant
        returns (uint256 disputeId)
    {
        _validateChallengeStake(challengeStake);
        IProposalManager.Proposal memory proposal = _validateProposalDisputable(proposalId);
        gltToken.safeTransferFrom(msg.sender, address(this), challengeStake);
        disputeId = _createDisputeRecord(proposalId, proposal.proposer, challengeStake);

        emit DisputeCreated(disputeId, proposalId, msg.sender, challengeStake);

        return disputeId;
    }

    /**
     * @inheritdoc IDisputeResolver
     */
    function voteOnDispute(
        uint256 disputeId,
        bool supportChallenge,
        bytes calldata signature
    )
        external
        onlyActiveValidator
        nonReentrant
    {
        Dispute storage dispute = _validateVotingEligibility(disputeId);

        if (!_verifyDisputeVoteSignature(disputeId, msg.sender, supportChallenge, signature)) {
            revert InvalidSignature();
        }

        _recordVote(disputeId, dispute, supportChallenge, signature);

        emit DisputeVoteCast(disputeId, msg.sender, supportChallenge);
    }

    /**
     * @inheritdoc IDisputeResolver
     */
    function resolveDispute(uint256 disputeId) external nonReentrant {
        Dispute storage dispute = _validateDisputeResolvable(disputeId);

        dispute.state = DisputeState.VotingComplete;

        bool challengerWon = _determineDisputeOutcome(dispute);
        uint256 slashAmount = _calculateSlashAmount(dispute.challengeStake);

        dispute.challengerWon = challengerWon;
        dispute.slashAmount = slashAmount;

        _processDisputeResolution(disputeId, dispute, challengerWon, slashAmount);

        dispute.state = DisputeState.Resolved;

        emit DisputeResolved(disputeId, challengerWon, slashAmount);
    }

    /**
     * @inheritdoc IDisputeResolver
     */
    function cancelDispute(uint256 disputeId, string calldata /* reason */ ) external onlyOwner {
        Dispute storage dispute = disputes[disputeId];
        if (dispute.proposalId == 0) {
            revert DisputeNotFound();
        }
        if (dispute.state != DisputeState.Active) {
            revert InvalidDisputeState();
        }

        dispute.state = DisputeState.Cancelled;

        gltToken.safeTransfer(dispute.challenger, dispute.challengeStake);

        emit DisputeResolved(disputeId, false, 0);
    }

    /**
     * @inheritdoc IDisputeResolver
     */
    function getDispute(uint256 disputeId) external view returns (Dispute memory) {
        Dispute memory dispute = disputes[disputeId];
        if (dispute.proposalId == 0) {
            revert DisputeNotFound();
        }
        return dispute;
    }

    /**
     * @inheritdoc IDisputeResolver
     */
    function getDisputesByProposal(uint256 proposalId) external view returns (uint256[] memory) {
        return proposalToDisputes[proposalId];
    }

    /**
     * @inheritdoc IDisputeResolver
     */
    function getDisputeVote(
        uint256 disputeId,
        address validator
    )
        external
        view
        returns (bool voted, bool supportChallenge)
    {
        voted = hasVoted[disputeId][validator];
        if (voted) {
            supportChallenge = disputeVotes[disputeId][validator].supportChallenge;
        }
    }

    /**
     * @inheritdoc IDisputeResolver
     */
    function getMinimumChallengeStake() external pure returns (uint256) {
        return MINIMUM_CHALLENGE_STAKE;
    }

    /**
     * @inheritdoc IDisputeResolver
     */
    function getDisputeVotingPeriod() external pure returns (uint256) {
        return DISPUTE_VOTING_PERIOD;
    }

    /**
     * @inheritdoc IDisputeResolver
     */
    function getSlashPercentage() external pure returns (uint256) {
        return SLASH_PERCENTAGE;
    }

    /**
     * @inheritdoc IDisputeResolver
     */
    function canResolveDispute(uint256 disputeId) external view returns (bool) {
        Dispute memory dispute = disputes[disputeId];
        return
            dispute.proposalId != 0 && dispute.state == DisputeState.Active && block.timestamp > dispute.votingEndTime;
    }

    /**
     * @inheritdoc IDisputeResolver
     */
    function getTotalDisputes() external view returns (uint256) {
        return disputeCounter;
    }

    /**
     * @dev Verifies a dispute vote signature.
     * @param disputeId The dispute ID.
     * @param validator The validator address.
     * @param supportChallenge Whether supporting the challenge.
     * @param signature The signature to verify.
     * @return True if the signature is valid.
     */
    function _verifyDisputeVoteSignature(
        uint256 disputeId,
        address validator,
        bool supportChallenge,
        bytes memory signature
    )
        private
        view
        returns (bool)
    {
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "GenLayerDisputeVote", disputeId, validator, supportChallenge, address(this), block.chainid
            )
        );

        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address recoveredSigner = ethSignedMessageHash.recover(signature);

        return recoveredSigner == validator;
    }

    /**
     * @dev Validates the challenge stake amount.
     * @param challengeStake The stake amount to validate.
     */
    function _validateChallengeStake(uint256 challengeStake) private pure {
        if (challengeStake == 0) {
            revert ZeroChallengeStake();
        }
        if (challengeStake < MINIMUM_CHALLENGE_STAKE) {
            revert InsufficientChallengeStake();
        }
    }

    /**
     * @dev Validates that a proposal can be disputed.
     * @param proposalId The proposal ID to validate.
     * @return proposal The proposal details.
     */
    function _validateProposalDisputable(uint256 proposalId) private view returns (IProposalManager.Proposal memory) {
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        if (proposal.state != IProposalManager.ProposalState.OptimisticApproved) {
            revert ProposalNotDisputable();
        }
        if (!proposalManager.canChallenge(proposalId)) {
            revert ProposalNotDisputable();
        }
        return proposal;
    }

    /**
     * @dev Creates a new dispute record.
     * @param proposalId The proposal ID.
     * @param proposer The proposer address.
     * @param challengeStake The challenge stake amount.
     * @return disputeId The created dispute ID.
     */
    function _createDisputeRecord(
        uint256 proposalId,
        address proposer,
        uint256 challengeStake
    )
        private
        returns (uint256)
    {
        uint256 disputeId = ++disputeCounter;
        uint256 currentTime = block.timestamp;

        disputes[disputeId] = Dispute({
            proposalId: proposalId,
            challenger: msg.sender,
            proposer: proposer,
            challengeStake: challengeStake,
            state: DisputeState.Active,
            createdAt: currentTime,
            votingEndTime: currentTime + DISPUTE_VOTING_PERIOD,
            votesFor: 0,
            votesAgainst: 0,
            challengerWon: false,
            slashAmount: 0
        });

        proposalToDisputes[proposalId].push(disputeId);

        return disputeId;
    }

    /**
     * @dev Validates dispute exists and voting is eligible.
     * @param disputeId The dispute ID.
     * @return dispute The dispute storage reference.
     */
    function _validateVotingEligibility(uint256 disputeId) private view returns (Dispute storage) {
        Dispute storage dispute = disputes[disputeId];
        if (dispute.proposalId == 0) {
            revert DisputeNotFound();
        }
        if (dispute.state != DisputeState.Active) {
            revert InvalidDisputeState();
        }
        if (block.timestamp > dispute.votingEndTime) {
            revert DisputeVotingEnded();
        }
        if (hasVoted[disputeId][msg.sender]) {
            revert ValidatorAlreadyVoted();
        }
        return dispute;
    }

    /**
     * @dev Records a vote on a dispute.
     * @param disputeId The dispute ID.
     * @param dispute The dispute storage reference.
     * @param supportChallenge Whether supporting the challenge.
     * @param signature The vote signature.
     */
    function _recordVote(
        uint256 disputeId,
        Dispute storage dispute,
        bool supportChallenge,
        bytes calldata signature
    )
        private
    {
        hasVoted[disputeId][msg.sender] = true;
        disputeVotes[disputeId][msg.sender] = DisputeVote({
            validator: msg.sender,
            supportChallenge: supportChallenge,
            signature: signature,
            timestamp: block.timestamp
        });

        if (supportChallenge) {
            dispute.votesFor++;
        } else {
            dispute.votesAgainst++;
        }
    }

    /**
     * @dev Validates that a dispute can be resolved.
     * @param disputeId The dispute ID.
     * @return dispute The dispute storage reference.
     */
    function _validateDisputeResolvable(uint256 disputeId) private view returns (Dispute storage) {
        Dispute storage dispute = disputes[disputeId];
        if (dispute.proposalId == 0) {
            revert DisputeNotFound();
        }
        if (dispute.state != DisputeState.Active) {
            revert InvalidDisputeState();
        }
        if (block.timestamp <= dispute.votingEndTime) {
            revert DisputeVotingActive();
        }
        return dispute;
    }

    /**
     * @dev Determines the outcome of a dispute based on voting.
     * @param dispute The dispute data.
     * @return challengerWon Whether the challenger won.
     */
    function _determineDisputeOutcome(Dispute storage dispute) private view returns (bool) {
        uint256 totalActiveValidators = validatorRegistry.getActiveValidators().length;
        // At least 50% of validators must vote to reject (support the challenge)
        // Using multiplication to avoid division rounding issues
        return dispute.votesFor * VOTE_THRESHOLD_DIVISOR >= totalActiveValidators;
    }

    /**
     * @dev Calculates the slash amount.
     * @param challengeStake The challenge stake amount.
     * @return slashAmount The calculated slash amount.
     */
    function _calculateSlashAmount(uint256 challengeStake) private pure returns (uint256) {
        return (challengeStake * SLASH_PERCENTAGE) / PERCENTAGE_DIVISOR;
    }

    /**
     * @dev Processes the dispute resolution, handling rewards and penalties.
     * @param disputeId The dispute ID.
     * @param dispute The dispute data.
     * @param challengerWon Whether the challenger won.
     * @param slashAmount The slash amount.
     */
    function _processDisputeResolution(
        uint256 disputeId,
        Dispute storage dispute,
        bool challengerWon,
        uint256 slashAmount
    )
        private
    {
        if (challengerWon) {
            _processChallengerVictory(disputeId, dispute, slashAmount);
        } else {
            _processProposerVictory(disputeId, dispute, slashAmount);
        }
    }

    /**
     * @dev Processes the case where the challenger wins.
     * @param disputeId The dispute ID.
     * @param dispute The dispute data.
     * @param slashAmount The slash amount.
     */
    function _processChallengerVictory(uint256 disputeId, Dispute storage dispute, uint256 slashAmount) private {
        // Check if proposer is a validator before trying to slash
        if (validatorRegistry.isActiveValidator(dispute.proposer)) {
            IValidatorRegistry.ValidatorInfo memory proposerInfo = validatorRegistry.getValidatorInfo(dispute.proposer);

            if (proposerInfo.stakedAmount > 0) {
                uint256 actualSlashAmount =
                    slashAmount > proposerInfo.stakedAmount ? proposerInfo.stakedAmount : slashAmount;
                validatorRegistry.slashValidator(dispute.proposer, actualSlashAmount, "Lost dispute");
                dispute.slashAmount = actualSlashAmount;
            }
        }

        gltToken.safeTransfer(dispute.challenger, dispute.challengeStake);
        emit RewardDistributed(disputeId, dispute.challenger, dispute.challengeStake);
    }

    /**
     * @dev Processes the case where the proposer wins.
     * @param disputeId The dispute ID.
     * @param dispute The dispute data.
     * @param slashAmount The slash amount.
     */
    function _processProposerVictory(uint256 disputeId, Dispute storage dispute, uint256 slashAmount) private {
        uint256 rewardAmount = dispute.challengeStake - slashAmount;

        gltToken.safeTransfer(dispute.proposer, rewardAmount);
        emit RewardDistributed(disputeId, dispute.proposer, rewardAmount);

        // Slashed amount goes to treasury (owner)
        gltToken.safeTransfer(owner(), slashAmount);
    }
}
