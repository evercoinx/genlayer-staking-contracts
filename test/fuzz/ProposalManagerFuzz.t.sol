// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { IProposalManager } from "../../src/interfaces/IProposalManager.sol";
import { IValidatorRegistry } from "../../src/interfaces/IValidatorRegistry.sol";
import { GLTToken } from "../../src/GLTToken.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { ProposalManager } from "../../src/ProposalManager.sol";
import { MockLLMOracle } from "../../src/MockLLMOracle.sol";

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
        proposalManager = new ProposalManager(address(validatorRegistry), address(llmOracle), proposalManagerRole);

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

    function testFuzz_CreateProposal(bytes32 contentHash, string memory metadata) public {
        vm.assume(contentHash != bytes32(0));
        vm.assume(bytes(metadata).length > 0 && bytes(metadata).length < 10_000);

        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(contentHash, metadata);

        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(proposal.contentHash, contentHash);
        assertEq(proposal.metadata, metadata);
        assertEq(proposal.proposer, validator1);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.Proposed));
    }

    function testFuzz_MultipleProposals(bytes32[] memory contentHashes) public {
        vm.assume(contentHashes.length > 0 && contentHashes.length <= 50);

        uint256[] memory proposalIds = new uint256[](contentHashes.length);
        uint256 validProposals = 0;

        for (uint256 i = 0; i < contentHashes.length; i++) {
            if (contentHashes[i] == bytes32(0)) continue;

            vm.prank(validator1);
            proposalIds[validProposals] =
                proposalManager.createProposal(contentHashes[i], string(abi.encodePacked("Proposal ", i)));
            validProposals++;
        }

        assertEq(proposalManager.getTotalProposals(), validProposals);

        uint256[] memory proposerProposals = proposalManager.getProposalsByProposer(validator1);
        assertEq(proposerProposals.length, validProposals);
    }

    function testFuzz_ChallengeWindowTiming(uint256 blockAdvance) public {
        blockAdvance = bound(blockAdvance, 0, 999);

        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.roll(block.number + blockAdvance);

        if (blockAdvance <= CHALLENGE_WINDOW) {
            assertTrue(proposalManager.canChallenge(proposalId));
            vm.prank(validator2);
            proposalManager.challengeProposal(proposalId);

            IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
            assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.Challenged));
        } else {
            assertFalse(proposalManager.canChallenge(proposalId));
            vm.expectRevert(IProposalManager.ChallengeWindowExpired.selector);
            vm.prank(validator2);
            proposalManager.challengeProposal(proposalId);
        }
    }


    function testFuzz_StateTransitions(uint8[] memory operations) public {
        if (operations.length == 0) {
            operations = new uint8[](1);
            operations[0] = 0;
        }
        if (operations.length > 30) {
            uint8[] memory truncated = new uint8[](30);
            for (uint256 i = 0; i < 30; i++) {
                truncated[i] = operations[i];
            }
            operations = truncated;
        }

        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("state test"), "State Test");

        for (uint256 i = 0; i < operations.length; i++) {
            uint8 op = operations[i] % 5;
            IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);

            if (op == 0) {
                if (proposal.state == IProposalManager.ProposalState.Proposed) {
                    vm.prank(proposalManagerRole);
                    proposalManager.approveOptimistically(proposalId);
                }
            } else if (op == 1) {
                if (
                    proposal.state == IProposalManager.ProposalState.OptimisticApproved
                        && proposalManager.canChallenge(proposalId)
                ) {
                    vm.prank(validator2);
                    proposalManager.challengeProposal(proposalId);
                }
            } else if (op == 2) {
                if (proposalManager.canFinalize(proposalId)) {
                    proposalManager.finalizeProposal(proposalId);
                }
            } else if (op == 3) {
                if (
                    proposal.state != IProposalManager.ProposalState.Finalized
                        && proposal.state != IProposalManager.ProposalState.Rejected
                ) {
                    vm.prank(proposalManagerRole);
                    proposalManager.rejectProposal(proposalId, "Fuzz rejection");
                }
            } else if (op == 4) {
                vm.roll(block.number + (operations[i] % 20));
            }
        }

        IProposalManager.Proposal memory finalProposal = proposalManager.getProposal(proposalId);
        assertTrue(
            finalProposal.state == IProposalManager.ProposalState.Proposed
                || finalProposal.state == IProposalManager.ProposalState.OptimisticApproved
                || finalProposal.state == IProposalManager.ProposalState.Challenged
                || finalProposal.state == IProposalManager.ProposalState.Finalized
                || finalProposal.state == IProposalManager.ProposalState.Rejected
        );
    }

    function testFuzz_MetadataSize(uint256 size, uint256 seed) public {
        size = bound(size, 1, 100_000);

        bytes memory metadataBytes = new bytes(size);
        for (uint256 i = 0; i < size; i++) {
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

}
