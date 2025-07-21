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
 * @title EdgeCaseIntegrationTest
 * @dev Integration tests for edge cases and error scenarios
 */
contract EdgeCaseIntegrationTest is Test {
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

    address public validator1;
    address public validator2;
    address public validator3;

    uint256 constant MINIMUM_STAKE = 1000e18;
    uint256 constant MAX_VALIDATORS = 100;
    uint256 constant CHALLENGE_WINDOW = 10;
    uint256 constant VOTING_PERIOD = 100;
    uint256 constant DISPUTE_VOTING_PERIOD = 50;

    function setUp() public {
        validator1 = vm.addr(VALIDATOR1_PRIVATE_KEY);
        validator2 = vm.addr(VALIDATOR2_PRIVATE_KEY);
        validator3 = vm.addr(VALIDATOR3_PRIVATE_KEY);

        gltToken = new GLTToken(deployer);
        llmOracle = new MockLLMOracle();
        validatorRegistry = new ValidatorRegistry(address(gltToken), deployer, 5);
        proposalManager = new ProposalManager(address(validatorRegistry), address(llmOracle), proposalManagerRole);
        consensusEngine =
            new ConsensusEngine(address(validatorRegistry), address(proposalManager), consensusInitiatorRole);
        disputeResolver = new DisputeResolver(address(gltToken), address(validatorRegistry), address(proposalManager));

        validatorRegistry.setSlasher(address(disputeResolver));

        setupValidator(validator1, 2000e18);
        setupValidator(validator2, 1500e18);
        setupValidator(validator3, 1000e18);
    }

    function setupValidator(address validator, uint256 stake) internal {
        gltToken.mint(validator, 10_000e18);
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

    function test_EdgeCase_ChallengeWindowExpiryDuringDispute() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.roll(block.number + CHALLENGE_WINDOW - 1);

        vm.prank(validator2);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 100e18);

        vm.roll(block.number + 2);

        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertEq(uint8(dispute.state), uint8(IDisputeResolver.DisputeState.Active));

        vm.prank(validator3);
        disputeResolver.voteOnDispute(
            disputeId, true, createDisputeVoteSignature(VALIDATOR3_PRIVATE_KEY, disputeId, true)
        );

        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);
        disputeResolver.resolveDispute(disputeId);
    }

    function test_EdgeCase_MaximumValidatorsReached() public {
        uint256 activeValidatorLimit = validatorRegistry.activeValidatorLimit();

        for (uint256 i = 4; i <= activeValidatorLimit; ++i) {
            address newValidator = address(uint160(i * 1000));
            gltToken.mint(newValidator, 2000e18);

            vm.startPrank(newValidator);
            gltToken.approve(address(validatorRegistry), type(uint256).max);
            validatorRegistry.registerValidator(1000e18);
            vm.stopPrank();
        }

        address[] memory activeValidators = validatorRegistry.getActiveValidators();
        assertEq(activeValidators.length, activeValidatorLimit);

        address extraValidator = address(0xEEEE);
        gltToken.mint(extraValidator, 5000e18);

        vm.startPrank(extraValidator);
        gltToken.approve(address(validatorRegistry), type(uint256).max);
        validatorRegistry.registerValidator(3000e18);
        vm.stopPrank();

        activeValidators = validatorRegistry.getActiveValidators();
        assertEq(activeValidators.length, activeValidatorLimit);
        assertTrue(validatorRegistry.isActiveValidator(extraValidator));
    }

    function test_EdgeCase_MinimumQuorumExactlyMet() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.prank(validator2);
        proposalManager.challengeProposal(proposalId);

        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);

        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true));

        vm.prank(validator2);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR2_PRIVATE_KEY, roundId, true));

        vm.roll(block.number + VOTING_PERIOD + 1);
        bool approved = consensusEngine.finalizeConsensus(roundId);
        assertTrue(approved);
    }

    function test_EdgeCase_InsufficientBalanceForChallenge() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        uint256 balance = gltToken.balanceOf(validator3);
        vm.prank(validator3);
        gltToken.transfer(address(0x9999), balance - 50e18);

        vm.expectRevert();
        vm.prank(validator3);
        disputeResolver.createDispute(proposalId, 100e18);
    }

    function test_EdgeCase_ValidatorUnstakingDuringConsensus() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.prank(validator2);
        proposalManager.challengeProposal(proposalId);

        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);

        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true));

        vm.prank(validator2);
        validatorRegistry.requestUnstake(1500e18);

        vm.expectRevert(IConsensusEngine.NotActiveValidator.selector);
        vm.prank(validator2);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR2_PRIVATE_KEY, roundId, true));

        vm.roll(block.number + VOTING_PERIOD + 1);
        bool approved = consensusEngine.finalizeConsensus(roundId);
        assertFalse(approved);
    }

    function test_EdgeCase_MultipleDisputesOnSameProposal() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("controversial"), "Controversial");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.prank(validator2);
        uint256 disputeId1 = disputeResolver.createDispute(proposalId, 100e18);

        vm.prank(validator3);
        uint256 disputeId2 = disputeResolver.createDispute(proposalId, 150e18);

        vm.prank(validator3);
        disputeResolver.voteOnDispute(
            disputeId1, true, createDisputeVoteSignature(VALIDATOR3_PRIVATE_KEY, disputeId1, true)
        );

        vm.prank(validator1);
        disputeResolver.voteOnDispute(
            disputeId1, true, createDisputeVoteSignature(VALIDATOR1_PRIVATE_KEY, disputeId1, true)
        );

        vm.prank(validator1);
        disputeResolver.voteOnDispute(
            disputeId2, true, createDisputeVoteSignature(VALIDATOR1_PRIVATE_KEY, disputeId2, true)
        );

        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);

        disputeResolver.resolveDispute(disputeId1);
        IDisputeResolver.Dispute memory dispute1 = disputeResolver.getDispute(disputeId1);
        assertTrue(dispute1.challengerWon);

        disputeResolver.resolveDispute(disputeId2);
        IDisputeResolver.Dispute memory dispute2 = disputeResolver.getDispute(disputeId2);
        assertFalse(dispute2.challengerWon);

        uint256[] memory disputes = disputeResolver.getDisputesByProposal(proposalId);
        assertEq(disputes.length, 2);
    }

    function test_EdgeCase_TieVoteInConsensus() public {
        uint256 validator4PrivateKey = 0x4444;
        address validator4 = vm.addr(validator4PrivateKey);
        setupValidator(validator4, 1500e18);

        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("tie test"), "Tie Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.prank(validator2);
        proposalManager.challengeProposal(proposalId);

        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);

        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true));

        vm.prank(validator2);
        consensusEngine.castVote(roundId, true, createVoteSignature(VALIDATOR2_PRIVATE_KEY, roundId, true));

        vm.prank(validator3);
        consensusEngine.castVote(roundId, false, createVoteSignature(VALIDATOR3_PRIVATE_KEY, roundId, false));

        vm.prank(validator4);
        consensusEngine.castVote(roundId, false, createVoteSignature(validator4PrivateKey, roundId, false));

        vm.roll(block.number + VOTING_PERIOD + 1);
        bool approved = consensusEngine.finalizeConsensus(roundId);
        assertFalse(approved);
    }

    function test_EdgeCase_ZeroParticipationInConsensus() public {
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("ignored"), "Ignored");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.prank(validator2);
        proposalManager.challengeProposal(proposalId);

        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);

        vm.roll(block.number + VOTING_PERIOD + 1);
        bool approved = consensusEngine.finalizeConsensus(roundId);
        assertFalse(approved);

        IProposalManager.Proposal memory proposal = proposalManager.getProposal(proposalId);
        assertEq(uint8(proposal.state), uint8(IProposalManager.ProposalState.Challenged));
    }

    function test_EdgeCase_ValidatorSlashedMultipleTimes() public {
        uint256[] memory proposalIds = new uint256[](3);
        uint256[] memory disputeIds = new uint256[](3);

        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(validator1);
            proposalIds[i] = proposalManager.createProposal(
                keccak256(abi.encodePacked("bad proposal", i)), string(abi.encodePacked("Bad ", i))
            );

            vm.prank(proposalManagerRole);
            proposalManager.approveOptimistically(proposalIds[i]);

            vm.prank(validator2);
            disputeIds[i] = disputeResolver.createDispute(proposalIds[i], 100e18);
        }

        IValidatorRegistry.ValidatorInfo memory infoBefore = validatorRegistry.getValidatorInfo(validator1);

        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(validator3);
            disputeResolver.voteOnDispute(
                disputeIds[i], true, createDisputeVoteSignature(VALIDATOR3_PRIVATE_KEY, disputeIds[i], true)
            );

            vm.prank(validator2);
            disputeResolver.voteOnDispute(
                disputeIds[i], true, createDisputeVoteSignature(VALIDATOR2_PRIVATE_KEY, disputeIds[i], true)
            );
        }

        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);

        for (uint256 i = 0; i < 3; ++i) {
            disputeResolver.resolveDispute(disputeIds[i]);
        }

        IValidatorRegistry.ValidatorInfo memory infoAfter = validatorRegistry.getValidatorInfo(validator1);

        uint256 totalSlashed = infoBefore.stakedAmount - infoAfter.stakedAmount;
        assertEq(totalSlashed, 30e18);

        if (infoAfter.stakedAmount < MINIMUM_STAKE) {
            assertEq(uint8(infoAfter.status), uint8(IValidatorRegistry.ValidatorStatus.Slashed));
            assertFalse(validatorRegistry.isActiveValidator(validator1));
        }
    }
}
