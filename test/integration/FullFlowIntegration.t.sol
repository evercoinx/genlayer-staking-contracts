// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { console2 } from "@forge-std/console2.sol";
import { GLTToken } from "../../src/GLTToken.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { ProposalManager } from "../../src/ProposalManager.sol";
import { MockLLMOracle } from "../../src/MockLLMOracle.sol";
import { ConsensusEngine } from "../../src/ConsensusEngine.sol";
import { DisputeResolver } from "../../src/DisputeResolver.sol";
import { IValidatorRegistry } from "../../src/interfaces/IValidatorRegistry.sol";
import { IProposalManager } from "../../src/interfaces/IProposalManager.sol";
import { IConsensusEngine } from "../../src/interfaces/IConsensusEngine.sol";
import { IDisputeResolver } from "../../src/interfaces/IDisputeResolver.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title FullFlowIntegrationTest
 * @dev Integration tests covering complete workflows across all contracts
 */
contract FullFlowIntegrationTest is Test {
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    // Contracts
    GLTToken public gltToken;
    ValidatorRegistry public validatorRegistry;
    ProposalManager public proposalManager;
    MockLLMOracle public llmOracle;
    ConsensusEngine public consensusEngine;
    DisputeResolver public disputeResolver;

    // Roles
    address public deployer = address(this);
    address public proposalManagerRole = address(0x1000);
    address public consensusInitiatorRole = address(0x2000);

    // Validators
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

    // Constants
    uint256 constant MINIMUM_STAKE = 1000e18;
    uint256 constant INITIAL_VALIDATOR_BALANCE = 10000e18;
    uint256 constant CHALLENGE_WINDOW = 10;
    uint256 constant VOTING_PERIOD = 100;
    uint256 constant DISPUTE_VOTING_PERIOD = 50;

    function setUp() public {
        // Derive validator addresses
        validator1 = vm.addr(VALIDATOR1_PRIVATE_KEY);
        validator2 = vm.addr(VALIDATOR2_PRIVATE_KEY);
        validator3 = vm.addr(VALIDATOR3_PRIVATE_KEY);
        validator4 = vm.addr(VALIDATOR4_PRIVATE_KEY);
        validator5 = vm.addr(VALIDATOR5_PRIVATE_KEY);

        // Deploy contracts
        gltToken = new GLTToken(deployer);
        llmOracle = new MockLLMOracle();
        validatorRegistry = new ValidatorRegistry(address(gltToken), deployer);
        proposalManager = new ProposalManager(
            address(validatorRegistry),
            address(llmOracle),
            proposalManagerRole
        );
        consensusEngine = new ConsensusEngine(
            address(validatorRegistry),
            address(proposalManager),
            consensusInitiatorRole
        );
        disputeResolver = new DisputeResolver(
            address(gltToken),
            address(validatorRegistry),
            address(proposalManager)
        );

        // Set up roles
        validatorRegistry.setSlasher(address(disputeResolver));

        // Fund validators
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

    // Helper functions
    function createVoteSignature(
        uint256 privateKey,
        uint256 roundId,
        bool support
    ) internal view returns (bytes memory) {
        address validator = vm.addr(privateKey);
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "GenLayerConsensusVote",
                roundId,
                validator,
                support,
                address(consensusEngine),
                block.chainid
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
    ) internal view returns (bytes memory) {
        address validator = vm.addr(privateKey);
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "GenLayerDisputeVote",
                disputeId,
                validator,
                supportChallenge,
                address(disputeResolver),
                block.chainid
            )
        );
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedMessageHash);
        return abi.encodePacked(r, s, v);
    }

    // Test: Complete happy path - proposal approved through consensus
    function test_Integration_HappyPath_ProposalApproved() public {
        console2.log("=== Happy Path: Proposal Approved ===");
        
        // 1. Validator creates proposal
        bytes32 contentHash = keccak256("Valid proposal content");
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(contentHash, "Integration Test Proposal");
        console2.log("Proposal created with ID:", proposalId);
        
        // 2. Proposal manager approves optimistically
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        console2.log("Proposal optimistically approved");
        
        // 3. Wait for challenge window to pass
        vm.roll(block.number + CHALLENGE_WINDOW + 1);
        
        // 4. No challenge, proposal can be finalized
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.OptimisticApproved));
        console2.log("Challenge window passed without challenges");
        
        // Note: In real implementation, would need to finalize proposal
    }

    // Test: Proposal challenged and approved through consensus
    function test_Integration_ProposalChallenged_ConsensusApproves() public {
        console2.log("=== Proposal Challenged, Consensus Approves ===");
        
        // 1. Create and optimistically approve proposal
        bytes32 contentHash = keccak256("Challenged but valid proposal");
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(contentHash, "Challenged Proposal");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        // 2. Validator challenges proposal
        vm.prank(validator2);
        proposalManager.challengeProposal(proposalId);
        console2.log("Proposal challenged by validator2");
        
        // 3. Initiate consensus
        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        console2.log("Consensus round initiated:", roundId);
        
        // 4. Validators vote (3 out of 5 vote for approval)
        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true));
        
        vm.prank(validator3);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR3_PRIVATE_KEY, roundId, true));
        
        vm.prank(validator4);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR4_PRIVATE_KEY, roundId, true));
        
        vm.prank(validator2);
        consensusEngine.castVote(roundId, false, createVoteSignature(VALIDATOR2_PRIVATE_KEY, roundId, false));
        
        console2.log("Votes cast - 3 for, 1 against");
        
        // 5. Move past voting period and finalize
        vm.roll(block.number + VOTING_PERIOD + 1);
        bool approved = consensusEngine.finalizeConsensus(roundId);
        assertTrue(approved);
        console2.log("Consensus finalized - proposal approved");
        
        // 6. Note: In the current implementation, ConsensusEngine doesn't automatically update ProposalManager state
        // The proposal remains in Challenged state after consensus
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.Challenged));
    }

    // Test: Proposal challenged and rejected through consensus
    function test_Integration_ProposalChallenged_ConsensusRejects() public {
        console2.log("=== Proposal Challenged, Consensus Rejects ===");
        
        // 1. Create and optimistically approve proposal with odd hash (invalid)
        bytes32 contentHash = keccak256("Invalid proposal content!");
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(contentHash, "Invalid Proposal");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        // 2. Challenge proposal
        vm.prank(validator2);
        proposalManager.challengeProposal(proposalId);
        
        // 3. Initiate consensus
        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        // 4. Validators vote against (4 out of 5 vote against)
        vm.prank(validator2);
        consensusEngine.castVote(roundId, false, createVoteSignature(VALIDATOR2_PRIVATE_KEY, roundId, false));
        
        vm.prank(validator3);
        consensusEngine.castVote(roundId, false, createVoteSignature(VALIDATOR3_PRIVATE_KEY, roundId, false));
        
        vm.prank(validator4);
        consensusEngine.castVote(roundId, false, createVoteSignature(VALIDATOR4_PRIVATE_KEY, roundId, false));
        
        vm.prank(validator5);
        consensusEngine.castVote(roundId, false, createVoteSignature(VALIDATOR5_PRIVATE_KEY, roundId, false));
        
        console2.log("Votes cast - 0 for, 4 against");
        
        // 5. Finalize consensus
        vm.roll(block.number + VOTING_PERIOD + 1);
        bool approved = consensusEngine.finalizeConsensus(roundId);
        assertFalse(approved);
        console2.log("Consensus finalized - proposal rejected");
        
        // 6. Note: Proposal state remains Challenged after consensus
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.Challenged));
    }

    // Test: Dispute resolution - challenger wins
    function test_Integration_DisputeResolution_ChallengerWins() public {
        console2.log("=== Dispute Resolution: Challenger Wins ===");
        
        // 1. Create and optimistically approve invalid proposal
        bytes32 contentHash = keccak256("Malicious proposal!");
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(contentHash, "Malicious Proposal");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        // 2. Create dispute with stake
        uint256 challengeStake = 200e18;
        uint256 challengerBalanceBefore = gltToken.balanceOf(validator3);
        
        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, challengeStake);
        console2.log("Dispute created with stake:", challengeStake / 1e18, "GLT");
        
        // 3. Validators vote on dispute (majority support challenge)
        vm.prank(validator2);
        disputeResolver.voteOnDispute(
            disputeId, 
            true, 
            createDisputeVoteSignature(VALIDATOR2_PRIVATE_KEY, disputeId, true)
        );
        
        vm.prank(validator4);
        disputeResolver.voteOnDispute(
            disputeId, 
            true, 
            createDisputeVoteSignature(VALIDATOR4_PRIVATE_KEY, disputeId, true)
        );
        
        vm.prank(validator5);
        disputeResolver.voteOnDispute(
            disputeId, 
            true, 
            createDisputeVoteSignature(VALIDATOR5_PRIVATE_KEY, disputeId, true)
        );
        
        vm.prank(validator1);
        disputeResolver.voteOnDispute(
            disputeId, 
            false, 
            createDisputeVoteSignature(VALIDATOR1_PRIVATE_KEY, disputeId, false)
        );
        
        console2.log("Dispute votes: 3 for challenge, 1 against");
        
        // 4. Resolve dispute
        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);
        
        IValidatorRegistry.ValidatorInfo memory proposerBefore = validatorRegistry.getValidatorInfo(validator1);
        disputeResolver.resolveDispute(disputeId);
        IValidatorRegistry.ValidatorInfo memory proposerAfter = validatorRegistry.getValidatorInfo(validator1);
        
        // 5. Check results
        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertTrue(dispute.challengerWon);
        console2.log("Challenger won the dispute");
        
        // Check proposer was slashed
        uint256 slashAmount = (challengeStake * 10) / 100;
        assertEq(proposerAfter.stakedAmount, proposerBefore.stakedAmount - slashAmount);
        console2.log("Proposer slashed:", slashAmount / 1e18, "GLT");
        
        // Check challenger got refund
        assertEq(gltToken.balanceOf(validator3), challengerBalanceBefore);
        console2.log("Challenger refunded challenge stake");
    }

    // Test: Dispute resolution - proposer wins
    function test_Integration_DisputeResolution_ProposerWins() public {
        console2.log("=== Dispute Resolution: Proposer Wins ===");
        
        // 1. Create and optimistically approve valid proposal
        bytes32 contentHash = keccak256("Actually valid proposal");
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(contentHash, "Valid Proposal");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        // 2. Create dispute (malicious challenge)
        uint256 challengeStake = 150e18;
        
        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, challengeStake);
        console2.log("Dispute created by validator3");
        
        // 3. Validators vote against challenge
        vm.prank(validator1);
        disputeResolver.voteOnDispute(
            disputeId, 
            false, 
            createDisputeVoteSignature(VALIDATOR1_PRIVATE_KEY, disputeId, false)
        );
        
        vm.prank(validator2);
        disputeResolver.voteOnDispute(
            disputeId, 
            false, 
            createDisputeVoteSignature(VALIDATOR2_PRIVATE_KEY, disputeId, false)
        );
        
        vm.prank(validator4);
        disputeResolver.voteOnDispute(
            disputeId, 
            false, 
            createDisputeVoteSignature(VALIDATOR4_PRIVATE_KEY, disputeId, false)
        );
        
        console2.log("Dispute votes: 0 for challenge, 3 against");
        
        // 4. Resolve dispute
        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);
        
        uint256 proposerBalanceBefore = gltToken.balanceOf(validator1);
        disputeResolver.resolveDispute(disputeId);
        uint256 proposerBalanceAfter = gltToken.balanceOf(validator1);
        
        // 5. Check results
        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertFalse(dispute.challengerWon);
        console2.log("Proposer won the dispute");
        
        // Check proposer received reward
        uint256 slashAmount = (challengeStake * 10) / 100;
        uint256 rewardAmount = challengeStake - slashAmount;
        assertEq(proposerBalanceAfter, proposerBalanceBefore + rewardAmount);
        console2.log("Proposer rewarded:", rewardAmount / 1e18, "GLT");
    }

    // Test: Multiple validators staking and unstaking
    function test_Integration_ValidatorLifecycle() public {
        console2.log("=== Validator Lifecycle ===");
        
        // 1. New validator joins
        address newValidator = address(0x9999);
        gltToken.mint(newValidator, 5000e18);
        
        vm.startPrank(newValidator);
        gltToken.approve(address(validatorRegistry), type(uint256).max);
        validatorRegistry.registerValidator(2000e18);
        vm.stopPrank();
        
        assertTrue(validatorRegistry.isActiveValidator(newValidator));
        console2.log("New validator registered and active");
        
        // 2. Validator increases stake
        vm.prank(newValidator);
        validatorRegistry.increaseStake(1000e18);
        
        IValidatorRegistry.ValidatorInfo memory info = validatorRegistry.getValidatorInfo(newValidator);
        assertEq(info.stakedAmount, 3000e18);
        console2.log("Validator increased stake to:", info.stakedAmount / 1e18, "GLT");
        
        // 3. Validator requests unstake
        vm.prank(newValidator);
        validatorRegistry.requestUnstake(3000e18);
        
        info = validatorRegistry.getValidatorInfo(newValidator);
        assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Unstaking));
        console2.log("Validator requested full unstake");
        
        // 4. Wait bonding period
        vm.warp(block.timestamp + 7 days + 1);
        
        // 5. Complete unstake
        uint256 balanceBefore = gltToken.balanceOf(newValidator);
        vm.prank(newValidator);
        validatorRegistry.completeUnstake();
        uint256 balanceAfter = gltToken.balanceOf(newValidator);
        
        assertEq(balanceAfter, balanceBefore + 3000e18);
        assertFalse(validatorRegistry.isActiveValidator(newValidator));
        console2.log("Unstaking completed, validator inactive");
    }

    // Test: LLM Oracle validation integration
    function test_Integration_LLMOracleValidation() public {
        console2.log("=== LLM Oracle Validation ===");
        
        // 1. Test with even hash (should be valid)
        bytes32 evenHash = keccak256("Even content 1234");
        assertTrue(uint256(evenHash) % 2 == 0, "Hash should be even");
        
        vm.prank(validator1);
        uint256 proposalId1 = proposalManager.createProposal(evenHash, "Even hash proposal");
        
        bool isValid1 = llmOracle.validateProposal(proposalId1, evenHash);
        assertTrue(isValid1);
        console2.log("Even hash validated as true");
        
        // 2. Test with odd hash (should be invalid)
        bytes32 oddHash = keccak256("Odd content 123");
        assertTrue(uint256(oddHash) % 2 == 1, "Hash should be odd");
        
        vm.prank(validator2);
        uint256 proposalId2 = proposalManager.createProposal(oddHash, "Odd hash proposal");
        
        bool isValid2 = llmOracle.validateProposal(proposalId2, oddHash);
        assertFalse(isValid2);
        console2.log("Odd hash validated as false");
    }

    // Test: Edge case - validator slashed below minimum stake
    function test_Integration_ValidatorSlashedBelowMinimum() public {
        console2.log("=== Validator Slashed Below Minimum ===");
        
        // 1. Validator5 has exactly minimum stake (1000 GLT)
        IValidatorRegistry.ValidatorInfo memory info = validatorRegistry.getValidatorInfo(validator5);
        assertEq(info.stakedAmount, MINIMUM_STAKE);
        assertTrue(validatorRegistry.isActiveValidator(validator5));
        
        // 2. Create proposal and dispute that validator5 will lose
        vm.prank(validator5);
        uint256 proposalId = proposalManager.createProposal(keccak256("Bad proposal!"), "Bad");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        vm.prank(validator3);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 200e18);
        
        // 3. Vote for challenger
        vm.prank(validator1);
        disputeResolver.voteOnDispute(disputeId, true, createDisputeVoteSignature(VALIDATOR1_PRIVATE_KEY, disputeId, true));
        
        vm.prank(validator2);
        disputeResolver.voteOnDispute(disputeId, true, createDisputeVoteSignature(VALIDATOR2_PRIVATE_KEY, disputeId, true));
        
        // 4. Resolve dispute
        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);
        disputeResolver.resolveDispute(disputeId);
        
        // 5. Check validator5 is slashed and no longer active
        info = validatorRegistry.getValidatorInfo(validator5);
        assertLt(info.stakedAmount, MINIMUM_STAKE);
        assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Slashed));
        assertFalse(validatorRegistry.isActiveValidator(validator5));
        console2.log("Validator5 slashed below minimum and removed from active set");
    }

    // Test: Concurrent proposals and disputes
    function test_Integration_ConcurrentProposalsAndDisputes() public {
        console2.log("=== Concurrent Proposals and Disputes ===");
        
        // 1. Multiple validators create proposals
        vm.prank(validator1);
        uint256 proposalId1 = proposalManager.createProposal(keccak256("Proposal 1"), "First");
        
        vm.prank(validator2);
        uint256 proposalId2 = proposalManager.createProposal(keccak256("Proposal 2"), "Second");
        
        vm.prank(validator3);
        uint256 proposalId3 = proposalManager.createProposal(keccak256("Proposal 3!"), "Third");
        
        // 2. Approve them optimistically
        vm.startPrank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId1);
        proposalManager.approveOptimistically(proposalId2);
        proposalManager.approveOptimistically(proposalId3);
        vm.stopPrank();
        
        // 3. Create disputes on different proposals
        vm.prank(validator4);
        disputeResolver.createDispute(proposalId1, 100e18);
        
        vm.prank(validator5);
        disputeResolver.createDispute(proposalId3, 150e18);
        
        console2.log("Created disputes on proposals 1 and 3");
        
        // 4. Challenge proposal 2 for consensus
        vm.prank(validator4);
        proposalManager.challengeProposal(proposalId2);
        
        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId2);
        
        console2.log("Proposal 2 sent to consensus");
        
        // 5. Process each independently
        assertEq(disputeResolver.getTotalDisputes(), 2);
        assertEq(consensusEngine.getCurrentRound(proposalId2), roundId);
        
        console2.log("System handling multiple proposals and disputes concurrently");
    }
}