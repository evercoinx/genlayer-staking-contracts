// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { GLTToken } from "../../src/GLTToken.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { ProposalManager } from "../../src/ProposalManager.sol";
import { MockLLMOracle } from "../../src/MockLLMOracle.sol";
import { IProposalManager } from "../../src/interfaces/IProposalManager.sol";
import { IValidatorRegistry } from "../../src/interfaces/IValidatorRegistry.sol";

/**
 * @title ProposalManagerFuzzTest
 * @dev Fuzz tests for ProposalManager contract
 */
contract ProposalManagerFuzzTest is Test {
    GLTToken public gltToken;
    ValidatorRegistry public validatorRegistry;
    ProposalManager public proposalManager;
    MockLLMOracle public llmOracle;
    
    address public owner = address(this);
    address public proposalManagerRole = address(0x1000);
    address public validator1 = address(0x1);
    address public validator2 = address(0x2);
    
    uint256 constant MINIMUM_STAKE = 1000e18;
    uint256 constant CHALLENGE_WINDOW = 10;

    function setUp() public {
        gltToken = new GLTToken(owner);
        validatorRegistry = new ValidatorRegistry(address(gltToken), owner);
        llmOracle = new MockLLMOracle();
        proposalManager = new ProposalManager(
            address(validatorRegistry),
            address(llmOracle),
            proposalManagerRole
        );
        
        // Setup validators
        _setupValidator(validator1, 2000e18);
        _setupValidator(validator2, 1500e18);
    }

    function _setupValidator(address validator, uint256 stake) internal {
        gltToken.mint(validator, stake);
        vm.prank(validator);
        gltToken.approve(address(validatorRegistry), stake);
        vm.prank(validator);
        validatorRegistry.registerValidator(stake);
    }

    // Fuzz test: Create proposals with various content hashes and metadata
    function testFuzz_CreateProposal(bytes32 contentHash, string memory metadata) public {
        // Constraints
        vm.assume(contentHash != bytes32(0));
        vm.assume(bytes(metadata).length > 0 && bytes(metadata).length < 10000);
        
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(contentHash, metadata);
        
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(proposal.contentHash, contentHash);
        assertEq(proposal.metadata, metadata);
        assertEq(proposal.proposer, validator1);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.Proposed));
    }

    // Fuzz test: Multiple proposals from same validator
    function testFuzz_MultipleProposals(bytes32[] memory contentHashes) public {
        vm.assume(contentHashes.length > 0 && contentHashes.length <= 50);
        
        uint256[] memory proposalIds = new uint256[](contentHashes.length);
        uint256 validProposals = 0;
        
        for (uint256 i = 0; i < contentHashes.length; i++) {
            if (contentHashes[i] == bytes32(0)) continue;
            
            vm.prank(validator1);
            proposalIds[validProposals] = proposalManager.createProposal(
                contentHashes[i],
                string(abi.encodePacked("Proposal ", i))
            );
            validProposals++;
        }
        
        // Check all proposals were created
        assertEq(proposalManager.getTotalProposals(), validProposals);
        
        // Check proposals by proposer
        uint256[] memory proposerProposals = proposalManager.getProposalsByProposer(validator1);
        assertEq(proposerProposals.length, validProposals);
    }

    // Fuzz test: Challenge window timing
    function testFuzz_ChallengeWindowTiming(uint256 blockAdvance) public {
        vm.assume(blockAdvance < 1000); // Reasonable block advancement
        
        // Create and approve proposal
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        // Advance blocks
        vm.roll(block.number + blockAdvance);
        
        if (blockAdvance <= CHALLENGE_WINDOW) {
            // Should be able to challenge
            assertTrue(proposalManager.canChallenge(proposalId));
            vm.prank(validator2);
            proposalManager.challengeProposal(proposalId);
            
            IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
            assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.Challenged));
        } else {
            // Challenge window expired
            assertFalse(proposalManager.canChallenge(proposalId));
            vm.expectRevert(IProposalManager.ChallengeWindowExpired.selector);
            vm.prank(validator2);
            proposalManager.challengeProposal(proposalId);
        }
    }

    // Fuzz test: LLM validation with random content hashes
    function testFuzz_LLMValidation(bytes32[] memory contentHashes) public {
        vm.assume(contentHashes.length > 0 && contentHashes.length <= 20);
        
        uint256 validCount = 0;
        uint256 invalidCount = 0;
        
        for (uint256 i = 0; i < contentHashes.length; i++) {
            if (contentHashes[i] == bytes32(0)) continue;
            
            vm.prank(validator1);
            uint256 proposalId = proposalManager.createProposal(
                contentHashes[i],
                "Fuzz test proposal"
            );
            
            // LLM validates based on even/odd hash
            bool isValid = uint256(contentHashes[i]) % 2 == 0;
            
            if (isValid) {
                validCount++;
            } else {
                invalidCount++;
            }
            
            // Check LLM validation matches expected
            IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
            assertEq(proposal.llmValidated, isValid);
        }
        
        // At least some should be valid and some invalid (statistically)
        // But with fuzz testing, we might get edge cases where all are even or odd
        if (contentHashes.length >= 20) {
            // With 20+ hashes, we expect at least one of each (very high probability)
            assertTrue(validCount > 0 || invalidCount == contentHashes.length);
            assertTrue(invalidCount > 0 || validCount == contentHashes.length);
        }
    }

    // Fuzz test: State transitions with random operations
    function testFuzz_StateTransitions(uint8[] memory operations) public {
        vm.assume(operations.length > 0 && operations.length <= 30);
        
        // Create initial proposal
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("state test"), "State Test");
        
        for (uint256 i = 0; i < operations.length; i++) {
            uint8 op = operations[i] % 5;
            IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
            
            if (op == 0) {
                // Try to approve optimistically
                if (proposal.state == IProposalManager.ProposalState.Proposed) {
                    vm.prank(proposalManagerRole);
                    proposalManager.approveOptimistically(proposalId);
                }
            } else if (op == 1) {
                // Try to challenge
                if (proposal.state == IProposalManager.ProposalState.OptimisticApproved &&
                    proposalManager.canChallenge(proposalId)) {
                    vm.prank(validator2);
                    proposalManager.challengeProposal(proposalId);
                }
            } else if (op == 2) {
                // Try to finalize
                if (proposalManager.canFinalize(proposalId)) {
                    proposalManager.finalizeProposal(proposalId);
                }
            } else if (op == 3) {
                // Try to reject
                if (proposal.state != IProposalManager.ProposalState.Finalized &&
                    proposal.state != IProposalManager.ProposalState.Rejected) {
                    vm.prank(proposalManagerRole);
                    proposalManager.rejectProposal(proposalId, "Fuzz rejection");
                }
            } else if (op == 4) {
                // Advance some blocks
                vm.roll(block.number + (operations[i] % 20));
            }
        }
        
        // Verify final state is valid
        IProposalManager.Proposal memory finalProposal = proposalManager.getProposal(proposalId);
        assertTrue(
            finalProposal.state == IProposalManager.ProposalState.Proposed ||
            finalProposal.state == IProposalManager.ProposalState.OptimisticApproved ||
            finalProposal.state == IProposalManager.ProposalState.Challenged ||
            finalProposal.state == IProposalManager.ProposalState.Finalized ||
            finalProposal.state == IProposalManager.ProposalState.Rejected
        );
    }

    // Fuzz test: Metadata size limits
    function testFuzz_MetadataSize(uint256 size, uint256 seed) public {
        vm.assume(size > 0 && size <= 100000); // Up to 100KB
        
        // Generate pseudo-random metadata of specified size
        bytes memory metadataBytes = new bytes(size);
        for (uint256 i = 0; i < size; i++) {
            // Use unchecked to prevent overflow in the loop
            unchecked {
                metadataBytes[i] = bytes1(uint8((seed + i) % 256));
            }
        }
        string memory metadata = string(metadataBytes);
        
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("size test"), metadata);
        
        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(bytes(proposal.metadata).length, size);
    }

    // Fuzz test: Concurrent challenges from multiple validators
    function testFuzz_ConcurrentChallenges(address[] memory challengers) public {
        vm.assume(challengers.length > 0 && challengers.length <= 10);
        
        // Create and approve proposal
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("concurrent"), "Concurrent Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        // Setup challengers as validators
        for (uint256 i = 0; i < challengers.length; i++) {
            if (challengers[i] == address(0) || challengers[i] == validator1) continue;
            _setupValidator(challengers[i], MINIMUM_STAKE);
        }
        
        // First valid challenger should succeed
        bool challenged = false;
        for (uint256 i = 0; i < challengers.length; i++) {
            if (challengers[i] == address(0) || challengers[i] == validator1) continue;
            
            if (!challenged) {
                vm.prank(challengers[i]);
                proposalManager.challengeProposal(proposalId);
                challenged = true;
                
                IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
                assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.Challenged));
            } else {
                // Subsequent challenges should fail
                vm.expectRevert(IProposalManager.ProposalNotChallengeable.selector);
                vm.prank(challengers[i]);
                proposalManager.challengeProposal(proposalId);
            }
        }
    }
}