// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IDisputeResolver } from "../../src/interfaces/IDisputeResolver.sol";
import { IValidatorRegistry } from "../../src/interfaces/IValidatorRegistry.sol";
import { IProposalManager } from "../../src/interfaces/IProposalManager.sol";
import { IConsensusEngine } from "../../src/interfaces/IConsensusEngine.sol";
import { DisputeResolver } from "../../src/DisputeResolver.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { ProposalManager } from "../../src/ProposalManager.sol";
import { ConsensusEngine } from "../../src/ConsensusEngine.sol";
import { MockLLMOracle } from "../../src/MockLLMOracle.sol";
import { GLTToken } from "../../src/GLTToken.sol";

/**
 * @title DisputeResolverTest
 * @dev Test suite for DisputeResolver contract.
 */
contract DisputeResolverTest is Test {
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    DisputeResolver public disputeResolver;
    ValidatorRegistry public validatorRegistry;
    ProposalManager public proposalManager;
    ConsensusEngine public consensusEngine;
    MockLLMOracle public llmOracle;
    GLTToken public gltToken;

    address public deployer = address(this);
    address public proposalManagerRole = address(0x2);
    address public consensusInitiator = address(0x3);

    uint256 constant VALIDATOR1_PRIVATE_KEY = 0x1234;
    uint256 constant VALIDATOR2_PRIVATE_KEY = 0x5678;
    uint256 constant VALIDATOR3_PRIVATE_KEY = 0x9ABC;
    uint256 constant VALIDATOR4_PRIVATE_KEY = 0xDEF0;

    address public validator1;
    address public validator2;
    address public validator3;
    address public validator4;
    address public nonValidator = address(0x999);

    uint256 constant MINIMUM_STAKE = 1000e18;
    uint256 constant SLASH_PERCENTAGE = 10; // 10%
    uint256 constant MINIMUM_CHALLENGE_STAKE = 100e18;
    uint256 constant DISPUTE_VOTING_PERIOD = 50;
    uint256 constant CHALLENGE_WINDOW_DURATION = 10;
    uint256 constant VOTING_PERIOD = 100;

    event DisputeCreated(
        uint256 indexed disputeId, uint256 indexed proposalId, address indexed challenger, uint256 challengeStake
    );
    event DisputeVoteCast(uint256 indexed disputeId, address indexed validator, bool supportChallenge);
    event DisputeResolved(uint256 indexed disputeId, bool challengerWon, uint256 slashAmount);
    event RewardDistributed(uint256 indexed disputeId, address indexed recipient, uint256 amount);

    function setUp() public {
        validator1 = vm.addr(VALIDATOR1_PRIVATE_KEY);
        validator2 = vm.addr(VALIDATOR2_PRIVATE_KEY);
        validator3 = vm.addr(VALIDATOR3_PRIVATE_KEY);
        validator4 = vm.addr(VALIDATOR4_PRIVATE_KEY);

        gltToken = new GLTToken(deployer);

        validatorRegistry = new ValidatorRegistry(address(gltToken), deployer);

        llmOracle = new MockLLMOracle();

        proposalManager = new ProposalManager(address(validatorRegistry), address(llmOracle), proposalManagerRole);

        consensusEngine = new ConsensusEngine(address(validatorRegistry), address(proposalManager), consensusInitiator);

        disputeResolver = new DisputeResolver(address(gltToken), address(validatorRegistry), address(proposalManager));

        validatorRegistry.setSlasher(address(disputeResolver));

        setupValidator(validator1, 3000e18);
        setupValidator(validator2, 2500e18);
        setupValidator(validator3, 2000e18);
        setupValidator(validator4, 1500e18);

        gltToken.mint(validator1, 1000e18);
        gltToken.mint(validator2, 1000e18);
        gltToken.mint(validator3, 1000e18);
        gltToken.mint(validator4, 1000e18);

        vm.prank(validator1);
        gltToken.approve(address(disputeResolver), type(uint256).max);
        vm.prank(validator2);
        gltToken.approve(address(disputeResolver), type(uint256).max);
        vm.prank(validator3);
        gltToken.approve(address(disputeResolver), type(uint256).max);
        vm.prank(validator4);
        gltToken.approve(address(disputeResolver), type(uint256).max);
    }

    function setupValidator(address validator, uint256 stake) internal {
        gltToken.mint(validator, stake + 1000e18);
        vm.prank(validator);
        gltToken.approve(address(validatorRegistry), type(uint256).max);
        vm.prank(validator);
        validatorRegistry.registerValidator(stake);
    }

    function _createVoteSignature(
        uint256 privateKey,
        uint256 disputeId,
        bool supportChallenge
    )
        internal
        view
        returns (bytes memory)
    {
        address validator = vm.addr(privateKey);
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "GenLayerDisputeVote", disputeId, validator, supportChallenge, address(disputeResolver), block.chainid
            )
        );
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedMessageHash);
        return abi.encodePacked(r, s, v);
    }

    function _createOptimisticallyApprovedProposal() internal returns (uint256) {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test proposal"), "Test Proposal");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        return proposalId;
    }

    // === Constructor Tests ===
    function test_Constructor_RevertIfZeroGLTToken() public {
        vm.expectRevert(IDisputeResolver.ZeroGLTToken.selector);
        new DisputeResolver(address(0), address(validatorRegistry), address(proposalManager));
    }

    function test_Constructor_RevertIfZeroValidatorRegistry() public {
        vm.expectRevert(IDisputeResolver.ZeroValidatorRegistry.selector);
        new DisputeResolver(address(gltToken), address(0), address(proposalManager));
    }

    function test_Constructor_RevertIfZeroProposalManager() public {
        vm.expectRevert(IDisputeResolver.ZeroProposalManager.selector);
        new DisputeResolver(address(gltToken), address(validatorRegistry), address(0));
    }

    // === Create Dispute ===
    function test_CreateDispute_Success() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();
        uint256 challengeStake = 200e18;

        uint256 balanceBefore = gltToken.balanceOf(validator3);

        vm.expectEmit(true, true, true, true);
        emit DisputeCreated(1, proposalId, validator3, challengeStake);

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, challengeStake);

        assertEq(disputeId, 1);

        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertEq(dispute.proposalId, proposalId);
        assertEq(dispute.challenger, validator3);
        assertEq(dispute.proposer, validator1);
        assertEq(dispute.challengeStake, challengeStake);
        assertEq(uint8(dispute.state), uint8(IDisputeResolver.DisputeState.Active));
        assertEq(dispute.votingEndTime, block.timestamp + DISPUTE_VOTING_PERIOD);

        assertEq(gltToken.balanceOf(validator3), balanceBefore - challengeStake);
        assertEq(gltToken.balanceOf(address(disputeResolver)), challengeStake);
    }

    function test_CreateDispute_RevertIfNotActiveValidator() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.expectRevert(IDisputeResolver.CallerNotActiveValidator.selector);
        vm.prank(nonValidator);
        disputeResolver.createDispute(proposalId, MINIMUM_CHALLENGE_STAKE);
    }

    function test_CreateDispute_RevertIfProposalNotOptimisticallyApproved() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");

        vm.expectRevert(IDisputeResolver.ProposalNotDisputable.selector);
        vm.prank(validator3);
        disputeResolver.createDispute(proposalId, MINIMUM_CHALLENGE_STAKE);
    }

    function test_CreateDispute_RevertIfBelowMinimumStake() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.expectRevert(IDisputeResolver.InsufficientChallengeStake.selector);
        vm.prank(validator3);
        disputeResolver.createDispute(proposalId, 50e18);
    }

    function test_CreateDispute_RevertIfZeroStake() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.expectRevert(IDisputeResolver.ZeroChallengeStake.selector);
        vm.prank(validator3);
        disputeResolver.createDispute(proposalId, 0);
    }

    function test_CreateDispute_RevertIfChallengeWindowExpired() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.roll(block.number + CHALLENGE_WINDOW_DURATION + 1);

        vm.expectRevert(IDisputeResolver.ProposalNotDisputable.selector);
        vm.prank(validator3);
        disputeResolver.createDispute(proposalId, MINIMUM_CHALLENGE_STAKE);
    }

    function test_CreateDispute_MultipleDisputes() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.prank(validator3);
        uint256 disputeId1 = disputeResolver.createDispute(proposalId, MINIMUM_CHALLENGE_STAKE);

        vm.prank(validator4);
        uint256 disputeId2 = disputeResolver.createDispute(proposalId, MINIMUM_CHALLENGE_STAKE + 50e18);

        assertEq(disputeId1, 1);
        assertEq(disputeId2, 2);

        uint256[] memory disputes = disputeResolver.getDisputesByProposal(proposalId);
        assertEq(disputes.length, 2);
    }

    // === Vote on Dispute ===
    function test_VoteOnDispute_Success() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 200e18);

        bytes memory signature = _createVoteSignature(VALIDATOR4_PRIVATE_KEY, disputeId, true);

        vm.expectEmit(true, true, false, true);
        emit DisputeVoteCast(disputeId, validator4, true);

        vm.prank(validator4);
        disputeResolver.voteOnDispute(disputeId, true, signature);

        (bool hasVoted, bool supportChallenge) = disputeResolver.getDisputeVote(disputeId, validator4);
        assertTrue(hasVoted);
        assertTrue(supportChallenge);

        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertEq(dispute.votesFor, 1);
        assertEq(dispute.votesAgainst, 0);
    }

    function test_VoteOnDispute_MultipleVotes() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 200e18);

        bytes memory signature1 = _createVoteSignature(VALIDATOR4_PRIVATE_KEY, disputeId, true);
        vm.prank(validator4);
        disputeResolver.voteOnDispute(disputeId, true, signature1);

        bytes memory signature2 = _createVoteSignature(VALIDATOR1_PRIVATE_KEY, disputeId, false);
        vm.prank(validator1);
        disputeResolver.voteOnDispute(disputeId, false, signature2);

        bytes memory signature3 = _createVoteSignature(VALIDATOR2_PRIVATE_KEY, disputeId, true);
        vm.prank(validator2);
        disputeResolver.voteOnDispute(disputeId, true, signature3);

        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertEq(dispute.votesFor, 2);
        assertEq(dispute.votesAgainst, 1);
    }

    function test_VoteOnDispute_RevertIfNotActiveValidator() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 200e18);

        vm.expectRevert(IDisputeResolver.CallerNotActiveValidator.selector);
        vm.prank(nonValidator);
        disputeResolver.voteOnDispute(
            disputeId, true, _createVoteSignature(uint256(uint160(msg.sender)), disputeId, true)
        );
    }

    function test_VoteOnDispute_RevertIfDisputeNotFound() public {
        vm.expectRevert(IDisputeResolver.DisputeNotFound.selector);
        vm.prank(validator1);
        disputeResolver.voteOnDispute(999, true, "");
    }

    function test_VoteOnDispute_RevertIfAlreadyVoted() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 200e18);

        vm.prank(validator4);
        disputeResolver.voteOnDispute(disputeId, true, _createVoteSignature(VALIDATOR4_PRIVATE_KEY, disputeId, true));

        vm.expectRevert(IDisputeResolver.ValidatorAlreadyVoted.selector);
        vm.prank(validator4);
        disputeResolver.voteOnDispute(disputeId, false, _createVoteSignature(VALIDATOR4_PRIVATE_KEY, disputeId, false));
    }

    function test_VoteOnDispute_RevertIfVotingEnded() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 200e18);

        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);

        vm.expectRevert(IDisputeResolver.DisputeVotingEnded.selector);
        vm.prank(validator4);
        disputeResolver.voteOnDispute(
            disputeId, true, _createVoteSignature(uint256(uint160(msg.sender)), disputeId, true)
        );
    }

    // === Resolve Dispute ===
    function test_ResolveDispute_ChallengerWins() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();
        uint256 challengeStake = 200e18;

        IValidatorRegistry.ValidatorInfo memory proposerInfoBefore = validatorRegistry.getValidatorInfo(validator1);

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, challengeStake);

        uint256 challengerBalanceAfterDispute = gltToken.balanceOf(validator3);

        vm.prank(validator4);
        disputeResolver.voteOnDispute(disputeId, true, _createVoteSignature(VALIDATOR4_PRIVATE_KEY, disputeId, true));

        vm.prank(validator2);
        disputeResolver.voteOnDispute(disputeId, true, _createVoteSignature(VALIDATOR2_PRIVATE_KEY, disputeId, true));

        vm.prank(validator1);
        disputeResolver.voteOnDispute(disputeId, false, _createVoteSignature(VALIDATOR1_PRIVATE_KEY, disputeId, false));

        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);

        uint256 expectedSlashAmount = (challengeStake * SLASH_PERCENTAGE) / 100;
        uint256 expectedReward = challengeStake;

        vm.expectEmit(true, true, false, true);
        emit RewardDistributed(disputeId, validator3, expectedReward);

        vm.expectEmit(true, false, false, true);
        emit DisputeResolved(disputeId, true, expectedSlashAmount);

        disputeResolver.resolveDispute(disputeId);

        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertEq(uint8(dispute.state), uint8(IDisputeResolver.DisputeState.Resolved));
        assertTrue(dispute.challengerWon);
        assertEq(dispute.slashAmount, expectedSlashAmount);

        assertEq(gltToken.balanceOf(validator3), challengerBalanceAfterDispute + expectedReward);

        IValidatorRegistry.ValidatorInfo memory proposerInfoAfter = validatorRegistry.getValidatorInfo(validator1);
        uint256 actualSlash = expectedSlashAmount > proposerInfoBefore.stakedAmount
            ? proposerInfoBefore.stakedAmount
            : expectedSlashAmount;
        assertEq(proposerInfoAfter.stakedAmount, proposerInfoBefore.stakedAmount - actualSlash);

        // Note: DisputeResolver doesn't auto-reject proposals - ProposalManager handles that
    }

    function test_ResolveDispute_ProposerWins() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();
        uint256 challengeStake = 200e18;

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, challengeStake);

        vm.prank(validator4);
        disputeResolver.voteOnDispute(disputeId, true, _createVoteSignature(VALIDATOR4_PRIVATE_KEY, disputeId, true));

        vm.prank(validator1);
        disputeResolver.voteOnDispute(disputeId, false, _createVoteSignature(VALIDATOR1_PRIVATE_KEY, disputeId, false));

        vm.prank(validator2);
        disputeResolver.voteOnDispute(disputeId, false, _createVoteSignature(VALIDATOR2_PRIVATE_KEY, disputeId, false));

        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);

        uint256 expectedSlashAmount = (challengeStake * SLASH_PERCENTAGE) / 100;
        uint256 expectedReward = challengeStake - expectedSlashAmount;

        vm.expectEmit(true, true, false, true);
        emit RewardDistributed(disputeId, validator1, expectedReward);

        vm.expectEmit(true, false, false, true);
        emit DisputeResolved(disputeId, false, expectedSlashAmount);

        uint256 ownerBalanceBefore = gltToken.balanceOf(deployer);

        disputeResolver.resolveDispute(disputeId);

        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertEq(uint8(dispute.state), uint8(IDisputeResolver.DisputeState.Resolved));
        assertFalse(dispute.challengerWon);
        assertEq(dispute.slashAmount, expectedSlashAmount);

        assertEq(gltToken.balanceOf(validator1), 2000e18 + expectedReward);

        assertEq(gltToken.balanceOf(deployer), ownerBalanceBefore + expectedSlashAmount);
    }

    function test_ResolveDispute_RevertIfDisputeNotFound() public {
        vm.expectRevert(IDisputeResolver.DisputeNotFound.selector);
        disputeResolver.resolveDispute(999);
    }

    function test_ResolveDispute_RevertIfNotActive() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 200e18);

        disputeResolver.cancelDispute(disputeId, "Cancelled for test");

        vm.expectRevert(IDisputeResolver.InvalidDisputeState.selector);
        disputeResolver.resolveDispute(disputeId);
    }

    function test_ResolveDispute_RevertIfVotingActive() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 200e18);

        vm.expectRevert(IDisputeResolver.DisputeVotingActive.selector);
        disputeResolver.resolveDispute(disputeId);
    }

    // === Cancel Dispute ===
    function test_CancelDispute_Success() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();
        uint256 challengeStake = 200e18;

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, challengeStake);

        uint256 challengerBalanceBefore = gltToken.balanceOf(validator3);

        string memory reason = "Cancelled by admin";

        vm.expectEmit(true, false, false, true);
        emit DisputeResolved(disputeId, false, 0);

        disputeResolver.cancelDispute(disputeId, reason);

        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertEq(uint8(dispute.state), uint8(IDisputeResolver.DisputeState.Cancelled));

        assertEq(gltToken.balanceOf(validator3), challengerBalanceBefore + challengeStake);
    }

    function test_CancelDispute_RevertIfUnauthorized() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 200e18);

        vm.expectRevert();
        vm.prank(validator1);
        disputeResolver.cancelDispute(disputeId, "Unauthorized");
    }

    function test_CancelDispute_RevertIfNotActive() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 200e18);

        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);
        disputeResolver.resolveDispute(disputeId);

        vm.expectRevert(IDisputeResolver.InvalidDisputeState.selector);
        disputeResolver.cancelDispute(disputeId, "Too late");
    }

    // === View Functions ===
    function test_GetDispute_RevertIfNotFound() public {
        vm.expectRevert(IDisputeResolver.DisputeNotFound.selector);
        disputeResolver.getDispute(999);
    }

    function test_GetDisputesByProposal() public {
        uint256 proposalId1 = _createOptimisticallyApprovedProposal();

        vm.prank(validator3);
        uint256 disputeId1 = disputeResolver.createDispute(proposalId1, 200e18);

        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);
        disputeResolver.resolveDispute(disputeId1);

        uint256 proposalId2 = _createOptimisticallyApprovedProposal();
        vm.prank(validator4);
        uint256 disputeId2 = disputeResolver.createDispute(proposalId2, 150e18);

        uint256[] memory proposal1Disputes = disputeResolver.getDisputesByProposal(proposalId1);
        assertEq(proposal1Disputes.length, 1);
        assertEq(proposal1Disputes[0], disputeId1);

        uint256[] memory proposal2Disputes = disputeResolver.getDisputesByProposal(proposalId2);
        assertEq(proposal2Disputes.length, 1);
        assertEq(proposal2Disputes[0], disputeId2);
    }

    function test_GetTotalDisputes() public {
        assertEq(disputeResolver.totalDisputes(), 0);

        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.prank(validator3);
        disputeResolver.createDispute(proposalId, 200e18);

        assertEq(disputeResolver.totalDisputes(), 1);
    }

    function test_GetMinimumChallengeStake() public view {
        assertEq(disputeResolver.MINIMUM_CHALLENGE_STAKE(), MINIMUM_CHALLENGE_STAKE);
    }

    function test_GetDisputeVotingPeriod() public view {
        assertEq(disputeResolver.DISPUTE_VOTING_PERIOD(), DISPUTE_VOTING_PERIOD);
    }

    function test_GetSlashPercentage() public view {
        assertEq(disputeResolver.SLASH_PERCENTAGE(), SLASH_PERCENTAGE);
    }

    // === Edge Cases ===
    function test_MultipleDisputes_DifferentProposals() public {
        uint256[] memory disputeIds = new uint256[](3);

        for (uint256 i = 0; i < 3; i++) {
            uint256 proposalId = _createOptimisticallyApprovedProposal();

            address challenger = i == 0 ? validator3 : (i == 1 ? validator4 : validator2);
            uint256 stake = 150e18 + (i * 50e18);

            vm.prank(challenger);
            disputeIds[i] = disputeResolver.createDispute(proposalId, stake);
        }

        assertEq(disputeResolver.totalDisputes(), 3);
    }

    function test_ExactlyHalfVotes_ChallengerWins() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 200e18);

        // Edge case: With 4 validators, 2 votes for challenge (50%) should make challenger win
        vm.prank(validator4);
        disputeResolver.voteOnDispute(disputeId, true, _createVoteSignature(VALIDATOR4_PRIVATE_KEY, disputeId, true));

        vm.prank(validator1);
        disputeResolver.voteOnDispute(disputeId, true, _createVoteSignature(VALIDATOR1_PRIVATE_KEY, disputeId, true));

        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);
        disputeResolver.resolveDispute(disputeId);

        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertTrue(dispute.challengerWon);
    }

    function test_LessThanHalfVotes_ProposerWins() public {
        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 200e18);

        // Edge case: With 4 validators, 1 vote for challenge (25%) - proposer should win
        vm.prank(validator4);
        disputeResolver.voteOnDispute(disputeId, true, _createVoteSignature(VALIDATOR4_PRIVATE_KEY, disputeId, true));

        vm.prank(validator1);
        disputeResolver.voteOnDispute(disputeId, false, _createVoteSignature(VALIDATOR1_PRIVATE_KEY, disputeId, false));

        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);
        disputeResolver.resolveDispute(disputeId);

        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertFalse(dispute.challengerWon);
    }

    function testFuzz_CreateDispute(uint256 challengeStake) public {
        challengeStake = bound(challengeStake, MINIMUM_CHALLENGE_STAKE, 1000e18);

        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, challengeStake);

        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertEq(dispute.challengeStake, challengeStake);
        assertTrue(disputeId > 0);
    }

    function testFuzz_VotingOutcome(uint8 votesFor, uint8 votesAgainst) public {
        votesFor = uint8(bound(votesFor, 0, 4));
        votesAgainst = uint8(bound(votesAgainst, 0, 4));
        // Ensure total votes are in range [1, 4]
        uint8 total = votesFor + votesAgainst;
        if (total == 0) {
            votesFor = 1;
        } else if (total > 4) {
            votesAgainst = 4 - votesFor;
        }

        uint256 proposalId = _createOptimisticallyApprovedProposal();

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 200e18);

        address[4] memory validators = [validator1, validator2, validator3, validator4];
        uint256[4] memory privateKeys =
            [VALIDATOR1_PRIVATE_KEY, VALIDATOR2_PRIVATE_KEY, VALIDATOR3_PRIVATE_KEY, VALIDATOR4_PRIVATE_KEY];
        uint256 voteIndex = 0;

        for (uint256 i = 0; i < votesFor && voteIndex < 4; i++) {
            if (validators[voteIndex] != validator3) {
                bytes memory sig = _createVoteSignature(privateKeys[voteIndex], disputeId, true);
                vm.prank(validators[voteIndex]);
                disputeResolver.voteOnDispute(disputeId, true, sig);
            }
            voteIndex++;
        }

        for (uint256 i = 0; i < votesAgainst && voteIndex < 4; i++) {
            if (validators[voteIndex] != validator3) {
                bytes memory sig = _createVoteSignature(privateKeys[voteIndex], disputeId, false);
                vm.prank(validators[voteIndex]);
                disputeResolver.voteOnDispute(disputeId, false, sig);
            }
            voteIndex++;
        }

        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);
        disputeResolver.resolveDispute(disputeId);

        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        // Challenger wins with 50% or more votes (2 out of 4 validators)
        bool expectedChallengerWon = dispute.votesFor >= 2;
        assertEq(dispute.challengerWon, expectedChallengerWon);
    }

    function test_ResolveDispute_NonValidatorProposer_ChallengerWins() public {
        gltToken.mint(nonValidator, 100e18);

        vm.prank(nonValidator);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Non-validator proposal");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        uint256 challengeStake = 200e18;
        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, challengeStake);

        // Edge case: 2 for (supporting challenge), 2 against - challenger wins with 50%
        vm.prank(validator1);
        disputeResolver.voteOnDispute(disputeId, true, _createVoteSignature(VALIDATOR1_PRIVATE_KEY, disputeId, true));

        vm.prank(validator2);
        disputeResolver.voteOnDispute(disputeId, true, _createVoteSignature(VALIDATOR2_PRIVATE_KEY, disputeId, true));

        vm.prank(validator3);
        disputeResolver.voteOnDispute(disputeId, false, _createVoteSignature(VALIDATOR3_PRIVATE_KEY, disputeId, false));

        vm.prank(validator4);
        disputeResolver.voteOnDispute(disputeId, false, _createVoteSignature(VALIDATOR4_PRIVATE_KEY, disputeId, false));

        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);

        uint256 challengerBalanceBeforeResolve = gltToken.balanceOf(validator3);
        uint256 disputeResolverBalanceBefore = gltToken.balanceOf(address(disputeResolver));

        disputeResolver.resolveDispute(disputeId);

        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertEq(uint8(dispute.state), uint8(IDisputeResolver.DisputeState.Resolved));
        assertTrue(dispute.challengerWon);

        // Non-validator proposer: slash amount calculated but not applied
        uint256 calculatedSlashAmount = (challengeStake * SLASH_PERCENTAGE) / 100;
        assertEq(dispute.slashAmount, calculatedSlashAmount);

        assertEq(gltToken.balanceOf(validator3), challengerBalanceBeforeResolve + challengeStake);

        assertEq(gltToken.balanceOf(address(disputeResolver)), disputeResolverBalanceBefore - challengeStake);
    }
}
