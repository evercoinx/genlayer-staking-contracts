// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IValidatorRegistry } from "../../src/interfaces/IValidatorRegistry.sol";
import { IProposalManager } from "../../src/interfaces/IProposalManager.sol";
import { IConsensusEngine } from "../../src/interfaces/IConsensusEngine.sol";
import { IDisputeResolver } from "../../src/interfaces/IDisputeResolver.sol";
import { GLTToken } from "../../src/GLTToken.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { ProposalManager } from "../../src/ProposalManager.sol";
import { MockLLMOracle } from "../../src/MockLLMOracle.sol";
import { ConsensusEngine } from "../../src/ConsensusEngine.sol";
import { DisputeResolver } from "../../src/DisputeResolver.sol";

/**
 * @title FullFlowIntegrationTest
 * @dev Integration tests covering complete workflows across all contracts
 */
contract FullFlowIntegrationTest is Test {
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    GLTToken public gltToken;
    ValidatorRegistry public validatorRegistry;
    ProposalManager public proposalManager;
    MockLLMOracle public llmOracle;
    ConsensusEngine public consensusEngine;
    DisputeResolver public disputeResolver;

    address public deployer = address(this);
    address public proposalManagerRole = address(0x1000);
    address public consensusInitiatorRole = address(0x2000);

    uint256 constant VALIDATOR1_PRIVATE_KEY = 0x1234;
    uint256 constant VALIDATOR2_PRIVATE_KEY = 0x5678;
    uint256 constant VALIDATOR3_PRIVATE_KEY = 0x9ABC;
    uint256 constant VALIDATOR4_PRIVATE_KEY = 0xDEF0;
    uint256 constant VALIDATOR5_PRIVATE_KEY = 0x1111;

    address public validator1;
    address public validator2;
    address public validator3;
    address public validator4;
    address public validator5;

    uint256 constant MINIMUM_STAKE = 1000e18;
    uint256 constant INITIAL_VALIDATOR_BALANCE = 10_000e18;
    uint256 constant CHALLENGE_WINDOW = 10;
    uint256 constant VOTING_PERIOD = 100;
    uint256 constant DISPUTE_VOTING_PERIOD = 50;

    function setUp() public {
        validator1 = vm.addr(VALIDATOR1_PRIVATE_KEY);
        validator2 = vm.addr(VALIDATOR2_PRIVATE_KEY);
        validator3 = vm.addr(VALIDATOR3_PRIVATE_KEY);
        validator4 = vm.addr(VALIDATOR4_PRIVATE_KEY);
        validator5 = vm.addr(VALIDATOR5_PRIVATE_KEY);

        gltToken = new GLTToken(deployer);
        llmOracle = new MockLLMOracle();
        validatorRegistry = new ValidatorRegistry(address(gltToken), deployer);
        proposalManager = new ProposalManager(address(validatorRegistry), address(llmOracle), proposalManagerRole);
        consensusEngine =
            new ConsensusEngine(address(validatorRegistry), address(proposalManager), consensusInitiatorRole);
        disputeResolver = new DisputeResolver(address(gltToken), address(validatorRegistry), address(proposalManager));

        validatorRegistry.setSlasher(address(disputeResolver));

        setupValidator(validator1, 3000e18);
        setupValidator(validator2, 2500e18);
        setupValidator(validator3, 2000e18);
        setupValidator(validator4, 1500e18);
        setupValidator(validator5, 1000e18);
    }

    function setupValidator(address validator, uint256 stake) internal {
        gltToken.mint(validator, INITIAL_VALIDATOR_BALANCE);
        vm.prank(validator);
        gltToken.approve(address(validatorRegistry), type(uint256).max);
        vm.prank(validator);
        validatorRegistry.registerValidator(stake);
        vm.prank(validator);
        gltToken.approve(address(disputeResolver), type(uint256).max);
    }

    function createVoteSignature(
        uint256 privateKey,
        uint256 roundId,
        bool support
    )
        internal
        view
        returns (bytes memory)
    {
        address validator = vm.addr(privateKey);
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "GenLayerConsensusVote", roundId, validator, support, address(consensusEngine), block.chainid
            )
        );
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedMessageHash);
        return abi.encodePacked(r, s, v);
    }

    function createDisputeVoteSignature(
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

    function test_Integration_HappyPath_ProposalApproved() public {
        bytes32 contentHash = keccak256("Valid proposal content");
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(contentHash, "Integration Test Proposal");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.roll(block.number + CHALLENGE_WINDOW + 1);

        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.OptimisticApproved));

        // Note: In real implementation, would need to finalize proposal
    }

    function test_Integration_ProposalChallenged_ConsensusApproves() public {
        bytes32 contentHash = keccak256("Challenged but valid proposal");
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(contentHash, "Challenged Proposal");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.prank(validator2);
        proposalManager.challengeProposal(proposalId);

        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);

        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true));

        vm.prank(validator3);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR3_PRIVATE_KEY, roundId, true));

        vm.prank(validator4);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR4_PRIVATE_KEY, roundId, true));

        vm.prank(validator2);
        consensusEngine.castVote(roundId, false, createVoteSignature(VALIDATOR2_PRIVATE_KEY, roundId, false));

        vm.roll(block.number + VOTING_PERIOD + 1);
        bool approved = consensusEngine.finalizeConsensus(roundId);
        assertTrue(approved);

        // Note: In the current implementation, ConsensusEngine doesn't automatically update ProposalManager state
        // The proposal remains in Challenged state after consensus
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.Challenged));
    }

    function test_Integration_ProposalChallenged_ConsensusRejects() public {
        bytes32 contentHash = keccak256("Invalid proposal content!");
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(contentHash, "Invalid Proposal");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.prank(validator2);
        proposalManager.challengeProposal(proposalId);

        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);

        vm.prank(validator2);
        consensusEngine.castVote(roundId, false, createVoteSignature(VALIDATOR2_PRIVATE_KEY, roundId, false));

        vm.prank(validator3);
        consensusEngine.castVote(roundId, false, createVoteSignature(VALIDATOR3_PRIVATE_KEY, roundId, false));

        vm.prank(validator4);
        consensusEngine.castVote(roundId, false, createVoteSignature(VALIDATOR4_PRIVATE_KEY, roundId, false));

        vm.prank(validator5);
        consensusEngine.castVote(roundId, false, createVoteSignature(VALIDATOR5_PRIVATE_KEY, roundId, false));

        vm.roll(block.number + VOTING_PERIOD + 1);
        bool approved = consensusEngine.finalizeConsensus(roundId);
        assertFalse(approved);

        // Note: Proposal state remains Challenged after consensus
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.Challenged));
    }

    function test_Integration_DisputeResolution_ChallengerWins() public {
        bytes32 contentHash = keccak256("Malicious proposal!");
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(contentHash, "Malicious Proposal");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        uint256 challengeStake = 200e18;
        uint256 challengerBalanceBefore = gltToken.balanceOf(validator3);

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, challengeStake);

        vm.prank(validator2);
        disputeResolver.voteOnDispute(
            disputeId, true, createDisputeVoteSignature(VALIDATOR2_PRIVATE_KEY, disputeId, true)
        );

        vm.prank(validator4);
        disputeResolver.voteOnDispute(
            disputeId, true, createDisputeVoteSignature(VALIDATOR4_PRIVATE_KEY, disputeId, true)
        );

        vm.prank(validator5);
        disputeResolver.voteOnDispute(
            disputeId, true, createDisputeVoteSignature(VALIDATOR5_PRIVATE_KEY, disputeId, true)
        );

        vm.prank(validator1);
        disputeResolver.voteOnDispute(
            disputeId, false, createDisputeVoteSignature(VALIDATOR1_PRIVATE_KEY, disputeId, false)
        );

        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);

        IValidatorRegistry.ValidatorInfo memory proposerBefore = validatorRegistry.getValidatorInfo(validator1);
        disputeResolver.resolveDispute(disputeId);
        IValidatorRegistry.ValidatorInfo memory proposerAfter = validatorRegistry.getValidatorInfo(validator1);

        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertTrue(dispute.challengerWon);

        uint256 slashAmount = (challengeStake * 10) / 100;
        assertEq(proposerAfter.stakedAmount, proposerBefore.stakedAmount - slashAmount);

        assertEq(gltToken.balanceOf(validator3), challengerBalanceBefore);
    }

    function test_Integration_DisputeResolution_ProposerWins() public {
        bytes32 contentHash = keccak256("Actually valid proposal");
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(contentHash, "Valid Proposal");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        uint256 challengeStake = 150e18;

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, challengeStake);

        vm.prank(validator1);
        disputeResolver.voteOnDispute(
            disputeId, false, createDisputeVoteSignature(VALIDATOR1_PRIVATE_KEY, disputeId, false)
        );

        vm.prank(validator2);
        disputeResolver.voteOnDispute(
            disputeId, false, createDisputeVoteSignature(VALIDATOR2_PRIVATE_KEY, disputeId, false)
        );

        vm.prank(validator4);
        disputeResolver.voteOnDispute(
            disputeId, false, createDisputeVoteSignature(VALIDATOR4_PRIVATE_KEY, disputeId, false)
        );

        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);

        uint256 proposerBalanceBefore = gltToken.balanceOf(validator1);
        disputeResolver.resolveDispute(disputeId);
        uint256 proposerBalanceAfter = gltToken.balanceOf(validator1);

        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertFalse(dispute.challengerWon);

        uint256 slashAmount = (challengeStake * 10) / 100;
        uint256 rewardAmount = challengeStake - slashAmount;
        assertEq(proposerBalanceAfter, proposerBalanceBefore + rewardAmount);
    }

    function test_Integration_ValidatorLifecycle() public {
        address newValidator = address(0x9999);
        gltToken.mint(newValidator, 5000e18);

        vm.startPrank(newValidator);
        gltToken.approve(address(validatorRegistry), type(uint256).max);
        validatorRegistry.registerValidator(2000e18);
        vm.stopPrank();

        assertTrue(validatorRegistry.isActiveValidator(newValidator));

        vm.prank(newValidator);
        validatorRegistry.increaseStake(1000e18);

        IValidatorRegistry.ValidatorInfo memory info = validatorRegistry.getValidatorInfo(newValidator);
        assertEq(info.stakedAmount, 3000e18);

        vm.prank(newValidator);
        validatorRegistry.requestUnstake(3000e18);

        info = validatorRegistry.getValidatorInfo(newValidator);
        assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Unstaking));

        vm.roll(block.number + 1);

        uint256 balanceBefore = gltToken.balanceOf(newValidator);
        vm.prank(newValidator);
        validatorRegistry.completeUnstake();
        uint256 balanceAfter = gltToken.balanceOf(newValidator);

        assertEq(balanceAfter, balanceBefore + 3000e18);
        assertFalse(validatorRegistry.isActiveValidator(newValidator));
    }

    function test_Integration_LLMOracleValidation() public {
        bytes32 evenHash = keccak256("Even content 1234");
        assertTrue(uint256(evenHash) % 2 == 0, "Hash should be even");

        vm.prank(validator1);
        uint256 proposalId1 = proposalManager.createProposal(evenHash, "Even hash proposal");

        bool isValid1 = llmOracle.validateProposal(proposalId1, evenHash);
        assertTrue(isValid1);

        bytes32 oddHash = keccak256("Odd content 123");
        assertTrue(uint256(oddHash) % 2 == 1, "Hash should be odd");

        vm.prank(validator2);
        uint256 proposalId2 = proposalManager.createProposal(oddHash, "Odd hash proposal");

        bool isValid2 = llmOracle.validateProposal(proposalId2, oddHash);
        assertFalse(isValid2);
    }

    function test_Integration_ValidatorSlashedBelowMinimum() public {
        IValidatorRegistry.ValidatorInfo memory info = validatorRegistry.getValidatorInfo(validator5);
        assertEq(info.stakedAmount, MINIMUM_STAKE);
        assertTrue(validatorRegistry.isActiveValidator(validator5));

        vm.prank(validator5);
        uint256 proposalId = proposalManager.createProposal(keccak256("Bad proposal!"), "Bad");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 200e18);

        vm.prank(validator1);
        disputeResolver.voteOnDispute(
            disputeId, true, createDisputeVoteSignature(VALIDATOR1_PRIVATE_KEY, disputeId, true)
        );

        vm.prank(validator2);
        disputeResolver.voteOnDispute(
            disputeId, true, createDisputeVoteSignature(VALIDATOR2_PRIVATE_KEY, disputeId, true)
        );

        vm.prank(validator4);
        disputeResolver.voteOnDispute(
            disputeId, true, createDisputeVoteSignature(VALIDATOR4_PRIVATE_KEY, disputeId, true)
        );

        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);
        disputeResolver.resolveDispute(disputeId);

        info = validatorRegistry.getValidatorInfo(validator5);
        assertLt(info.stakedAmount, MINIMUM_STAKE);
        assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Slashed));
        assertFalse(validatorRegistry.isActiveValidator(validator5));
    }

    function test_Integration_ConcurrentProposalsAndDisputes() public {
        vm.prank(validator1);
        uint256 proposalId1 = proposalManager.createProposal(keccak256("Proposal 1"), "First");

        vm.prank(validator2);
        uint256 proposalId2 = proposalManager.createProposal(keccak256("Proposal 2"), "Second");

        vm.prank(validator3);
        uint256 proposalId3 = proposalManager.createProposal(keccak256("Proposal 3!"), "Third");

        vm.startPrank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId1);
        proposalManager.approveOptimistically(proposalId2);
        proposalManager.approveOptimistically(proposalId3);
        vm.stopPrank();

        vm.prank(validator4);
        disputeResolver.createDispute(proposalId1, 100e18);

        vm.prank(validator5);
        disputeResolver.createDispute(proposalId3, 150e18);

        vm.prank(validator4);
        proposalManager.challengeProposal(proposalId2);

        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId2);

        assertEq(disputeResolver.totalDisputes(), 2);
        assertEq(consensusEngine.getCurrentRound(proposalId2), roundId);
    }

    function test_Integration_NonValidatorCanCreateProposal() public {
        address nonValidator = address(0x9999);

        gltToken.mint(nonValidator, 100e18);

        bytes32 contentHash = keccak256("Non-validator proposal");
        vm.prank(nonValidator);
        uint256 proposalId = proposalManager.createProposal(contentHash, "Non-Validator Test Proposal");

        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(proposal.proposer, nonValidator);
        assertEq(proposal.contentHash, contentHash);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.Proposed));

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.prank(validator1);
        proposalManager.challengeProposal(proposalId);

        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);

        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true));

        vm.prank(validator2);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR2_PRIVATE_KEY, roundId, true));

        vm.prank(validator3);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR3_PRIVATE_KEY, roundId, true));

        vm.roll(block.number + VOTING_PERIOD + 1);

        bool approved = consensusEngine.finalizeConsensus(roundId);
        assertTrue(approved);
    }
}