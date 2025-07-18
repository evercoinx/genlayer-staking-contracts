// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { GLTToken } from "../../src/GLTToken.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { ProposalManager } from "../../src/ProposalManager.sol";
import { MockLLMOracle } from "../../src/MockLLMOracle.sol";
import { DisputeResolver } from "../../src/DisputeResolver.sol";
import { IDisputeResolver } from "../../src/interfaces/IDisputeResolver.sol";
import { IProposalManager } from "../../src/interfaces/IProposalManager.sol";
import { IValidatorRegistry } from "../../src/interfaces/IValidatorRegistry.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title DisputeResolverFuzzTest
 * @dev Fuzz tests for DisputeResolver contract
 */
contract DisputeResolverFuzzTest is Test {
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    GLTToken public gltToken;
    ValidatorRegistry public validatorRegistry;
    ProposalManager public proposalManager;
    MockLLMOracle public llmOracle;
    DisputeResolver public disputeResolver;
    
    address public owner = address(this);
    address public proposalManagerRole = address(0x1000);
    
    uint256 constant MINIMUM_STAKE = 1000e18;
    uint256 constant MINIMUM_CHALLENGE_STAKE = 100e18;
    uint256 constant DISPUTE_VOTING_PERIOD = 50;
    uint256 constant SLASH_PERCENTAGE = 10;

    function setUp() public {
        gltToken = new GLTToken(owner);
        validatorRegistry = new ValidatorRegistry(address(gltToken), owner);
        llmOracle = new MockLLMOracle();
        proposalManager = new ProposalManager(
            address(validatorRegistry),
            address(llmOracle),
            proposalManagerRole
        );
        disputeResolver = new DisputeResolver(
            address(gltToken),
            address(validatorRegistry),
            address(proposalManager)
        );
        
        validatorRegistry.setSlasher(address(disputeResolver));
    }

    function _setupValidator(uint256 privateKey, uint256 stake) internal returns (address) {
        address validator = vm.addr(privateKey);
        gltToken.mint(validator, stake + 5000e18); // Extra for disputes
        vm.prank(validator);
        gltToken.approve(address(validatorRegistry), stake);
        vm.prank(validator);
        validatorRegistry.registerValidator(stake);
        vm.prank(validator);
        gltToken.approve(address(disputeResolver), type(uint256).max);
        return validator;
    }

    function _createDisputeVoteSignature(
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

    // Fuzz test: Create disputes with various stake amounts
    function testFuzz_CreateDisputeWithStakes(uint256 challengeStake) public {
        // Constraints
        vm.assume(challengeStake >= MINIMUM_CHALLENGE_STAKE);
        vm.assume(challengeStake <= 10000e18);
        
        // Setup validators
        address proposer = _setupValidator(0x1111, 2000e18);
        address challenger = _setupValidator(0x2222, 1500e18);
        
        // Create proposal
        vm.prank(proposer);
        uint256 proposalId = proposalManager.createProposal(keccak256("dispute"), "Dispute Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        // Create dispute
        uint256 balanceBefore = gltToken.balanceOf(challenger);
        
        vm.prank(challenger);
        uint256 disputeId = disputeResolver.createDispute(proposalId, challengeStake);
        
        uint256 balanceAfter = gltToken.balanceOf(challenger);
        assertEq(balanceBefore - balanceAfter, challengeStake);
        
        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertEq(dispute.challengeStake, challengeStake);
        assertEq(dispute.challenger, challenger);
    }

    // Fuzz test: Voting patterns with different validator counts
    function testFuzz_VotingPatterns(
        uint8 totalValidators,
        uint8 votingValidators,
        uint256 votingPattern
    ) public {
        // Constraints
        vm.assume(totalValidators >= 3 && totalValidators <= 20);
        vm.assume(votingValidators <= totalValidators);
        
        // Setup validators
        uint256[] memory privateKeys = new uint256[](totalValidators);
        address[] memory validators = new address[](totalValidators);
        
        for (uint256 i = 0; i < totalValidators; i++) {
            privateKeys[i] = 0x3000 + i;
            validators[i] = _setupValidator(privateKeys[i], MINIMUM_STAKE + (i * 100e18));
        }
        
        // Create proposal and dispute
        vm.prank(validators[0]);
        uint256 proposalId = proposalManager.createProposal(keccak256("pattern"), "Pattern Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        vm.prank(validators[1]);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 200e18);
        
        // Vote based on pattern
        uint256 votesFor = 0;
        uint256 votesAgainst = 0;
        
        for (uint256 i = 2; i < 2 + votingValidators && i < totalValidators; i++) {
            bool supportChallenge = ((votingPattern >> (i - 2)) & 1) == 1;
            
            vm.prank(validators[i]);
            disputeResolver.voteOnDispute(
                disputeId,
                supportChallenge,
                _createDisputeVoteSignature(privateKeys[i], disputeId, supportChallenge)
            );
            
            if (supportChallenge) votesFor++;
            else votesAgainst++;
        }
        
        // Check vote counts
        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertEq(dispute.votesFor, votesFor);
        assertEq(dispute.votesAgainst, votesAgainst);
    }

    // Fuzz test: Slash calculations
    function testFuzz_SlashCalculations(uint256 proposerStake, uint256 challengeStake) public {
        // Constraints
        vm.assume(proposerStake >= MINIMUM_STAKE && proposerStake <= 100000e18);
        vm.assume(challengeStake >= MINIMUM_CHALLENGE_STAKE && challengeStake <= 10000e18);
        
        // Setup validators
        address proposer = _setupValidator(0x4444, proposerStake);
        address challenger = _setupValidator(0x5555, 2000e18);
        address voter = _setupValidator(0x6666, 1500e18);
        
        // Create proposal and dispute
        vm.prank(proposer);
        uint256 proposalId = proposalManager.createProposal(keccak256("slash"), "Slash Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        vm.prank(challenger);
        uint256 disputeId = disputeResolver.createDispute(proposalId, challengeStake);
        
        // Vote for challenger
        vm.prank(voter);
        disputeResolver.voteOnDispute(
            disputeId,
            true,
            _createDisputeVoteSignature(0x6666, disputeId, true)
        );
        
        // Record balances before resolution
        uint256 proposerStakeBefore = validatorRegistry.getValidatorInfo(proposer).stakedAmount;
        uint256 challengerBalanceBefore = gltToken.balanceOf(challenger);
        
        // Resolve dispute
        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);
        disputeResolver.resolveDispute(disputeId);
        
        // Check slash amount
        uint256 expectedSlash = (challengeStake * SLASH_PERCENTAGE) / 100;
        uint256 proposerStakeAfter = validatorRegistry.getValidatorInfo(proposer).stakedAmount;
        
        if (proposerStakeBefore >= expectedSlash) {
            assertEq(proposerStakeBefore - proposerStakeAfter, expectedSlash);
        } else {
            // Slashed entire remaining stake
            assertEq(proposerStakeAfter, 0);
        }
        
        // Check challenger refund
        assertEq(gltToken.balanceOf(challenger), challengerBalanceBefore + challengeStake);
    }

    // Fuzz test: Multiple disputes on same proposal
    function testFuzz_MultipleDisputes(uint8 disputeCount, uint256 seed) public {
        // Constraints
        vm.assume(disputeCount >= 1 && disputeCount <= 10);
        
        // Setup validators
        address proposer = _setupValidator(0x7777, 5000e18);
        
        // Create proposal
        vm.prank(proposer);
        uint256 proposalId = proposalManager.createProposal(keccak256("multi"), "Multi Dispute");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        uint256[] memory disputeIds = new uint256[](disputeCount);
        
        // Create multiple disputes
        for (uint256 i = 0; i < disputeCount; i++) {
            address challenger = _setupValidator(0x8000 + i, 2000e18);
            uint256 stake = MINIMUM_CHALLENGE_STAKE + ((seed >> (i * 8)) & 0xFF) * 1e18;
            
            vm.prank(challenger);
            disputeIds[i] = disputeResolver.createDispute(proposalId, stake);
        }
        
        // Check disputes array
        uint256[] memory proposalDisputes = disputeResolver.getDisputesByProposal(proposalId);
        assertEq(proposalDisputes.length, disputeCount);
        assertEq(disputeResolver.getTotalDisputes(), disputeCount);
    }

    // Fuzz test: Time-based voting scenarios
    function testFuzz_TimingScenarios(uint256 voteTime, uint256 resolveTime) public {
        // Constraints
        vm.assume(voteTime <= 200);
        vm.assume(resolveTime <= 200);
        
        // Setup
        address proposer = _setupValidator(0x9999, 2000e18);
        address challenger = _setupValidator(0xAAAA, 1500e18);
        address voter = _setupValidator(0xBBBB, 1000e18);
        
        // Create proposal and dispute
        vm.prank(proposer);
        uint256 proposalId = proposalManager.createProposal(keccak256("timing"), "Timing Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        vm.prank(challenger);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 150e18);
        
        // Try to vote at voteTime
        vm.warp(block.timestamp + voteTime);
        
        if (voteTime <= DISPUTE_VOTING_PERIOD) {
            // Should be able to vote
            vm.prank(voter);
            disputeResolver.voteOnDispute(
                disputeId,
                true,
                _createDisputeVoteSignature(0xBBBB, disputeId, true)
            );
            
            // Verify vote was recorded
            IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
            assertEq(dispute.votesFor, 1);
        } else {
            // Voting period ended
            vm.expectRevert(IDisputeResolver.DisputeVotingEnded.selector);
            vm.prank(voter);
            disputeResolver.voteOnDispute(
                disputeId,
                true,
                _createDisputeVoteSignature(0xBBBB, disputeId, true)
            );
        }
        
        // Try to resolve at resolveTime
        vm.warp(block.timestamp + resolveTime);
        
        if (block.timestamp > disputeResolver.getDispute(disputeId).votingEndTime) {
            // Should be able to resolve
            disputeResolver.resolveDispute(disputeId);
            
            IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
            assertEq(uint8(dispute.state), uint8(IDisputeResolver.DisputeState.Resolved));
        } else {
            // Too early to resolve
            vm.expectRevert(IDisputeResolver.DisputeVotingActive.selector);
            disputeResolver.resolveDispute(disputeId);
        }
    }

    // Fuzz test: Edge case stake amounts
    function testFuzz_EdgeCaseStakes(
        uint256 proposerStake,
        uint256 challengeStake,
        bool supportChallenge
    ) public {
        // Test with edge case amounts
        vm.assume(proposerStake >= MINIMUM_STAKE || proposerStake == 0);
        vm.assume(proposerStake <= type(uint256).max / 2);
        vm.assume(challengeStake >= MINIMUM_CHALLENGE_STAKE);
        vm.assume(challengeStake <= proposerStake || proposerStake < MINIMUM_STAKE);
        
        if (proposerStake < MINIMUM_STAKE) return; // Skip invalid setup
        
        // Setup
        address proposer = _setupValidator(0xCCCC, proposerStake);
        address challenger = _setupValidator(0xDDDD, challengeStake + 1000e18);
        address voter = _setupValidator(0xEEEE, 1500e18);
        
        // Create proposal and dispute
        vm.prank(proposer);
        uint256 proposalId = proposalManager.createProposal(keccak256("edge"), "Edge Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        vm.prank(challenger);
        uint256 disputeId = disputeResolver.createDispute(proposalId, challengeStake);
        
        // Vote
        vm.prank(voter);
        disputeResolver.voteOnDispute(
            disputeId,
            supportChallenge,
            _createDisputeVoteSignature(0xEEEE, disputeId, supportChallenge)
        );
        
        // Resolve
        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);
        disputeResolver.resolveDispute(disputeId);
        
        // Check results based on outcome
        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        if (supportChallenge) {
            assertTrue(dispute.challengerWon);
            // Check proposer was slashed appropriately
            uint256 expectedSlash = (challengeStake * SLASH_PERCENTAGE) / 100;
            IValidatorRegistry.ValidatorInfo memory info = validatorRegistry.getValidatorInfo(proposer);
            if (proposerStake >= expectedSlash) {
                assertEq(info.stakedAmount, proposerStake - expectedSlash);
            } else {
                assertEq(info.stakedAmount, 0);
            }
        } else {
            assertFalse(dispute.challengerWon);
        }
    }
}