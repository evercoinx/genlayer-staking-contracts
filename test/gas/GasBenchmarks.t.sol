// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { console2 } from "@forge-std/console2.sol";
import { GLTToken } from "../../src/GLTToken.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { ProposalManager } from "../../src/ProposalManager.sol";
import { MockLLMOracle } from "../../src/MockLLMOracle.sol";
import { ConsensusEngine } from "../../src/ConsensusEngine.sol";
import { DisputeResolver } from "../../src/DisputeResolver.sol";
import { IValidatorRegistry } from "../../src/interfaces/IValidatorRegistry.sol";
import { IProposalManager } from "../../src/interfaces/IProposalManager.sol";
import { IConsensusEngine } from "../../src/interfaces/IConsensusEngine.sol";
import { IDisputeResolver } from "../../src/interfaces/IDisputeResolver.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title GasBenchmarks
 * @dev Benchmarks for measuring gas usage across different system operations
 */
contract GasBenchmarks is Test {
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

    // Test data
    uint256 constant NUM_VALIDATORS = 20;
    uint256 constant BASE_STAKE = 1000e18;
    uint256[] validatorPrivateKeys;
    address[] validators;

    function setUp() public {
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
        
        // Increase active validator limit for gas optimization tests
        validatorRegistry.setActiveValidatorLimit(NUM_VALIDATORS);

        // Set up multiple validators
        for (uint256 i = 0; i < NUM_VALIDATORS; i++) {
            uint256 privateKey = 0x1000 + i;
            validatorPrivateKeys.push(privateKey);
            address validator = vm.addr(privateKey);
            validators.push(validator);
            
            // Higher stakes for lower indices to ensure they're active
            uint256 stake = BASE_STAKE + ((NUM_VALIDATORS - i) * 100e18);
            setupValidator(validator, stake);
        }
    }

    function setupValidator(address validator, uint256 stake) internal {
        gltToken.mint(validator, stake + 5000e18);
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

    // Benchmark: Gas cost for validator registration with many existing validators
    function test_GasBenchmark_ValidatorRegistrationScaling() public {
        console2.log("=== Gas Benchmark: Validator Registration Scaling ===");
        
        // Measure gas for registering additional validators
        uint256[] memory gasCosts = new uint256[](5);
        
        for (uint256 i = 0; i < 5; i++) {
            address newValidator = address(uint160(0x9000 + i));
            gltToken.mint(newValidator, 3000e18);
            
            vm.startPrank(newValidator);
            gltToken.approve(address(validatorRegistry), type(uint256).max);
            
            uint256 gasBefore = gasleft();
            validatorRegistry.registerValidator(2000e18);
            uint256 gasAfter = gasleft();
            vm.stopPrank();
            
            gasCosts[i] = gasBefore - gasAfter;
            console2.log("Registration", i + 1, "gas cost:", gasCosts[i]);
        }
        
        // Check that gas costs don't increase significantly
        uint256 maxIncrease = (gasCosts[4] * 100) / gasCosts[0];
        if (maxIncrease > 100) {
            console2.log("Gas increase from first to last:", maxIncrease - 100, "%");
        } else {
            console2.log("Gas decreased from first to last:", 100 - maxIncrease, "%");
        }
        assertTrue(maxIncrease < 150, "Gas costs increased too much"); // Max 50% increase
    }

    // Benchmark: Gas costs for consensus voting
    function test_GasBenchmark_ConsensusVotingCosts() public {
        console2.log("=== Gas Benchmark: Consensus Voting Costs ===");
        
        // Create and challenge proposal
        vm.prank(validators[0]);
        uint256 proposalId = proposalManager.createProposal(keccak256("batch test"), "Batch Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        vm.prank(validators[1]);
        proposalManager.challengeProposal(proposalId);
        
        vm.prank(consensusInitiatorRole);
        uint256 roundId = consensusEngine.initiateConsensus(proposalId);
        
        // Measure gas for each vote
        uint256 totalGas = 0;
        uint256 minGas = type(uint256).max;
        uint256 maxGas = 0;
        
        for (uint256 i = 0; i < 15; i++) { // 15 out of 20 validators vote
            bytes memory signature = createVoteSignature(
                validatorPrivateKeys[i],
                roundId,
                i % 2 == 0 // Alternate votes
            );
            
            uint256 gasBefore = gasleft();
            vm.prank(validators[i]);
            consensusEngine.castVote(roundId, i % 2 == 0, signature);
            uint256 gasUsed = gasBefore - gasleft();
            
            totalGas += gasUsed;
            if (gasUsed < minGas) minGas = gasUsed;
            if (gasUsed > maxGas) maxGas = gasUsed;
        }
        
        console2.log("Average gas per vote:", totalGas / 15);
        console2.log("Min gas:", minGas);
        console2.log("Max gas:", maxGas);
        console2.log("Gas variance:", ((maxGas - minGas) * 100) / minGas, "%");
    }

    // Benchmark: Storage cost for proposal metadata of different sizes
    function test_GasBenchmark_ProposalMetadataStorageCost() public {
        console2.log("=== Gas Benchmark: Proposal Metadata Storage Cost ===");
        
        string[4] memory metadataSizes = [
            "Short",
            "This is a medium length metadata string for testing gas costs",
            "This is a much longer metadata string that contains detailed information about the proposal including rationale, implementation details, expected outcomes, and various other considerations that might be relevant",
            "This is an extremely long metadata string that simulates a comprehensive proposal description with multiple sections, detailed technical specifications, economic analysis, risk assessment, implementation timeline, success metrics, governance considerations, and other extensive documentation that might be included in a real-world governance proposal to ensure all stakeholders have complete information"
        ];
        
        uint256[] memory gasCosts = new uint256[](4);
        
        for (uint256 i = 0; i < 4; i++) {
            uint256 gasBefore = gasleft();
            vm.prank(validators[i]);
            proposalManager.createProposal(
                keccak256(abi.encodePacked("test", i)),
                metadataSizes[i]
            );
            gasCosts[i] = gasBefore - gasleft();
            
            console2.log("Metadata length:", bytes(metadataSizes[i]).length, "bytes");
            console2.log("Gas cost:", gasCosts[i]);
        }
        
        // Calculate gas per byte for storage
        uint256 byteDiff = bytes(metadataSizes[3]).length - bytes(metadataSizes[0]).length;
        uint256 gasDiff = gasCosts[3] - gasCosts[0];
        console2.log("Approx gas per metadata byte:", gasDiff / byteDiff);
    }

    // Benchmark: Gas costs for dispute resolution with many votes
    function test_GasBenchmark_DisputeResolutionScaling() public {
        console2.log("=== Gas Benchmark: Dispute Resolution Scaling ===");
        
        // Create proposal and dispute
        vm.prank(validators[0]);
        uint256 proposalId = proposalManager.createProposal(keccak256("dispute test"), "Dispute Test");
        
        vm.prank(proposalManagerRole);
        proposalManager.approveOptimistically(proposalId);
        
        vm.prank(validators[1]);
        uint256 disputeId = disputeResolver.createDispute(proposalId, 200e18);
        
        // Measure gas for voting and resolution
        uint256 votingGasTotal = 0;
        
        // Have many validators vote
        for (uint256 i = 2; i < 18; i++) { // 16 validators vote
            uint256 privateKey = validatorPrivateKeys[i];
            bool supportChallenge = i % 3 != 0; // 2/3 support challenge
            
            uint256 gasBeforeVote = gasleft();
            vm.prank(validators[i]);
            disputeResolver.voteOnDispute(
                disputeId,
                supportChallenge,
                createDisputeVoteSignature(privateKey, disputeId, supportChallenge)
            );
            votingGasTotal += gasBeforeVote - gasleft();
        }
        
        console2.log("Total gas for 16 dispute votes:", votingGasTotal);
        console2.log("Average gas per dispute vote:", votingGasTotal / 16);
        
        // Measure resolution gas
        vm.warp(block.timestamp + 51);
        uint256 gasBefore = gasleft();
        disputeResolver.resolveDispute(disputeId);
        uint256 resolutionGas = gasBefore - gasleft();
        
        console2.log("Dispute resolution gas:", resolutionGas);
    }

    // Benchmark: Gas costs for different validator set operations
    function test_GasBenchmark_ValidatorSetOperationCosts() public {
        console2.log("=== Gas Benchmark: Validator Set Operation Costs ===");
        
        // Measure gas for different update scenarios
        
        // Scenario 1: Small stake increase (no reordering)
        uint256 gasBefore = gasleft();
        vm.prank(validators[10]);
        validatorRegistry.increaseStake(10e18);
        uint256 gasSmallIncrease = gasBefore - gasleft();
        console2.log("Small stake increase gas:", gasSmallIncrease);
        
        // Scenario 2: Large stake increase (causes reordering)
        gasBefore = gasleft();
        vm.prank(validators[15]);
        validatorRegistry.increaseStake(1000e18);
        uint256 gasLargeIncrease = gasBefore - gasleft();
        console2.log("Large stake increase (with reordering) gas:", gasLargeIncrease);
        
        // Scenario 3: Validator unstaking
        gasBefore = gasleft();
        vm.prank(validators[5]);
        validatorRegistry.requestUnstake(BASE_STAKE + 500e18);
        uint256 gasUnstake = gasBefore - gasleft();
        console2.log("Unstaking gas:", gasUnstake);
        
        // Scenario 4: Manual validator set update
        gasBefore = gasleft();
        validatorRegistry.updateActiveValidatorSet();
        uint256 gasManualUpdate = gasBefore - gasleft();
        console2.log("Manual validator set update gas:", gasManualUpdate);
    }

    // Benchmark: Gas cost comparison for different voting patterns
    function test_GasBenchmark_VotingPatternComparison() public {
        console2.log("=== Gas Benchmark: Voting Pattern Comparison ===");
        
        // Create multiple proposals to test different voting patterns
        uint256[] memory proposalIds = new uint256[](3);
        uint256[] memory roundIds = new uint256[](3);
        
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(validators[i]);
            proposalIds[i] = proposalManager.createProposal(
                keccak256(abi.encodePacked("pattern", i)),
                "Pattern Test"
            );
            
            vm.prank(proposalManagerRole);
            proposalManager.approveOptimistically(proposalIds[i]);
            
            vm.prank(validators[i + 1]);
            proposalManager.challengeProposal(proposalIds[i]);
            
            vm.prank(consensusInitiatorRole);
            roundIds[i] = consensusEngine.initiateConsensus(proposalIds[i]);
        }
        
        // Pattern 1: Early unanimous decision (all vote same way early)
        console2.log("\nPattern 1: Early unanimous decision");
        uint256 totalGas1 = 0;
        for (uint256 i = 0; i < 10; i++) {
            uint256 gasBefore = gasleft();
            vm.prank(validators[i]);
            consensusEngine.castVote(
                roundIds[0],
                true,
                createVoteSignature(validatorPrivateKeys[i], roundIds[0], true)
            );
            totalGas1 += gasBefore - gasleft();
        }
        console2.log("Total gas for 10 unanimous votes:", totalGas1);
        
        // Pattern 2: Close decision (alternating votes)
        console2.log("\nPattern 2: Close decision");
        uint256 totalGas2 = 0;
        for (uint256 i = 0; i < 10; i++) {
            uint256 gasBefore = gasleft();
            vm.prank(validators[i]);
            consensusEngine.castVote(
                roundIds[1],
                i % 2 == 0,
                createVoteSignature(validatorPrivateKeys[i], roundIds[1], i % 2 == 0)
            );
            totalGas2 += gasBefore - gasleft();
        }
        console2.log("Total gas for 10 alternating votes:", totalGas2);
        
        // Pattern 3: Late surge (early minority, late majority)
        console2.log("\nPattern 3: Late surge");
        uint256 totalGas3 = 0;
        for (uint256 i = 0; i < 10; i++) {
            bool vote = i >= 7; // Last 3 vote true
            uint256 gasBefore = gasleft();
            vm.prank(validators[i]);
            consensusEngine.castVote(
                roundIds[2],
                vote,
                createVoteSignature(validatorPrivateKeys[i], roundIds[2], vote)
            );
            totalGas3 += gasBefore - gasleft();
        }
        console2.log("Total gas for 10 late surge votes:", totalGas3);
        
        console2.log("\nGas comparison:");
        console2.log("Pattern 2 efficiency vs unanimous:", (totalGas2 * 100) / totalGas1, "%");
        console2.log("Pattern 3 efficiency vs unanimous:", (totalGas3 * 100) / totalGas1, "%");
    }
}