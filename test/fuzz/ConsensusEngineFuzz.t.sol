// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IConsensusEngine } from "../../src/interfaces/IConsensusEngine.sol";
import { IProposalManager } from "../../src/interfaces/IProposalManager.sol";
import { IValidatorRegistry } from "../../src/interfaces/IValidatorRegistry.sol";
import { GLTToken } from "../../src/GLTToken.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { ProposalManager } from "../../src/ProposalManager.sol";
import { MockLLMOracle } from "../../src/MockLLMOracle.sol";
import { ConsensusEngine } from "../../src/ConsensusEngine.sol";

/**
 * @title ConsensusEngineFuzzTest
 * @dev Fuzz tests for ConsensusEngine contract
 */
contract ConsensusEngineFuzzTest is Test {
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    uint256 public constant MINIMUM_STAKE = 1000e18;
    uint256 public constant VOTING_PERIOD = 100;
    uint256 public constant QUORUM_PERCENTAGE = 60;

    GLTToken public gltToken;
    ValidatorRegistry public validatorRegistry;
    ProposalManager public proposalManager;
    MockLLMOracle public llmOracle;
    ConsensusEngine public consensusEngine;
    address public owner = address(this);
    address public proposalManagerRole = address(0x1000);
    address public consensusInitiatorRole = address(0x2000);

    function setUp() public {
        gltToken = new GLTToken(owner);
        validatorRegistry = new ValidatorRegistry(address(gltToken), owner, 5);
        llmOracle = new MockLLMOracle();
        proposalManager = new ProposalManager(address(validatorRegistry), address(llmOracle), proposalManagerRole);
        consensusEngine =
            new ConsensusEngine(address(validatorRegistry), address(proposalManager), consensusInitiatorRole);
    }

    function _setupValidator(uint256 privateKey, uint256 stake) internal returns (address) {
        address validator = vm.addr(privateKey);
        gltToken.mint(validator, stake);
        vm.prank(validator);
        gltToken.approve(address(validatorRegistry), stake);
        vm.prank(validator);
        validatorRegistry.registerValidator(stake);
        return validator;
    }

    function _createVoteSignature(
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

    function testFuzz_VotingWithValidatorCounts(uint8 validatorCount, uint8 votingCount) public {
        uint256 activeLimit = validatorRegistry.activeValidatorLimit();
        validatorCount = uint8(bound(validatorCount, 3, activeLimit));
        votingCount = uint8(bound(votingCount, 0, validatorCount));

        uint256[] memory privateKeys = new uint256[](validatorCount);
        address[] memory validators = new address[](validatorCount);

        for (uint256 i = 0; i < validatorCount; ++i) {
            privateKeys[i] = 0x1000 + i;
            validators[i] = _setupValidator(privateKeys[i], MINIMUM_STAKE + ((validatorCount - i) * 100e18));
        }

        address[] memory activeValidators = validatorRegistry.getActiveValidators();
        require(activeValidators.length >= 2, "Need at least 2 active validators");

        vm.prank(activeValidators[0]);
        uint256 proposalId = proposalManager.createProposal(keccak256("test"), "Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.prank(activeValidators[1]);
        proposalManager.challengeProposal(proposalId);

        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);

        uint256 votesFor = 0;
        uint256 votesAgainst = 0;

        for (uint256 i = 0; i < votingCount && i < activeValidators.length; ++i) {
            bool support = i % 2 == 0;
            if (support) {
                ++votesFor;
            } else {
                ++votesAgainst;
            }

            uint256 privateKey = 0;
            for (uint256 j = 0; j < validators.length; ++j) {
                if (validators[j] == activeValidators[i]) {
                    privateKey = privateKeys[j];
                    break;
                }
            }
            require(privateKey != 0, "Private key not found");

            vm.prank(activeValidators[i]);
            consensusEngine.castVote(roundId, support, _createVoteSignature(privateKey, roundId, support));
        }

        (uint256 actualFor, uint256 actualAgainst, uint256 totalValidators) = consensusEngine.getVoteCounts(roundId);
        assertEq(actualFor, votesFor);
        assertEq(actualAgainst, votesAgainst);
        assertEq(totalValidators, validatorCount);
    }

    function testFuzz_VoteTiming(uint256 blockDelay) public {
        blockDelay = bound(blockDelay, 0, 999);
        address validator1 = _setupValidator(0x1111, 2000e18);
        address validator2 = _setupValidator(0x2222, 1500e18);

        vm.prank(validator1);
        uint256 proposalId = proposalManager.createProposal(keccak256("timing"), "Timing Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.prank(validator2);
        proposalManager.challengeProposal(proposalId);

        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);

        vm.roll(block.number + blockDelay);

        if (blockDelay <= VOTING_PERIOD) {
            vm.prank(validator1);
            consensusEngine.castVote(roundId, true, _createVoteSignature(0x1111, roundId, true));

            (bool hasVoted, bool support) = consensusEngine.getVote(roundId, validator1);
            assertTrue(hasVoted);
            assertTrue(support);
        } else {
            vm.expectRevert(IConsensusEngine.VotingPeriodEnded.selector);
            vm.prank(validator1);
            consensusEngine.castVote(roundId, true, _createVoteSignature(0x1111, roundId, true));
        }
    }

    function testFuzz_RandomVotingPatterns(uint256 seed) public {
        uint256 activeLimit = validatorRegistry.activeValidatorLimit();
        uint256 validatorCount = activeLimit;
        uint256[] memory privateKeys = new uint256[](validatorCount);
        address[] memory validators = new address[](validatorCount);

        for (uint256 i = 0; i < validatorCount; ++i) {
            privateKeys[i] = 0x3000 + i;
            validators[i] = _setupValidator(privateKeys[i], MINIMUM_STAKE + ((validatorCount - i) * 200e18));
        }

        address[] memory activeValidators = validatorRegistry.getActiveValidators();
        require(activeValidators.length == validatorCount, "All validators should be active");

        vm.prank(activeValidators[0]);
        uint256 proposalId = proposalManager.createProposal(keccak256("pattern"), "Pattern Test");

        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);

        vm.prank(activeValidators[1]);
        proposalManager.challengeProposal(proposalId);

        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);

        uint256 votesFor = 0;
        uint256 votesAgainst = 0;

        for (uint256 i = 0; i < validatorCount; ++i) {
            if ((seed >> i) & 1 == 1) {
                bool support = ((seed >> (i + 10)) & 1) == 1;

                uint256 privateKey = 0;
                for (uint256 j = 0; j < validators.length; ++j) {
                    if (validators[j] == activeValidators[i]) {
                        privateKey = privateKeys[j];
                        break;
                    }
                }
                require(privateKey != 0, "Private key not found");

                vm.prank(activeValidators[i]);
                consensusEngine.castVote(roundId, support, _createVoteSignature(privateKey, roundId, support));

                if (support) {
                    ++votesFor;
                } else {
                    ++votesAgainst;
                }
            }
        }

        (uint256 actualFor, uint256 actualAgainst,) = consensusEngine.getVoteCounts(roundId);
        assertEq(actualFor, votesFor);
        assertEq(actualAgainst, votesAgainst);
    }

    function testFuzz_SignatureValidation(
        uint256 validatorKey,
        uint256 signerKey,
        uint256 roundId,
        bool support
    )
        public
        view
    {
        validatorKey = bound(validatorKey, 1, type(uint256).max / 2);
        signerKey = bound(signerKey, 1, type(uint256).max / 2);
        roundId = bound(roundId, 1, 999_999);

        address validator = vm.addr(validatorKey);
        address signer = vm.addr(signerKey);

        bytes memory signature = _createVoteSignature(signerKey, roundId, support);

        bool isValid = consensusEngine.verifyVoteSignature(roundId, signer, support, signature);
        assertTrue(isValid);

        if (validator != signer) {
            isValid = consensusEngine.verifyVoteSignature(roundId, validator, support, signature);
            assertFalse(isValid);
        }

        isValid = consensusEngine.verifyVoteSignature(roundId + 1, signer, support, signature);
        assertFalse(isValid);

        isValid = consensusEngine.verifyVoteSignature(roundId, signer, !support, signature);
        assertFalse(isValid);
    }
}
