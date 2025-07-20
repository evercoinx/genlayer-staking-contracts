// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IConsensusEngine } from "../../src/interfaces/IConsensusEngine.sol";
import { IValidatorRegistry } from "../../src/interfaces/IValidatorRegistry.sol";
import { IProposalManager } from "../../src/interfaces/IProposalManager.sol";
import { ConsensusEngine } from "../../src/ConsensusEngine.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { ProposalManager } from "../../src/ProposalManager.sol";
import { MockLLMOracle } from "../../src/MockLLMOracle.sol";
import { GLTToken } from "../../src/GLTToken.sol";

/**
 * @title ConsensusEngineTest
 * @dev Test suite for ConsensusEngine contract.
 */
contract ConsensusEngineTest is Test {
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    ConsensusEngine public consensusEngine;
    ValidatorRegistry public validatorRegistry;
    ProposalManager public proposalManager;
    MockLLMOracle public llmOracle;
    GLTToken public gltToken;
    
    address public deployer = address(this);
    address public slasher = address(0x1);
    address public proposalManagerRole = address(0x2);
    address public consensusInitiator = address(0x3);
    
    // Validator private keys for signature testing
    uint256 constant VALIDATOR1_PRIVATE_KEY = 0x1234;
    uint256 constant VALIDATOR2_PRIVATE_KEY = 0x5678;
    uint256 constant VALIDATOR3_PRIVATE_KEY = 0x9ABC;
    
    address public validator1;
    address public validator2;
    address public validator3;
    address public nonValidator = address(0x999);
    
    uint256 constant MINIMUM_STAKE = 1000e18;
    uint256 constant VOTING_PERIOD = 100;
    uint256 constant QUORUM_PERCENTAGE = 60;

    event ConsensusRoundStarted(
        uint256 indexed proposalId,
        uint256 indexed roundId,
        uint256 startBlock,
        uint256 endBlock
    );
    event VoteCast(uint256 indexed roundId, address indexed validator, bool support);
    event ConsensusFinalized(
        uint256 indexed roundId,
        uint256 indexed proposalId,
        bool approved,
        uint256 votesFor,
        uint256 votesAgainst
    );

    function setUp() public {
        // Derive validator addresses from private keys
        validator1 = vm.addr(VALIDATOR1_PRIVATE_KEY);
        validator2 = vm.addr(VALIDATOR2_PRIVATE_KEY);
        validator3 = vm.addr(VALIDATOR3_PRIVATE_KEY);
        
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
        
        // Deploy ConsensusEngine
        consensusEngine = new ConsensusEngine(
            address(validatorRegistry),
            address(proposalManager),
            consensusInitiator
        );
        
        // Setup validators
        gltToken.mint(validator1, 10_000e18);
        gltToken.mint(validator2, 10_000e18);
        gltToken.mint(validator3, 10_000e18);
        
        vm.prank(validator1);
        gltToken.approve(address(validatorRegistry), type(uint256).max);
        vm.prank(validator1);
        validatorRegistry.registerValidator(3000e18);
        
        vm.prank(validator2);
        gltToken.approve(address(validatorRegistry), type(uint256).max);
        vm.prank(validator2);
        validatorRegistry.registerValidator(2000e18);
        
        vm.prank(validator3);
        gltToken.approve(address(validatorRegistry), type(uint256).max);
        vm.prank(validator3);
        validatorRegistry.registerValidator(1000e18);
    }

    // Helper function to create a valid signature
    function _createVoteSignature(
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

    // Helper function to create a challenged proposal
    function _createChallengedProposal() internal returns (uint256) {
        // Create proposal
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test proposal"), "Test Proposal");
        
        // Approve optimistically
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        // Challenge it
        vm.prank(validator2);
        proposalManager.challengeProposal(proposalId);
        
        return proposalId;
    }

    // Initiate Consensus Tests
    function test_InitiateConsensus_Success() public {
        uint256 proposalId = _createChallengedProposal();
        uint256 expectedEndBlock = block.number + VOTING_PERIOD;
        
        vm.expectEmit(true, true, false, true);
        emit ConsensusRoundStarted(proposalId, 1, block.number, expectedEndBlock);
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        assertEq(roundId, 1);
        assertEq(consensusEngine.getCurrentRound(proposalId), roundId);
    }

    function test_InitiateConsensus_RevertIfNotInitiator() public {
        uint256 proposalId = _createChallengedProposal();
        
        vm.expectRevert(IConsensusEngine.CallerNotConsensusInitiator.selector);
        vm.prank(validator1);
        consensusEngine.initiateConsensus(proposalId);
    }

    function test_InitiateConsensus_RevertIfProposalNotChallenged() public {
        // Create proposal without challenging
        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");
        
        vm.expectRevert(IConsensusEngine.ProposalNotInChallengedState.selector);
        vm.prank(consensusInitiator);
        consensusEngine.initiateConsensus(proposalId);
    }

    function test_InitiateConsensus_RevertIfAlreadyInConsensus() public {
        uint256 proposalId = _createChallengedProposal();
        
        vm.prank(consensusInitiator);
        consensusEngine.initiateConsensus(proposalId);
        
        vm.expectRevert(IConsensusEngine.ProposalAlreadyInConsensus.selector);
        vm.prank(consensusInitiator);
        consensusEngine.initiateConsensus(proposalId);
    }

    // Cast Vote Tests
    function test_CastVote_Success() public {
        uint256 proposalId = _createChallengedProposal();
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        bytes memory signature = _createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true);
        
        vm.expectEmit(true, true, false, true);
        emit VoteCast(roundId, validator1, true);
        
        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, signature);
        
        (bool hasVoted, bool support) = consensusEngine.getVote(roundId, validator1);
        assertTrue(hasVoted);
        assertTrue(support);
        
        (uint256 votesFor, uint256 votesAgainst, uint256 totalValidators) = consensusEngine.getVoteCounts(roundId);
        assertEq(votesFor, 1);
        assertEq(votesAgainst, 0);
        assertEq(totalValidators, 3);
    }

    function test_CastVote_MultipleValidators() public {
        uint256 proposalId = _createChallengedProposal();
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        // Validator1 votes for
        bytes memory signature1 = _createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true);
        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, signature1);
        
        // Validator2 votes against
        bytes memory signature2 = _createVoteSignature(VALIDATOR2_PRIVATE_KEY, roundId, false);
        vm.prank(validator2);
        consensusEngine.castVote(roundId, false, signature2);
        
        // Validator3 votes for
        bytes memory signature3 = _createVoteSignature(VALIDATOR3_PRIVATE_KEY, roundId, true);
        vm.prank(validator3);
        consensusEngine.castVote(roundId, true, signature3);
        
        (uint256 votesFor, uint256 votesAgainst,) = consensusEngine.getVoteCounts(roundId);
        assertEq(votesFor, 2);
        assertEq(votesAgainst, 1);
    }

    function test_CastVote_RevertIfNotActiveValidator() public {
        uint256 proposalId = _createChallengedProposal();
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        bytes memory signature = _createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true);
        
        vm.expectRevert(IConsensusEngine.NotActiveValidator.selector);
        vm.prank(nonValidator);
        consensusEngine.castVote(roundId, true, signature);
    }

    function test_CastVote_RevertIfInvalidRound() public {
        bytes memory signature = _createVoteSignature(VALIDATOR1_PRIVATE_KEY, 999, true);
        
        vm.expectRevert(IConsensusEngine.RoundNotFound.selector);
        vm.prank(validator1);
        consensusEngine.castVote(999, true, signature);
    }

    function test_CastVote_RevertIfVotingEnded() public {
        uint256 proposalId = _createChallengedProposal();
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        // Move past voting period
        vm.roll(block.number + VOTING_PERIOD + 1);
        
        bytes memory signature = _createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true);
        
        vm.expectRevert(IConsensusEngine.VotingPeriodEnded.selector);
        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, signature);
    }

    function test_CastVote_RevertIfAlreadyVoted() public {
        uint256 proposalId = _createChallengedProposal();
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        bytes memory signature = _createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true);
        
        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, signature);
        
        vm.expectRevert(IConsensusEngine.AlreadyVoted.selector);
        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, signature);
    }

    function test_CastVote_RevertIfInvalidSignature() public {
        uint256 proposalId = _createChallengedProposal();
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        // Use wrong private key for signature
        bytes memory wrongSignature = _createVoteSignature(VALIDATOR2_PRIVATE_KEY, roundId, true);
        
        vm.expectRevert(IConsensusEngine.InvalidSignature.selector);
        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, wrongSignature);
    }

    function test_CastVote_RevertIfAlreadyFinalized() public {
        uint256 proposalId = _createChallengedProposal();
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        // Vote and finalize
        bytes memory signature1 = _createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true);
        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, signature1);
        
        bytes memory signature2 = _createVoteSignature(VALIDATOR2_PRIVATE_KEY, roundId, true);
        vm.prank(validator2);
        consensusEngine.castVote(roundId, true, signature2);
        
        vm.roll(block.number + VOTING_PERIOD + 1);
        consensusEngine.finalizeConsensus(roundId);
        
        // Try to vote after finalization
        bytes memory signature3 = _createVoteSignature(VALIDATOR3_PRIVATE_KEY, roundId, true);
        vm.expectRevert(IConsensusEngine.RoundAlreadyFinalized.selector);
        vm.prank(validator3);
        consensusEngine.castVote(roundId, true, signature3);
    }

    // Finalize Consensus Tests
    function test_FinalizeConsensus_Success_Approved() public {
        uint256 proposalId = _createChallengedProposal();
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        // 2 out of 3 validators vote for (67% > 60% quorum)
        bytes memory signature1 = _createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true);
        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, signature1);
        
        bytes memory signature2 = _createVoteSignature(VALIDATOR2_PRIVATE_KEY, roundId, true);
        vm.prank(validator2);
        consensusEngine.castVote(roundId, true, signature2);
        
        // Move past voting period
        vm.roll(block.number + VOTING_PERIOD + 1);
        
        vm.expectEmit(true, true, false, true);
        emit ConsensusFinalized(roundId, proposalId, true, 2, 0);
        
        bool approved = consensusEngine.finalizeConsensus(roundId);
        assertTrue(approved);
        
        // Round should no longer be finalizable
        assertFalse(consensusEngine.canFinalizeRound(roundId));
    }

    function test_FinalizeConsensus_Success_NotApproved() public {
        uint256 proposalId = _createChallengedProposal();
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        // Only 1 out of 3 validators vote (33% < 60% quorum)
        bytes memory signature1 = _createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true);
        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, signature1);
        
        // Move past voting period
        vm.roll(block.number + VOTING_PERIOD + 1);
        
        vm.expectEmit(true, true, false, true);
        emit ConsensusFinalized(roundId, proposalId, false, 1, 0);
        
        bool approved = consensusEngine.finalizeConsensus(roundId);
        assertFalse(approved);
    }

    function test_FinalizeConsensus_RevertIfVotingActive() public {
        uint256 proposalId = _createChallengedProposal();
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        vm.expectRevert(IConsensusEngine.VotingPeriodActive.selector);
        consensusEngine.finalizeConsensus(roundId);
    }

    function test_FinalizeConsensus_RevertIfAlreadyFinalized() public {
        uint256 proposalId = _createChallengedProposal();
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        vm.roll(block.number + VOTING_PERIOD + 1);
        consensusEngine.finalizeConsensus(roundId);
        
        vm.expectRevert(IConsensusEngine.RoundAlreadyFinalized.selector);
        consensusEngine.finalizeConsensus(roundId);
    }

    // Admin Tests
    function test_SetConsensusInitiator_Success() public {
        address newInitiator = address(0x888);
        
        consensusEngine.setConsensusInitiator(newInitiator);
        
        assertEq(consensusEngine.consensusInitiator(), newInitiator);
    }

    function test_SetConsensusInitiator_RevertIfUnauthorized() public {
        vm.expectRevert();
        vm.prank(validator1);
        consensusEngine.setConsensusInitiator(address(0x888));
    }

    function test_SetConsensusInitiator_RevertIfZeroAddress() public {
        vm.expectRevert(IConsensusEngine.ZeroAddress.selector);
        consensusEngine.setConsensusInitiator(address(0));
    }

    // View Functions Tests
    function test_GetCurrentRound() public {
        uint256 proposalId = _createChallengedProposal();
        
        assertEq(consensusEngine.getCurrentRound(proposalId), 0);
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        assertEq(consensusEngine.getCurrentRound(proposalId), roundId);
    }

    function test_GetVote() public {
        uint256 proposalId = _createChallengedProposal();
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        (bool hasVoted, bool support) = consensusEngine.getVote(roundId, validator1);
        assertFalse(hasVoted);
        assertFalse(support);
        
        bytes memory signature = _createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true);
        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, signature);
        
        (hasVoted, support) = consensusEngine.getVote(roundId, validator1);
        assertTrue(hasVoted);
        assertTrue(support);
    }

    function test_GetVoteCounts() public {
        uint256 proposalId = _createChallengedProposal();
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        (uint256 votesFor, uint256 votesAgainst, uint256 totalValidators) = consensusEngine.getVoteCounts(roundId);
        assertEq(votesFor, 0);
        assertEq(votesAgainst, 0);
        assertEq(totalValidators, 3);
        
        // Cast some votes
        bytes memory signature1 = _createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true);
        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, signature1);
        
        bytes memory signature2 = _createVoteSignature(VALIDATOR2_PRIVATE_KEY, roundId, false);
        vm.prank(validator2);
        consensusEngine.castVote(roundId, false, signature2);
        
        (votesFor, votesAgainst, totalValidators) = consensusEngine.getVoteCounts(roundId);
        assertEq(votesFor, 1);
        assertEq(votesAgainst, 1);
        assertEq(totalValidators, 3);
    }

    function test_CanFinalizeRound() public {
        uint256 proposalId = _createChallengedProposal();
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        // Should not be finalizable during voting period
        assertFalse(consensusEngine.canFinalizeRound(roundId));
        
        // Move past voting period
        vm.roll(block.number + VOTING_PERIOD + 1);
        assertTrue(consensusEngine.canFinalizeRound(roundId));
        
        // After finalization
        consensusEngine.finalizeConsensus(roundId);
        assertFalse(consensusEngine.canFinalizeRound(roundId));
    }

    function test_VerifyVoteSignature() public {
        uint256 proposalId = _createChallengedProposal();
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        bytes memory signature = _createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true);
        
        // Should verify correctly
        assertTrue(consensusEngine.verifyVoteSignature(roundId, validator1, true, signature));
        
        // Should fail with wrong validator
        assertFalse(consensusEngine.verifyVoteSignature(roundId, validator2, true, signature));
        
        // Should fail with wrong vote
        assertFalse(consensusEngine.verifyVoteSignature(roundId, validator1, false, signature));
    }

    function test_GetVotingPeriod() public view {
        assertEq(consensusEngine.getVotingPeriod(), VOTING_PERIOD);
    }

    function test_GetQuorumPercentage() public view {
        assertEq(consensusEngine.getQuorumPercentage(), QUORUM_PERCENTAGE);
    }

    // Edge Cases
    function test_ConsensusRound_ExactQuorum() public {
        uint256 proposalId = _createChallengedProposal();
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        // Exactly 67% vote for (2/3 validators, > 60% quorum)
        bytes memory signature1 = _createVoteSignature(VALIDATOR1_PRIVATE_KEY, roundId, true);
        vm.prank(validator1);
        consensusEngine.castVote(roundId, true, signature1);
        
        bytes memory signature2 = _createVoteSignature(VALIDATOR2_PRIVATE_KEY, roundId, true);
        vm.prank(validator2);
        consensusEngine.castVote(roundId, true, signature2);
        
        // Third validator votes against
        bytes memory signature3 = _createVoteSignature(VALIDATOR3_PRIVATE_KEY, roundId, false);
        vm.prank(validator3);
        consensusEngine.castVote(roundId, false, signature3);
        
        vm.roll(block.number + VOTING_PERIOD + 1);
        bool approved = consensusEngine.finalizeConsensus(roundId);
        assertTrue(approved);
    }

    // Fuzz Tests
    function testFuzz_VotingScenarios(uint8 votesFor, uint8 votesAgainst) public {
        vm.assume(votesFor <= 3 && votesAgainst <= 3);
        vm.assume(votesFor + votesAgainst <= 3);
        
        uint256 proposalId = _createChallengedProposal();
        
        vm.prank(consensusInitiator);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        uint256 validatorIndex = 0;
        uint256[3] memory privateKeys = [VALIDATOR1_PRIVATE_KEY, VALIDATOR2_PRIVATE_KEY, VALIDATOR3_PRIVATE_KEY];
        address[3] memory validators = [validator1, validator2, validator3];
        
        // Cast "for" votes
        for (uint256 i = 0; i < votesFor; i++) {
            bytes memory signature = _createVoteSignature(privateKeys[validatorIndex], roundId, true);
            vm.prank(validators[validatorIndex]);
            consensusEngine.castVote(roundId, true, signature);
            validatorIndex++;
        }
        
        // Cast "against" votes
        for (uint256 i = 0; i < votesAgainst; i++) {
            bytes memory signature = _createVoteSignature(privateKeys[validatorIndex], roundId, false);
            vm.prank(validators[validatorIndex]);
            consensusEngine.castVote(roundId, false, signature);
            validatorIndex++;
        }
        
        (uint256 roundVotesFor, uint256 roundVotesAgainst,) = consensusEngine.getVoteCounts(roundId);
        assertEq(roundVotesFor, votesFor);
        assertEq(roundVotesAgainst, votesAgainst);
        
        // Move past voting period and finalize
        vm.roll(block.number + VOTING_PERIOD + 1);
        bool approved = consensusEngine.finalizeConsensus(roundId);
        
        // Check if quorum is met (60% of 3 validators = 1.8, so 2 votes needed)
        bool expectedApproval = (votesFor + votesAgainst) >= 2 && votesFor > votesAgainst;
        assertEq(approved, expectedApproval);
    }
}