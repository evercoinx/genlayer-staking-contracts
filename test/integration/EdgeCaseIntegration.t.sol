// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { console2 } from "@forge-std/console2.sol";
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
 * @title EdgeCaseIntegrationTest
 * @dev Integration tests for edge cases and error scenarios
 */
contract EdgeCaseIntegrationTest is Test {
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

    address public validator1;
    address public validator2;
    address public validator3;

    // Constants
    uint256 constant MINIMUM_STAKE = 1000e18;
    uint256 constant MAX_VALIDATORS = 100;
    uint256 constant CHALLENGE_WINDOW = 10;
    uint256 constant VOTING_PERIOD = 100;
    uint256 constant DISPUTE_VOTING_PERIOD = 50;

    function setUp() public {
        // Derive validator addresses
        validator1 = vm.addr(VALIDATOR1_PRIVATE_KEY);
        validator2 = vm.addr(VALIDATOR2_PRIVATE_KEY);
        validator3 = vm.addr(VALIDATOR3_PRIVATE_KEY);

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
        setupValidator(validator1, 2000e18);
        setupValidator(validator2, 1500e18);
        setupValidator(validator3, 1000e18);
    }

    function setupValidator(address validator, uint256 stake) internal {
        gltToken.mint(validator, 10000e18);
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

    // Test: Challenge window expiry during active dispute
    function test_EdgeCase_ChallengeWindowExpiryDuringDispute() public {
        console2.log("=== Edge Case: Challenge Window Expiry During Dispute ===");
        
        // 1. Create and approve proposal
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        // 2. Create dispute just before challenge window expires
        vm.roll(block.number + CHALLENGE_WINDOW - 1);
        
        vm.prank(validator2);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 100e18);
        console2.log("Dispute created 1 block before challenge window expires");
        
        // 3. Move past challenge window
        vm.roll(block.number + 2);
        
        // 4. Verify dispute is still active despite challenge window expiry
        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertEq(uint8(dispute.state), uint8(IDisputeResolver.DisputeState.Active));
        
        // 5. Complete dispute voting
        vm.prank(validator3);
        disputeResolver.voteOnDispute(
            disputeId, 
            true, 
            createDisputeVoteSignature(VALIDATOR3_PRIVATE_KEY, disputeId, true)
        );
        
        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);
        disputeResolver.resolveDispute(disputeId);
        
        console2.log("Dispute resolved successfully after challenge window expired");
    }

    // Test: Maximum validators reached
    function test_EdgeCase_MaximumValidatorsReached() public {
        console2.log("=== Edge Case: Maximum Validators Reached ===");
        
        // Get current active validator limit
        uint256 activeValidatorLimit = validatorRegistry.getActiveValidatorLimit();
        console2.log("Active validator limit:", activeValidatorLimit);
        
        // Register validators up to activeValidatorLimit (we already have 3)
        for (uint256 i = 4; i <= activeValidatorLimit; i++) {
            address newValidator = address(uint160(i * 1000));
            gltToken.mint(newValidator, 2000e18);
            
            vm.startPrank(newValidator);
            gltToken.approve(address(validatorRegistry), type(uint256).max);
            validatorRegistry.registerValidator(1000e18);
            vm.stopPrank();
        }
        
        address[] memory activeValidators = validatorRegistry.getActiveValidators();
        assertEq(activeValidators.length, activeValidatorLimit);
        console2.log("Maximum active validators reached:", activeValidatorLimit);
        
        // Try to add one more with higher stake
        address extraValidator = address(0xEEEE);
        gltToken.mint(extraValidator, 5000e18);
        
        vm.startPrank(extraValidator);
        gltToken.approve(address(validatorRegistry), type(uint256).max);
        validatorRegistry.registerValidator(3000e18); // Higher stake than some existing
        vm.stopPrank();
        
        // Check that lowest staked validator was replaced
        activeValidators = validatorRegistry.getActiveValidators();
        assertEq(activeValidators.length, activeValidatorLimit);
        assertTrue(validatorRegistry.isActiveValidator(extraValidator));
        console2.log("Higher staked validator replaced lowest staked one");
    }

    // Test: Consensus with minimum quorum exactly met
    function test_EdgeCase_MinimumQuorumExactlyMet() public {
        console2.log("=== Edge Case: Minimum Quorum Exactly Met ===");
        
        // Create proposal and challenge it
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        vm.prank(validator2);
        proposalManager.challengeProposal(proposalId);
        
        // Initiate consensus
        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        // With 3 validators, 60% quorum means 2 votes needed (60% of 3 = 1.8, rounds up to 2)
        // Cast exactly 2 votes (66.67%)
        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true));
        
        vm.prank(validator2);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR2_PRIVATE_KEY, roundId, true));
        
        console2.log("Cast 2/3 votes (66.67%) - exceeding 60% quorum");
        
        // Finalize
        vm.roll(block.number + VOTING_PERIOD + 1);
        bool approved = consensusEngine.finalizeConsensus(roundId);
        assertTrue(approved);
        console2.log("Consensus approved with exact quorum");
    }

    // Test: Insufficient balance for challenge stake
    function test_EdgeCase_InsufficientBalanceForChallenge() public {
        console2.log("=== Edge Case: Insufficient Balance for Challenge ===");
        
        // Create proposal
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        // Validator3 transfers most of their balance away
        uint256 balance = gltToken.balanceOf(validator3);
        vm.prank(validator3);
        gltToken.transfer(address(0x9999), balance - 50e18); // Keep only 50 GLT
        
        // Try to create dispute with 100 GLT (minimum)
        vm.expectRevert();
        vm.prank(validator3);
        disputeResolver.createDispute(proposalId, 100e18);
        
        console2.log("Dispute creation failed due to insufficient balance");
    }

    // Test: Validator unstaking during active consensus
    function test_EdgeCase_ValidatorUnstakingDuringConsensus() public {
        console2.log("=== Edge Case: Validator Unstaking During Consensus ===");
        
        // Create proposal and initiate consensus
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        vm.prank(validator2);
        proposalManager.challengeProposal(proposalId);
        
        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        // Validator1 votes
        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true));
        
        // Validator2 requests unstaking
        vm.prank(validator2);
        validatorRegistry.requestUnstake(1500e18); // Full unstake
        
        console2.log("Validator2 requested unstaking during consensus");
        
        // Validator2 tries to vote after requesting unstake
        vm.expectRevert(IConsensusEngine.NotActiveValidator.selector);
        vm.prank(validator2);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR2_PRIVATE_KEY, roundId, true));
        
        console2.log("Unstaking validator cannot vote in consensus");
        
        // Finalize with reduced validator set
        vm.roll(block.number + VOTING_PERIOD + 1);
        bool approved = consensusEngine.finalizeConsensus(roundId);
        assertFalse(approved); // Only 1/2 validators voted (50% < 60%)
        console2.log("Consensus failed due to insufficient participation");
    }

    // Test: Multiple disputes on same proposal
    function test_EdgeCase_MultipleDisputesOnSameProposal() public {
        console2.log("=== Edge Case: Multiple Disputes on Same Proposal ===");
        
        // Create and approve proposal
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("controversial"), "Controversial");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        // Multiple validators create disputes
        vm.prank(validator2);
        uint256 disputeId1 = disputeResolver.createDispute(proposalId, 100e18);
        
        vm.prank(validator3);
        uint256 disputeId2 = disputeResolver.createDispute(proposalId, 150e18);
        
        console2.log("Created 2 disputes on same proposal");
        
        // Different outcomes for each dispute
        // Dispute 1: Challenger wins - need 2 votes out of 3 (>= 50%)
        vm.prank(validator3);
        disputeResolver.voteOnDispute(disputeId1, true, createDisputeVoteSignature(VALIDATOR3_PRIVATE_KEY, disputeId1, true));
        
        vm.prank(validator1);
        disputeResolver.voteOnDispute(disputeId1, true, createDisputeVoteSignature(VALIDATOR1_PRIVATE_KEY, disputeId1, true));
        
        // Dispute 2: Proposer wins - only 1 vote for challenge (< 50%)
        vm.prank(validator1);
        disputeResolver.voteOnDispute(disputeId2, true, createDisputeVoteSignature(VALIDATOR1_PRIVATE_KEY, disputeId2, true));
        
        // Resolve both disputes
        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);
        
        disputeResolver.resolveDispute(disputeId1);
        IDisputeResolver.Dispute memory dispute1 = disputeResolver.getDispute(disputeId1);
        assertTrue(dispute1.challengerWon);
        console2.log("Dispute 1: Challenger won (2/3 votes)");
        
        disputeResolver.resolveDispute(disputeId2);
        IDisputeResolver.Dispute memory dispute2 = disputeResolver.getDispute(disputeId2);
        assertFalse(dispute2.challengerWon);
        console2.log("Dispute 2: Proposer won (1/3 votes)");
        
        // Check disputes array
        uint256[] memory disputes = disputeResolver.getDisputesByProposal(proposalId);
        assertEq(disputes.length, 2);
    }

    // Test: Tie vote in consensus
    function test_EdgeCase_TieVoteInConsensus() public {
        console2.log("=== Edge Case: Tie Vote in Consensus ===");
        
        // Setup 4th validator with proper private key
        uint256 validator4PrivateKey = 0x4444;
        address validator4 = vm.addr(validator4PrivateKey);
        setupValidator(validator4, 1500e18);
        
        // Create proposal and challenge
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("tie test"), "Tie Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        vm.prank(validator2);
        proposalManager.challengeProposal(proposalId);
        
        // Initiate consensus
        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        // Create tie: 2 for, 2 against
        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true));
        
        vm.prank(validator2);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR2_PRIVATE_KEY, roundId, true));
        
        vm.prank(validator3);
        consensusEngine.castVote(roundId, false, createVoteSignature(VALIDATOR3_PRIVATE_KEY, roundId, false));
        
        vm.prank(validator4);
        consensusEngine.castVote(roundId, false, createVoteSignature(validator4PrivateKey, roundId, false));
        
        console2.log("Created tie: 2 for, 2 against");
        
        // Finalize - tie should result in rejection (not meeting quorum)
        vm.roll(block.number + VOTING_PERIOD + 1);
        bool approved = consensusEngine.finalizeConsensus(roundId);
        assertFalse(approved);
        console2.log("Tie vote results in proposal rejection");
    }

    // Test: Zero participation in consensus
    function test_EdgeCase_ZeroParticipationInConsensus() public {
        console2.log("=== Edge Case: Zero Participation in Consensus ===");
        
        // Create proposal and challenge
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("ignored"), "Ignored");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        vm.prank(validator2);
        proposalManager.challengeProposal(proposalId);
        
        // Initiate consensus
        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        // No one votes
        console2.log("No validators vote in consensus");
        
        // Finalize with zero participation
        vm.roll(block.number + VOTING_PERIOD + 1);
        bool approved = consensusEngine.finalizeConsensus(roundId);
        assertFalse(approved); // 0% < 60% quorum
        
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.Challenged));
        console2.log("Zero participation - proposal remains in Challenged state");
    }

    // Test: Validator slashed multiple times
    function test_EdgeCase_ValidatorSlashedMultipleTimes() public {
        console2.log("=== Edge Case: Validator Slashed Multiple Times ===");
        
        // Validator1 creates multiple bad proposals
        uint256[] memory proposalIds = new uint256[](3);
        uint256[] memory disputeIds = new uint256[](3);
        
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(validator1);
            proposalIds[i] = proposalManager.createProposal(
                keccak256(abi.encodePacked("bad proposal", i)), 
                string(abi.encodePacked("Bad ", i))
            );
            
            vm.prank(proposalManagerRole);
            proposalManager.approveOptimistically(proposalIds[i]);
            
            vm.prank(validator2);
            disputeIds[i] = disputeResolver.createDispute(proposalIds[i], 100e18);
        }
        
        console2.log("Created 3 disputes against validator1");
        
        // Resolve all disputes against validator1
        IValidatorRegistry.ValidatorInfo memory infoBefore = validatorRegistry.getValidatorInfo(validator1);
        console2.log("Validator1 stake before slashing:", infoBefore.stakedAmount / 1e18);
        
        // Vote on all disputes first - need 2 votes out of 3 for challenger to win
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(validator3);
            disputeResolver.voteOnDispute(
                disputeIds[i], 
                true, 
                createDisputeVoteSignature(VALIDATOR3_PRIVATE_KEY, disputeIds[i], true)
            );
            
            vm.prank(validator2);
            disputeResolver.voteOnDispute(
                disputeIds[i], 
                true, 
                createDisputeVoteSignature(VALIDATOR2_PRIVATE_KEY, disputeIds[i], true)
            );
        }
        
        // Then warp time and resolve all
        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);
        
        for (uint256 i = 0; i < 3; i++) {
            disputeResolver.resolveDispute(disputeIds[i]);
        }
        
        IValidatorRegistry.ValidatorInfo memory infoAfter = validatorRegistry.getValidatorInfo(validator1);
        console2.log("Validator1 stake after 3 slashings:", infoAfter.stakedAmount / 1e18);
        
        // Check cumulative slashing effect
        uint256 totalSlashed = infoBefore.stakedAmount - infoAfter.stakedAmount;
        assertEq(totalSlashed, 30e18); // 3 * 10 GLT (10% of 100 GLT stake each)
        
        if (infoAfter.stakedAmount < MINIMUM_STAKE) {
            assertEq(uint8(infoAfter.status), uint8(IValidatorRegistry.ValidatorStatus.Slashed));
            assertFalse(validatorRegistry.isActiveValidator(validator1));
            console2.log("Validator1 slashed below minimum and deactivated");
        }
    }
}