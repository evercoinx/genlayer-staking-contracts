// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IDisputeResolver } from "../../src/interfaces/IDisputeResolver.sol";
import { IProposalManager } from "../../src/interfaces/IProposalManager.sol";
import { IValidatorRegistry } from "../../src/interfaces/IValidatorRegistry.sol";
import { GLTToken } from "../../src/GLTToken.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { ProposalManager } from "../../src/ProposalManager.sol";
import { MockLLMOracle } from "../../src/MockLLMOracle.sol";
import { DisputeResolver } from "../../src/DisputeResolver.sol";

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
        validatorRegistry = new ValidatorRegistry(address(gltToken), owner, 5);
        llmOracle = new MockLLMOracle();
        proposalManager = new ProposalManager(address(validatorRegistry), address(llmOracle), proposalManagerRole);
        disputeResolver = new DisputeResolver(address(gltToken), address(validatorRegistry), address(proposalManager));

        validatorRegistry.setSlasher(address(disputeResolver));
    }

    function _setupValidator(uint256 privateKey, uint256 stake) internal returns (address) {
        address validator = vm.addr(privateKey);
        gltToken.mint(validator, stake + 10_000e18);
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

    function testFuzz_CreateDisputeWithStakes(uint256 challengeStake) public {
        challengeStake = bound(challengeStake, MINIMUM_CHALLENGE_STAKE, 5000e18);
        address proposer = _setupValidator(0x1111, 2000e18);
        address challenger = _setupValidator(0x2222, 1500e18);
        vm.prank(proposer);
        uint256 proposalId = proposalManager.createProposal(keccak256("dispute"), "Dispute Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        uint256 balanceBefore = gltToken.balanceOf(challenger);

        vm.prank(challenger);
        uint256 disputeId = disputeResolver.createDispute(proposalId, challengeStake);

        uint256 balanceAfter = gltToken.balanceOf(challenger);
        assertEq(balanceBefore - balanceAfter, challengeStake);

        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertEq(dispute.challengeStake, challengeStake);
        assertEq(dispute.challenger, challenger);
    }

    function testFuzz_VotingPatterns(uint8 totalValidators, uint8 votingValidators, uint256 votingPattern) public {
        uint256 activeLimit = validatorRegistry.activeValidatorLimit();
        totalValidators = uint8(bound(totalValidators, 3, activeLimit));
        votingValidators = uint8(bound(votingValidators, 1, totalValidators));
        uint256[] memory privateKeys = new uint256[](totalValidators);
        address[] memory validators = new address[](totalValidators);

        for (uint256 i = 0; i < totalValidators; ++i) {
            privateKeys[i] = 0x3000 + i;
            validators[i] = _setupValidator(privateKeys[i], MINIMUM_STAKE + ((totalValidators - i) * 100e18));
        }
        address[] memory activeValidators = validatorRegistry.getActiveValidators();
        require(activeValidators.length >= 2, "Need at least 2 active validators");
        vm.prank(activeValidators[0]);
        uint256 proposalId = proposalManager.createProposal(keccak256("pattern"), "Pattern Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.prank(activeValidators[1]);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 200e18);
        uint256 votesFor = 0;
        uint256 votesAgainst = 0;
        uint256 activeValidatorsLength = activeValidators.length;

        for (uint256 i = 2; i < 2 + votingValidators && i < activeValidatorsLength; ++i) {
            bool supportChallenge = ((votingPattern >> (i - 2)) & 1) == 1;
            uint256 privateKey = 0;
            for (uint256 j = 0; j < validators.length; ++j) {
                if (validators[j] == activeValidators[i]) {
                    privateKey = privateKeys[j];
                    break;
                }
            }
            require(privateKey != 0, "Private key not found");

            vm.prank(activeValidators[i]);
            disputeResolver.voteOnDispute(
                disputeId, supportChallenge, _createDisputeVoteSignature(privateKey, disputeId, supportChallenge)
            );

            if (supportChallenge) {
                ++votesFor;
            } else {
                ++votesAgainst;
            }
        }
        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        assertEq(dispute.votesFor, votesFor);
        assertEq(dispute.votesAgainst, votesAgainst);
    }

    function testFuzz_SlashCalculations(uint256 proposerStake, uint256 challengeStake) public {
        proposerStake = bound(proposerStake, MINIMUM_STAKE, 20_000e18);
        challengeStake = bound(challengeStake, MINIMUM_CHALLENGE_STAKE, 2000e18);
        address proposer = _setupValidator(0x4444, proposerStake);
        address challenger = _setupValidator(0x5555, 2000e18);
        address voter1 = _setupValidator(0x6666, 1500e18);
        address voter2 = _setupValidator(0x7777, 1200e18);
        vm.prank(proposer);
        uint256 proposalId = proposalManager.createProposal(keccak256("slash"), "Slash Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.prank(challenger);
        uint256 disputeId = disputeResolver.createDispute(proposalId, challengeStake);
        vm.prank(voter1);
        disputeResolver.voteOnDispute(disputeId, true, _createDisputeVoteSignature(0x6666, disputeId, true));

        vm.prank(voter2);
        disputeResolver.voteOnDispute(disputeId, true, _createDisputeVoteSignature(0x7777, disputeId, true));
        uint256 proposerStakeBefore = validatorRegistry.getValidatorInfo(proposer).stakedAmount;
        uint256 challengerBalanceBefore = gltToken.balanceOf(challenger);
        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);
        disputeResolver.resolveDispute(disputeId);
        uint256 disputeSlash = (challengeStake * SLASH_PERCENTAGE) / 100;
        uint256 maxSlash = (proposerStakeBefore * SLASH_PERCENTAGE) / 100;
        uint256 actualSlash = disputeSlash < maxSlash ? disputeSlash : maxSlash;
        uint256 proposerStakeAfter = validatorRegistry.getValidatorInfo(proposer).stakedAmount;
        assertEq(proposerStakeBefore - proposerStakeAfter, actualSlash);
        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        uint256 storedSlash = disputeSlash > proposerStakeBefore ? proposerStakeBefore : disputeSlash;
        assertEq(dispute.slashAmount, storedSlash);
        assertEq(gltToken.balanceOf(challenger), challengerBalanceBefore + challengeStake);
    }

    function testFuzz_MultipleDisputes(uint8 disputeCount, uint256 seed) public {
        disputeCount = uint8(bound(disputeCount, 1, 3));
        address proposer = _setupValidator(0x7777, 5000e18);
        vm.prank(proposer);
        uint256 proposalId = proposalManager.createProposal(keccak256("multi"), "Multi Dispute");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        uint256[] memory disputeIds = new uint256[](disputeCount);
        for (uint256 i = 0; i < disputeCount; ++i) {
            address challenger = _setupValidator(0x8000 + i, 2000e18);
            uint256 stake = bound((seed >> (i * 8)) & 0xFF, MINIMUM_CHALLENGE_STAKE, 500e18);

            vm.prank(challenger);
            disputeIds[i] = disputeResolver.createDispute(proposalId, stake);
        }
        uint256[] memory proposalDisputes = disputeResolver.getDisputesByProposal(proposalId);
        assertEq(proposalDisputes.length, disputeCount);
        assertEq(disputeResolver.totalDisputes(), disputeCount);
    }

    function testFuzz_TimingScenarios(uint256 voteTime, uint256 resolveTime) public {
        voteTime = bound(voteTime, 0, 100);
        resolveTime = bound(resolveTime, 0, 100);
        address proposer = _setupValidator(0x9999, 2000e18);
        address challenger = _setupValidator(0xAAAA, 1500e18);
        address voter = _setupValidator(0xBBBB, 1000e18);
        vm.prank(proposer);
        uint256 proposalId = proposalManager.createProposal(keccak256("timing"), "Timing Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.prank(challenger);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 150e18);
        vm.warp(block.timestamp + voteTime);

        if (voteTime <= DISPUTE_VOTING_PERIOD) {
            vm.prank(voter);
            disputeResolver.voteOnDispute(disputeId, true, _createDisputeVoteSignature(0xBBBB, disputeId, true));
            IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
            assertEq(dispute.votesFor, 1);
        } else {
            vm.expectRevert(IDisputeResolver.DisputeVotingEnded.selector);
            vm.prank(voter);
            disputeResolver.voteOnDispute(disputeId, true, _createDisputeVoteSignature(0xBBBB, disputeId, true));
        }
        vm.warp(block.timestamp + resolveTime);

        if (block.timestamp > disputeResolver.getDispute(disputeId).votingEndTime) {
            disputeResolver.resolveDispute(disputeId);

            IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
            assertEq(uint8(dispute.state), uint8(IDisputeResolver.DisputeState.Resolved));
        } else {
            vm.expectRevert(IDisputeResolver.DisputeVotingActive.selector);
            disputeResolver.resolveDispute(disputeId);
        }
    }

    function testFuzz_DisputeOutcomes(uint256 proposerStake, uint256 challengeStake, bool supportChallenge) public {
        proposerStake = bound(proposerStake, MINIMUM_STAKE, 10_000e18);
        challengeStake = bound(challengeStake, MINIMUM_CHALLENGE_STAKE, 1000e18);
        address proposer = _setupValidator(0xCCCC, proposerStake);
        address challenger = _setupValidator(0xDDDD, challengeStake + 1000e18);
        address voter1 = _setupValidator(0xEEEE, 1500e18);
        vm.prank(proposer);
        uint256 proposalId = proposalManager.createProposal(keccak256("outcome"), "Outcome Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.prank(challenger);
        uint256 disputeId = disputeResolver.createDispute(proposalId, challengeStake);
        vm.prank(voter1);
        disputeResolver.voteOnDispute(
            disputeId, supportChallenge, _createDisputeVoteSignature(0xEEEE, disputeId, supportChallenge)
        );

        if (supportChallenge) {
            vm.prank(proposer);
            disputeResolver.voteOnDispute(disputeId, true, _createDisputeVoteSignature(0xCCCC, disputeId, true));
        }
        uint256 proposerStakeBefore = validatorRegistry.getValidatorInfo(proposer).stakedAmount;
        uint256 challengerBalanceBefore = gltToken.balanceOf(challenger);
        vm.warp(block.timestamp + DISPUTE_VOTING_PERIOD + 1);
        disputeResolver.resolveDispute(disputeId);
        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);
        uint256 slashPercent = (challengeStake * SLASH_PERCENTAGE) / 100;
        uint256 maxSlash = (proposerStakeBefore * SLASH_PERCENTAGE) / 100;
        uint256 expectedSlash = slashPercent < maxSlash ? slashPercent : maxSlash;

        if (supportChallenge) {
            assertTrue(dispute.challengerWon);
            uint256 proposerStakeAfter = validatorRegistry.getValidatorInfo(proposer).stakedAmount;
            assertEq(proposerStakeAfter, proposerStakeBefore - expectedSlash);
            assertEq(gltToken.balanceOf(challenger), challengerBalanceBefore + challengeStake);
        } else {
            assertFalse(dispute.challengerWon);
            uint256 proposerStakeAfter = validatorRegistry.getValidatorInfo(proposer).stakedAmount;
            assertEq(proposerStakeAfter, proposerStakeBefore);
            assertEq(gltToken.balanceOf(challenger), challengerBalanceBefore);
        }
    }
}
