// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IDisputeResolver } from "./interfaces/IDisputeResolver.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";
import { IProposalManager } from "./interfaces/IProposalManager.sol";

/**
 * @title DisputeResolver
 * @dev Handles dispute resolution for challenged proposals in the GenLayer system.
 * Manages challenge stakes, voting, slashing, and reward distribution.
 */
contract DisputeResolver is IDisputeResolver, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /**
     * @dev Minimum challenge stake (100 GLT).
     */
    uint256 public constant MINIMUM_CHALLENGE_STAKE = 100e18;

    /**
     * @dev Dispute voting period duration (50 blocks).
     */
    uint256 public constant DISPUTE_VOTING_PERIOD = 50;

    /**
     * @dev Slash percentage for losing disputes (10%).
     */
    uint256 public constant SLASH_PERCENTAGE = 10;

    /**
     * @dev Counter for dispute IDs.
     */
    uint256 private disputeCounter;

    /**
     * @dev Mapping from dispute ID to dispute data.
     */
    mapping(uint256 => Dispute) private disputes;

    /**
     * @dev Mapping from proposal ID to dispute IDs.
     */
    mapping(uint256 => uint256[]) private proposalToDisputes;

    /**
     * @dev Mapping from dispute ID and validator to vote data.
     */
    mapping(uint256 => mapping(address => DisputeVote)) private disputeVotes;

    /**
     * @dev Mapping to track if validator has voted on a dispute.
     */
    mapping(uint256 => mapping(address => bool)) private hasVoted;

    /**
     * @dev GLT token contract.
     */
    IERC20 public immutable gltToken;

    /**
     * @dev Validator registry contract.
     */
    IValidatorRegistry public immutable validatorRegistry;

    /**
     * @dev Proposal manager contract.
     */
    IProposalManager public immutable proposalManager;

    /**
     * @dev Modifier to restrict functions to active validators.
     */
    modifier onlyActiveValidator() {
        require(
            validatorRegistry.isActiveValidator(msg.sender),
            "DisputeResolver: caller is not an active validator"
        );
        _;
    }

    /**
     * @dev Initializes the DisputeResolver with required contracts.
     * @param _gltToken Address of the GLT token contract.
     * @param _validatorRegistry Address of the validator registry contract.
     * @param _proposalManager Address of the proposal manager contract.
     */
    constructor(
        address _gltToken,
        address _validatorRegistry,
        address _proposalManager
    ) Ownable(msg.sender) {
        require(
            _gltToken != address(0) && 
            _validatorRegistry != address(0) && 
            _proposalManager != address(0),
            "DisputeResolver: zero address"
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
    ) external onlyActiveValidator nonReentrant returns (uint256 disputeId) {
        if (challengeStake == 0) {
            revert ZeroChallengeStake();
        }
        if (challengeStake < MINIMUM_CHALLENGE_STAKE) {
            revert InsufficientChallengeStake();
        }

        // Verify proposal can be disputed
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        if (proposal.state != IProposalManager.ProposalState.OptimisticApproved) {
            revert ProposalNotDisputable();
        }
        if (!proposalManager.canChallenge(proposalId)) {
            revert ProposalNotDisputable();
        }

        // Transfer challenge stake from challenger
        gltToken.safeTransferFrom(msg.sender, address(this), challengeStake);

        disputeId = ++disputeCounter;

        disputes[disputeId] = Dispute({
            proposalId: proposalId,
            challenger: msg.sender,
            proposer: proposal.proposer,
            challengeStake: challengeStake,
            state: DisputeState.Active,
            createdAt: block.timestamp,
            votingEndTime: block.timestamp + DISPUTE_VOTING_PERIOD,
            votesFor: 0,
            votesAgainst: 0,
            challengerWon: false,
            slashAmount: 0
        });

        proposalToDisputes[proposalId].push(disputeId);

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
    ) external onlyActiveValidator nonReentrant {
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

        // Verify signature
        if (!_verifyDisputeVoteSignature(disputeId, msg.sender, supportChallenge, signature)) {
            revert("DisputeResolver: invalid signature");
        }

        // Record vote
        hasVoted[disputeId][msg.sender] = true;
        disputeVotes[disputeId][msg.sender] = DisputeVote({
            validator: msg.sender,
            supportChallenge: supportChallenge,
            signature: signature,
            timestamp: block.timestamp
        });

        // Update vote counts
        if (supportChallenge) {
            dispute.votesFor++;
        } else {
            dispute.votesAgainst++;
        }

        emit DisputeVoteCast(disputeId, msg.sender, supportChallenge);
    }

    /**
     * @inheritdoc IDisputeResolver
     */
    function resolveDispute(uint256 disputeId) external nonReentrant {
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

        dispute.state = DisputeState.VotingComplete;

        // Determine outcome based on votes
        bool challengerWon = dispute.votesFor > dispute.votesAgainst;
        dispute.challengerWon = challengerWon;

        // Calculate slash amount (10% of challenge stake)
        uint256 slashAmount = (dispute.challengeStake * SLASH_PERCENTAGE) / 100;
        dispute.slashAmount = slashAmount;

        if (challengerWon) {
            // Challenger wins - slash proposer and reward challenger
            // Get proposer's staked amount from validator registry
            IValidatorRegistry.ValidatorInfo memory proposerInfo = validatorRegistry.getValidatorInfo(dispute.proposer);
            
            // Slash proposer in validator registry
            uint256 actualSlashAmount = 0;
            if (proposerInfo.stakedAmount > 0) {
                actualSlashAmount = slashAmount > proposerInfo.stakedAmount ? proposerInfo.stakedAmount : slashAmount;
                validatorRegistry.slashValidator(dispute.proposer, actualSlashAmount, "Lost dispute");
                dispute.slashAmount = actualSlashAmount;
            }

            // Return challenge stake to challenger
            // Note: The slashed amount stays in ValidatorRegistry, so we only return the challenge stake
            gltToken.safeTransfer(dispute.challenger, dispute.challengeStake);
            
            emit RewardDistributed(disputeId, dispute.challenger, dispute.challengeStake);
            
            // Note: The proposal should be rejected by ProposalManager separately
        } else {
            // Proposer wins - slash challenger stake and reward proposer
            uint256 rewardAmount = dispute.challengeStake - slashAmount;
            
            // Transfer reward to proposer
            gltToken.safeTransfer(dispute.proposer, rewardAmount);
            
            emit RewardDistributed(disputeId, dispute.proposer, rewardAmount);
            
            // Burn slashed amount (or transfer to treasury)
            // For now, we'll transfer to owner as treasury
            gltToken.safeTransfer(owner(), slashAmount);
        }

        dispute.state = DisputeState.Resolved;

        emit DisputeResolved(disputeId, challengerWon, slashAmount);
    }

    /**
     * @inheritdoc IDisputeResolver
     */
    function cancelDispute(uint256 disputeId, string calldata /* reason */) external onlyOwner {
        Dispute storage dispute = disputes[disputeId];
        if (dispute.proposalId == 0) {
            revert DisputeNotFound();
        }
        if (dispute.state != DisputeState.Active) {
            revert InvalidDisputeState();
        }

        dispute.state = DisputeState.Cancelled;

        // Return challenge stake to challenger
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
    ) external view returns (bool voted, bool supportChallenge) {
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
        return dispute.proposalId != 0 &&
               dispute.state == DisputeState.Active &&
               block.timestamp > dispute.votingEndTime;
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
    ) private view returns (bool) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "GenLayerDisputeVote",
                disputeId,
                validator,
                supportChallenge,
                address(this),
                block.chainid
            )
        );
        
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address recoveredSigner = ethSignedMessageHash.recover(signature);
        
        return recoveredSigner == validator;
    }
}