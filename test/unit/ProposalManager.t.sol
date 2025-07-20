// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { IProposalManager } from "../../src/interfaces/IProposalManager.sol";
import { ProposalManager } from "../../src/ProposalManager.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { MockLLMOracle } from "../../src/MockLLMOracle.sol";
import { GLTToken } from "../../src/GLTToken.sol";

/**
 * @title ProposalManagerTest
 * @dev Test suite for ProposalManager contract.
 */
contract ProposalManagerTest is Test {
    // Constants
    uint256 private constant MINIMUM_STAKE = 1_000e18;
    uint256 private constant CHALLENGE_WINDOW_DURATION = 10;

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

    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, bytes32 contentHash);
    event ProposalOptimisticallyApproved(uint256 indexed proposalId, uint256 challengeWindowEnd);
    event ProposalChallenged(uint256 indexed proposalId, address indexed challenger);
    event ProposalFinalized(uint256 indexed proposalId, IProposalManager.ProposalState state);
    event ProposalRejected(uint256 indexed proposalId, string reason);
    event ValidatorApprovalRecorded(uint256 indexed proposalId, address indexed validator, uint256 totalApprovals);
    event LLMValidationUpdated(uint256 indexed proposalId, bool validated);

    function setUp() public {
        gltToken = new GLTToken(deployer);

        validatorRegistry = new ValidatorRegistry(address(gltToken), slasher);

        llmOracle = new MockLLMOracle();

        proposalManager = new ProposalManager(address(validatorRegistry), address(llmOracle), proposalManagerRole);

        gltToken.mint(validator1, 10_000e18);
        gltToken.mint(validator2, 10_000e18);
        gltToken.mint(validator3, 10_000e18);

        vm.prank(validator1);
        gltToken.approve(address(validatorRegistry), type(uint256).max);
        vm.prank(validator1);
        validatorRegistry.registerValidator(2_000e18);

        vm.prank(validator2);
        gltToken.approve(address(validatorRegistry), type(uint256).max);
        vm.prank(validator2);
        validatorRegistry.registerValidator(2_000e18);

        vm.prank(validator3);
        gltToken.approve(address(validatorRegistry), type(uint256).max);
        vm.prank(validator3);
        validatorRegistry.registerValidator(2_000e18);
    }

    // === Create Proposal ===
    function test_CreateProposal_Success() public {
        bytes32 contentHash = keccak256("proposal content");
        string memory metadata = "Test proposal";

        vm.expectEmit(true, true, false, true);
        emit ProposalCreated(1, validator1, contentHash);

        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(contentHash, metadata);

        assertEq(proposalId, 1);

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

    function test_CreateProposal_AllowsNonValidators() public {
        bytes32 contentHash = keccak256("proposal content");
        string memory metadata = "Test proposal";

        vm.expectEmit(true, true, true, true);
        emit ProposalCreated(1, nonValidator, contentHash);

        vm.prank(nonValidator);
        uint256 proposalId = proposalManager.createProposal(contentHash, metadata);

        assertEq(proposalId, 1);

        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(proposal.proposer, nonValidator);
        assertEq(proposal.contentHash, contentHash);
        assertEq(proposal.metadata, metadata);
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

    // === Optimistic Approval ===
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

        vm.expectRevert(IProposalManager.CallerNotProposalManager.selector);
        vm.prank(validator2);
        proposalManager.approveOptimistically(proposalId);
    }

    function test_ApproveOptimistically_RevertIfInvalidState() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        vm.expectRevert(IProposalManager.InvalidStateTransition.selector);
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
    }

    // === Challenge Proposal ===
    function test_ChallengeProposal_Success() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

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

        vm.expectRevert(IProposalManager.CallerNotActiveValidator.selector);
        vm.prank(nonValidator);
        proposalManager.challengeProposal(proposalId);
    }

    function test_ChallengeProposal_RevertIfOutsideChallengeWindow() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

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

    // === Finalize Proposal ===
    function test_FinalizeProposal_Success() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

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

    // === Reject Proposal ===
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

        vm.expectRevert(IProposalManager.CallerNotProposalManager.selector);
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

    // === LLM Validation ===
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

        vm.expectRevert(IProposalManager.CallerNotProposalManager.selector);
        vm.prank(validator1);
        proposalManager.updateLLMValidation(proposalId, true);
    }

    // === Validator Approval ===
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

        vm.expectRevert(IProposalManager.CallerNotActiveValidator.selector);
        vm.prank(nonValidator);
        proposalManager.recordValidatorApproval(proposalId);
    }

    // === Admin Functions ===
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
        vm.expectRevert(IProposalManager.ZeroAddress.selector);
        proposalManager.setProposalManager(address(0));
    }

    // === View Functions ===
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

        assertFalse(proposalManager.canChallenge(proposalId));

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        assertTrue(proposalManager.canChallenge(proposalId));

        vm.roll(block.number + CHALLENGE_WINDOW_DURATION + 1);
        assertFalse(proposalManager.canChallenge(proposalId));
    }

    function test_CanFinalize() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");

        assertFalse(proposalManager.canFinalize(proposalId));

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        assertFalse(proposalManager.canFinalize(proposalId));

        vm.roll(block.number + CHALLENGE_WINDOW_DURATION + 1);
        assertTrue(proposalManager.canFinalize(proposalId));

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
        vm.prank(validator1);
        uint256 proposalId1 = proposalManager.createProposal(keccak256("1"), "Test 1");

        vm.prank(validator2);
        uint256 proposalId2 = proposalManager.createProposal(keccak256("2"), "Test 2");

        uint256[] memory proposedProposals =
            proposalManager.getProposalsByState(IProposalManager.ProposalState.Proposed);
        assertEq(proposedProposals.length, 2);

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId1);

        proposedProposals = proposalManager.getProposalsByState(IProposalManager.ProposalState.Proposed);
        assertEq(proposedProposals.length, 1);
        assertEq(proposedProposals[0], proposalId2);

        uint256[] memory approvedProposals =
            proposalManager.getProposalsByState(IProposalManager.ProposalState.OptimisticApproved);
        assertEq(approvedProposals.length, 1);
        assertEq(approvedProposals[0], proposalId1);
    }

    // === Edge Cases ===
    function test_ProposalLifecycle_FullFlow() public {
        bytes32 contentHash = keccak256("Full lifecycle test");

        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(contentHash, "Full lifecycle test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.OptimisticApproved));

        vm.roll(block.number + CHALLENGE_WINDOW_DURATION + 1);

        proposalManager.finalizeProposal(proposalId);

        proposal = proposalManager.getProposal(proposalId);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.Finalized));
    }

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
        blockAdvance = bound(blockAdvance, 0, 999);

        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.roll(block.number + blockAdvance);

        bool expectedCanChallenge = blockAdvance <= CHALLENGE_WINDOW_DURATION;
        assertEq(proposalManager.canChallenge(proposalId), expectedCanChallenge);

        if (expectedCanChallenge) {
            vm.prank(validator2);
            proposalManager.challengeProposal(proposalId);
        } else {
            proposalManager.finalizeProposal(proposalId);
        }
    }

    function test_RecordValidatorApproval_EmitsEvent() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");

        vm.expectEmit(true, true, false, true);
        emit ValidatorApprovalRecorded(proposalId, validator2, 1);

        vm.prank(validator2);
        proposalManager.recordValidatorApproval(proposalId);

        assertTrue(proposalManager.hasApproved(proposalId, validator2));
    }

    function test_RecordValidatorApproval_PreventDoubleVoting() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");

        vm.prank(validator2);
        proposalManager.recordValidatorApproval(proposalId);

        vm.prank(validator2);
        vm.expectRevert(IProposalManager.ValidatorAlreadyApproved.selector);
        proposalManager.recordValidatorApproval(proposalId);
    }

    function test_UpdateLLMValidation_EmitsEvent() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");

        vm.expectEmit(true, false, false, true);
        emit LLMValidationUpdated(proposalId, true);

        vm.prank(proposalManagerRole);
        proposalManager.updateLLMValidation(proposalId, true);
    }

    function test_GetProposals_BatchRetrieve() public {
        uint256[] memory proposalIds = new uint256[](3);

        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(validator1);
            proposalIds[i] = proposalManager.createProposal(
                keccak256(abi.encodePacked("test", i)), string(abi.encodePacked("Test ", i))
            );
        }

        IProposalManager.Proposal[] memory proposals = proposalManager.getProposals(proposalIds);
        assertEq(proposals.length, 3);

        for (uint256 i = 0; i < 3; ++i) {
            assertEq(proposals[i].id, proposalIds[i]);
            assertEq(proposals[i].proposer, validator1);
        }
    }

    function test_GetProposals_RevertIfNotFound() public {
        uint256[] memory invalidIds = new uint256[](2);
        invalidIds[0] = 999;
        invalidIds[1] = 1000;

        vm.expectRevert(IProposalManager.ProposalNotFound.selector);
        proposalManager.getProposals(invalidIds);
    }

    function test_HasApproved_ReturnsCorrectStatus() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");

        assertFalse(proposalManager.hasApproved(proposalId, validator2));

        vm.prank(validator2);
        proposalManager.recordValidatorApproval(proposalId);

        assertTrue(proposalManager.hasApproved(proposalId, validator2));
        assertFalse(proposalManager.hasApproved(proposalId, validator3));
    }
}
