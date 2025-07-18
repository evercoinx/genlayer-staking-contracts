// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { ProposalManager } from "../../src/ProposalManager.sol";
import { IProposalManager } from "../../src/interfaces/IProposalManager.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { MockLLMOracle } from "../../src/MockLLMOracle.sol";
import { GLTToken } from "../../src/GLTToken.sol";

/**
 * @title ProposalManagerTest
 * @dev Test suite for ProposalManager contract.
 */
contract ProposalManagerTest is Test {
    ProposalManager public proposalManager;
    ValidatorRegistry public validatorRegistry;
    MockLLMOracle public llmOracle;
    GLTToken public gltToken;
    
    address public deployer = address(this);
    address public slasher = address(0x1);
    address public validator1 = address(0x2);
    address public validator2 = address(0x3);
    address public validator3 = address(0x4);
    address public nonValidator = address(0x5);
    address public proposalManagerRole = address(0x6);
    
    uint256 constant MINIMUM_STAKE = 1000e18;
    uint256 constant CHALLENGE_WINDOW_DURATION = 10;

    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, bytes32 contentHash);
    event ProposalOptimisticallyApproved(uint256 indexed proposalId, uint256 challengeWindowEnd);
    event ProposalChallenged(uint256 indexed proposalId, address indexed challenger);
    event ProposalFinalized(uint256 indexed proposalId, IProposalManager.ProposalState state);
    event ProposalRejected(uint256 indexed proposalId, string reason);

    function setUp() public {
        // Deploy GLT token
        gltToken = new GLTToken(deployer);
        
        // Deploy ValidatorRegistry
        validatorRegistry = new ValidatorRegistry(address(gltToken), slasher);
        
        // Deploy MockLLMOracle
        llmOracle = new MockLLMOracle();
        
        // Deploy ProposalManager
        proposalManager = new ProposalManager(
            address(validatorRegistry),
            address(llmOracle),
            proposalManagerRole
        );
        
        // Setup validators
        gltToken.mint(validator1, 10_000e18);
        gltToken.mint(validator2, 10_000e18);
        gltToken.mint(validator3, 10_000e18);
        
        vm.prank(validator1);
        gltToken.approve(address(validatorRegistry), type(uint256).max);
        vm.prank(validator1);
        validatorRegistry.registerValidator(2000e18);
        
        vm.prank(validator2);
        gltToken.approve(address(validatorRegistry), type(uint256).max);
        vm.prank(validator2);
        validatorRegistry.registerValidator(2000e18);
        
        vm.prank(validator3);
        gltToken.approve(address(validatorRegistry), type(uint256).max);
        vm.prank(validator3);
        validatorRegistry.registerValidator(2000e18);
    }

    // Create Proposal Tests
    function test_CreateProposal_Success() public {
        bytes32 contentHash = keccak256("proposal content");
        string memory metadata = "Test proposal";
        
        vm.expectEmit(true, true, false, true);
        emit ProposalCreated(1, validator1, contentHash);
        
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(contentHash, metadata);
        
        assertEq(proposalId, 1, "Proposal ID should be 1");
        
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(proposal.proposer, validator1);
        assertEq(proposal.contentHash, contentHash);
        assertEq(proposal.metadata, metadata);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.Proposed));
        assertEq(proposal.createdAt, block.timestamp);
        assertEq(proposal.challengeWindowEnd, 0);
        assertEq(proposal.validatorApprovals, 0);
        assertFalse(proposal.llmValidated);
    }

    function test_CreateProposal_RevertIfNotActiveValidator() public {
        bytes32 contentHash = keccak256("proposal content");
        string memory metadata = "Test proposal";
        
        vm.expectRevert("ProposalManager: caller is not an active validator");
        vm.prank(nonValidator);
        proposalManager.createProposal(contentHash, metadata);
    }

    function test_CreateProposal_RevertIfEmptyContentHash() public {
        bytes32 emptyHash = bytes32(0);
        string memory metadata = "Test proposal";
        
        vm.expectRevert(IProposalManager.InvalidContentHash.selector);
        vm.prank(validator1);
        proposalManager.createProposal(emptyHash, metadata);
    }

    function test_CreateProposal_RevertIfEmptyMetadata() public {
        bytes32 contentHash = keccak256("proposal content");
        string memory metadata = "";
        
        vm.expectRevert(IProposalManager.EmptyMetadata.selector);
        vm.prank(validator1);
        proposalManager.createProposal(contentHash, metadata);
    }

    function test_CreateProposal_MultipleProposals() public {
        bytes32 contentHash1 = keccak256("proposal 1");
        bytes32 contentHash2 = keccak256("proposal 2");
        
        vm.prank(validator1);
        uint256 proposalId1 = proposalManager.createProposal(contentHash1, "Proposal 1");
        
        vm.prank(validator2);
        uint256 proposalId2 = proposalManager.createProposal(contentHash2, "Proposal 2");
        
        assertEq(proposalId1, 1);
        assertEq(proposalId2, 2);
        assertEq(proposalManager.getTotalProposals(), 2);
    }

    // Optimistic Approval Tests
    function test_ApproveOptimistically_Success() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        uint256 expectedChallengeWindowEnd = block.number + CHALLENGE_WINDOW_DURATION;
        
        vm.expectEmit(true, false, false, true);
        emit ProposalOptimisticallyApproved(proposalId, expectedChallengeWindowEnd);
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.OptimisticApproved));
        assertEq(proposal.challengeWindowEnd, expectedChallengeWindowEnd);
    }

    function test_ApproveOptimistically_RevertIfNotProposalManager() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.expectRevert("ProposalManager: caller is not the proposal manager");
        vm.prank(validator2);
        proposalManager.approveOptimistically(proposalId);
    }

    function test_ApproveOptimistically_RevertIfInvalidState() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        // Approve once
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        // Try to approve again
        vm.expectRevert(IProposalManager.InvalidStateTransition.selector);
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
    }

    // Challenge Proposal Tests
    function test_ChallengeProposal_Success() public {
        // Create and optimistically approve proposal
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        // Challenge within window
        vm.expectEmit(true, true, false, false);
        emit ProposalChallenged(proposalId, validator2);
        
        vm.prank(validator2);
        proposalManager.challengeProposal(proposalId);
        
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.Challenged));
    }

    function test_ChallengeProposal_RevertIfNotActiveValidator() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        vm.expectRevert("ProposalManager: caller is not an active validator");
        vm.prank(nonValidator);
        proposalManager.challengeProposal(proposalId);
    }

    function test_ChallengeProposal_RevertIfOutsideChallengeWindow() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        // Move past challenge window
        vm.roll(block.number + CHALLENGE_WINDOW_DURATION + 1);
        
        vm.expectRevert(IProposalManager.ChallengeWindowExpired.selector);
        vm.prank(validator2);
        proposalManager.challengeProposal(proposalId);
    }

    function test_ChallengeProposal_RevertIfNotOptimisticallyApproved() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.expectRevert(IProposalManager.ProposalNotChallengeable.selector);
        vm.prank(validator2);
        proposalManager.challengeProposal(proposalId);
    }

    // Finalize Proposal Tests
    function test_FinalizeProposal_Success() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        // Move past challenge window
        vm.roll(block.number + CHALLENGE_WINDOW_DURATION + 1);
        
        vm.expectEmit(true, false, false, true);
        emit ProposalFinalized(proposalId, IProposalManager.ProposalState.Finalized);
        
        proposalManager.finalizeProposal(proposalId);
        
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.Finalized));
    }

    function test_FinalizeProposal_RevertIfNotOptimisticallyApproved() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.expectRevert(IProposalManager.InvalidStateTransition.selector);
        proposalManager.finalizeProposal(proposalId);
    }

    function test_FinalizeProposal_RevertIfWithinChallengeWindow() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        vm.expectRevert(IProposalManager.ChallengeWindowActive.selector);
        proposalManager.finalizeProposal(proposalId);
    }

    function test_FinalizeProposal_RevertIfChallenged() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        vm.prank(validator2);
        proposalManager.challengeProposal(proposalId);
        
        vm.roll(block.number + CHALLENGE_WINDOW_DURATION + 1);
        
        vm.expectRevert(IProposalManager.InvalidStateTransition.selector);
        proposalManager.finalizeProposal(proposalId);
    }

    // Reject Proposal Tests
    function test_RejectProposal_Success() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        string memory reason = "Rejected by admin";
        
        vm.expectEmit(true, false, false, true);
        emit ProposalRejected(proposalId, reason);
        
        vm.prank(proposalManagerRole);
        proposalManager.rejectProposal(proposalId, reason);
        
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.Rejected));
    }

    function test_RejectProposal_RevertIfUnauthorized() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.expectRevert("ProposalManager: caller is not the proposal manager");
        vm.prank(validator2);
        proposalManager.rejectProposal(proposalId, "Unauthorized reject");
    }

    function test_RejectProposal_RevertIfAlreadyFinalized() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        vm.roll(block.number + CHALLENGE_WINDOW_DURATION + 1);
        proposalManager.finalizeProposal(proposalId);
        
        vm.expectRevert(IProposalManager.InvalidStateTransition.selector);
        vm.prank(proposalManagerRole);
        proposalManager.rejectProposal(proposalId, "Too late");
    }

    // LLM Validation Tests
    function test_UpdateLLMValidation_Success() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.updateLLMValidation(proposalId, true);
        
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertTrue(proposal.llmValidated);
    }

    function test_UpdateLLMValidation_RevertIfUnauthorized() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.expectRevert("ProposalManager: caller is not the proposal manager");
        vm.prank(validator1);
        proposalManager.updateLLMValidation(proposalId, true);
    }

    // Validator Approval Tests
    function test_RecordValidatorApproval_Success() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.prank(validator2);
        proposalManager.recordValidatorApproval(proposalId);
        
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(proposal.validatorApprovals, 1);
        
        vm.prank(validator3);
        proposalManager.recordValidatorApproval(proposalId);
        
        proposal = proposalManager.getProposal(proposalId);
        assertEq(proposal.validatorApprovals, 2);
    }

    function test_RecordValidatorApproval_RevertIfNotActiveValidator() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.expectRevert("ProposalManager: caller is not an active validator");
        vm.prank(nonValidator);
        proposalManager.recordValidatorApproval(proposalId);
    }

    // Admin Tests
    function test_SetProposalManager_Success() public {
        address newManager = address(0x999);
        
        proposalManager.setProposalManager(newManager);
        
        assertEq(proposalManager.proposalManager(), newManager);
    }

    function test_SetProposalManager_RevertIfUnauthorized() public {
        vm.expectRevert();
        vm.prank(validator1);
        proposalManager.setProposalManager(address(0x999));
    }

    function test_SetProposalManager_RevertIfZeroAddress() public {
        vm.expectRevert("ProposalManager: zero address");
        proposalManager.setProposalManager(address(0));
    }

    // View Functions Tests
    function test_GetProposal_RevertIfNotFound() public {
        vm.expectRevert(IProposalManager.ProposalNotFound.selector);
        proposalManager.getProposal(999);
    }

    function test_GetTotalProposals() public {
        assertEq(proposalManager.getTotalProposals(), 0);
        
        vm.prank(validator1);
        proposalManager.createProposal(keccak256("1"), "Test 1");
        assertEq(proposalManager.getTotalProposals(), 1);
        
        vm.prank(validator2);
        proposalManager.createProposal(keccak256("2"), "Test 2");
        assertEq(proposalManager.getTotalProposals(), 2);
    }

    function test_GetChallengeWindowDuration() public view {
        assertEq(proposalManager.getChallengeWindowDuration(), CHALLENGE_WINDOW_DURATION);
    }

    function test_CanChallenge() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        // Not optimistically approved yet
        assertFalse(proposalManager.canChallenge(proposalId));
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        // Within window
        assertTrue(proposalManager.canChallenge(proposalId));
        
        // Move past window
        vm.roll(block.number + CHALLENGE_WINDOW_DURATION + 1);
        assertFalse(proposalManager.canChallenge(proposalId));
    }

    function test_CanFinalize() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        // Not optimistically approved yet
        assertFalse(proposalManager.canFinalize(proposalId));
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        // Still within window
        assertFalse(proposalManager.canFinalize(proposalId));
        
        // Move past window
        vm.roll(block.number + CHALLENGE_WINDOW_DURATION + 1);
        assertTrue(proposalManager.canFinalize(proposalId));
        
        // After finalization
        proposalManager.finalizeProposal(proposalId);
        assertFalse(proposalManager.canFinalize(proposalId));
    }

    function test_GetProposalsByProposer() public {
        vm.prank(validator1);
        uint256 proposalId1 = proposalManager.createProposal(keccak256("1"), "Test 1");
        
        vm.prank(validator1);
        uint256 proposalId2 = proposalManager.createProposal(keccak256("2"), "Test 2");
        
        vm.prank(validator2);
        proposalManager.createProposal(keccak256("3"), "Test 3");
        
        uint256[] memory validator1Proposals = proposalManager.getProposalsByProposer(validator1);
        assertEq(validator1Proposals.length, 2);
        assertEq(validator1Proposals[0], proposalId1);
        assertEq(validator1Proposals[1], proposalId2);
    }

    function test_GetProposalsByState() public {
        // Create proposals
        vm.prank(validator1);
        uint256 proposalId1 = proposalManager.createProposal(keccak256("1"), "Test 1");
        
        vm.prank(validator2);
        uint256 proposalId2 = proposalManager.createProposal(keccak256("2"), "Test 2");
        
        // Check proposed state
        uint256[] memory proposedProposals = proposalManager.getProposalsByState(IProposalManager.ProposalState.Proposed);
        assertEq(proposedProposals.length, 2);
        
        // Approve one optimistically
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId1);
        
        proposedProposals = proposalManager.getProposalsByState(IProposalManager.ProposalState.Proposed);
        assertEq(proposedProposals.length, 1);
        assertEq(proposedProposals[0], proposalId2);
        
        uint256[] memory approvedProposals = proposalManager.getProposalsByState(IProposalManager.ProposalState.OptimisticApproved);
        assertEq(approvedProposals.length, 1);
        assertEq(approvedProposals[0], proposalId1);
    }

    // Edge Cases
    function test_ProposalLifecycle_FullFlow() public {
        // Create proposal
        bytes32 contentHash = keccak256("Full lifecycle test");
        
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(contentHash, "Full lifecycle test");
        
        // Approve optimistically
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.OptimisticApproved));
        
        // Move past challenge window
        vm.roll(block.number + CHALLENGE_WINDOW_DURATION + 1);
        
        // Finalize
        proposalManager.finalizeProposal(proposalId);
        
        proposal = proposalManager.getProposal(proposalId);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.Finalized));
    }

    // Fuzz Tests
    function testFuzz_CreateProposal(bytes32 contentHash, string memory metadata) public {
        vm.assume(contentHash != bytes32(0));
        vm.assume(bytes(metadata).length > 0 && bytes(metadata).length < 1000);
        
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(contentHash, metadata);
        
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(proposal.contentHash, contentHash);
        assertEq(proposal.metadata, metadata);
    }

    function testFuzz_ChallengeWindow(uint256 blockAdvance) public {
        vm.assume(blockAdvance < 1000);
        
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        vm.roll(block.number + blockAdvance);
        
        bool expectedCanChallenge = blockAdvance <= CHALLENGE_WINDOW_DURATION;
        assertEq(proposalManager.canChallenge(proposalId), expectedCanChallenge);
        
        if (expectedCanChallenge) {
            // Should be able to challenge
            vm.prank(validator2);
            proposalManager.challengeProposal(proposalId);
        } else {
            // Should be able to finalize
            proposalManager.finalizeProposal(proposalId);
        }
    }
}