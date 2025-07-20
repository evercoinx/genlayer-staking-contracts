// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { IMockLLMOracle } from "../../src/interfaces/IMockLLMOracle.sol";
import { MockLLMOracle } from "../../src/MockLLMOracle.sol";

/**
 * @title MockLLMOracleTest
 * @dev Test suite for MockLLMOracle contract.
 */
contract MockLLMOracleTest is Test {
    MockLLMOracle public oracle;

    event ValidationPerformed(uint256 indexed proposalId, bytes32 proposalHash, bool isValid);
    event BatchValidationPerformed(uint256[] proposalIds, bool[] results);

    function setUp() public {
        oracle = new MockLLMOracle();
    }

    // Single Validation Tests
    function test_ValidateProposal_EvenHash() public {
        uint256 proposalId = 1;
        bytes32 evenHash = bytes32(uint256(0x1234)); // Even last byte

        vm.expectEmit(true, false, false, true);
        emit ValidationPerformed(proposalId, evenHash, true);

        bool result = oracle.validateProposal(proposalId, evenHash);

        assertTrue(result, "Even hash should be valid");
        assertEq(oracle.getTotalValidations(), 1);
    }

    function test_ValidateProposal_OddHash() public {
        uint256 proposalId = 2;
        bytes32 oddHash = bytes32(uint256(0x1235)); // Odd last byte

        vm.expectEmit(true, false, false, true);
        emit ValidationPerformed(proposalId, oddHash, false);

        bool result = oracle.validateProposal(proposalId, oddHash);

        assertFalse(result, "Odd hash should be invalid");
        assertEq(oracle.getTotalValidations(), 1);
    }

    // Batch Validation Tests
    function test_BatchValidateProposals_Success() public {
        uint256[] memory proposalIds = new uint256[](3);
        bytes32[] memory hashes = new bytes32[](3);

        proposalIds[0] = 1;
        proposalIds[1] = 2;
        proposalIds[2] = 3;

        hashes[0] = bytes32(uint256(0x1234)); // Even
        hashes[1] = bytes32(uint256(0x1235)); // Odd
        hashes[2] = bytes32(uint256(0x1236)); // Even

        bool[] memory expectedResults = new bool[](3);
        expectedResults[0] = true;
        expectedResults[1] = false;
        expectedResults[2] = true;

        vm.expectEmit(false, false, false, true);
        emit BatchValidationPerformed(proposalIds, expectedResults);

        bool[] memory results = oracle.batchValidateProposals(proposalIds, hashes);

        assertEq(results.length, 3);
        assertTrue(results[0], "First hash should be valid");
        assertFalse(results[1], "Second hash should be invalid");
        assertTrue(results[2], "Third hash should be valid");
        assertEq(oracle.getTotalValidations(), 3);
    }

    function test_BatchValidateProposals_RevertIfArrayLengthMismatch() public {
        uint256[] memory proposalIds = new uint256[](2);
        bytes32[] memory hashes = new bytes32[](3);

        vm.expectRevert(IMockLLMOracle.ArrayLengthMismatch.selector);
        oracle.batchValidateProposals(proposalIds, hashes);
    }

    function test_BatchValidateProposals_RevertIfEmptyArray() public {
        uint256[] memory proposalIds = new uint256[](0);
        bytes32[] memory hashes = new bytes32[](0);

        vm.expectRevert(IMockLLMOracle.EmptyArray.selector);
        oracle.batchValidateProposals(proposalIds, hashes);
    }

    function test_BatchValidateProposals_RevertIfExceedsMaxBatchSize() public {
        uint256 maxSize = oracle.getMaxBatchSize();
        uint256[] memory proposalIds = new uint256[](maxSize + 1);
        bytes32[] memory hashes = new bytes32[](maxSize + 1);

        vm.expectRevert(IMockLLMOracle.BatchSizeTooLarge.selector);
        oracle.batchValidateProposals(proposalIds, hashes);
    }

    // Check Validation Tests
    function test_CheckValidation_EvenHash() public view {
        bytes32 evenHash = bytes32(uint256(0x1234));
        assertTrue(oracle.checkValidation(evenHash));
    }

    function test_CheckValidation_OddHash() public view {
        bytes32 oddHash = bytes32(uint256(0x1235));
        assertFalse(oracle.checkValidation(oddHash));
    }

    // View Function Tests
    function test_GetMaxBatchSize() public view {
        assertEq(oracle.getMaxBatchSize(), 100);
    }

    function test_GetTotalValidations_InitiallyZero() public view {
        assertEq(oracle.getTotalValidations(), 0);
    }

    function test_TotalValidations_IncreasesCorrectly() public {
        oracle.validateProposal(1, bytes32(uint256(0x1234)));
        assertEq(oracle.getTotalValidations(), 1);

        uint256[] memory proposalIds = new uint256[](3);
        bytes32[] memory hashes = new bytes32[](3);
        for (uint256 i = 0; i < 3; i++) {
            proposalIds[i] = i + 2;
            hashes[i] = bytes32(uint256(i));
        }

        oracle.batchValidateProposals(proposalIds, hashes);
        assertEq(oracle.getTotalValidations(), 4);
    }

    // Fuzz Tests
    function testFuzz_ValidateProposal(uint256 proposalId, bytes32 hash) public {
        bool expectedResult = uint8(hash[31]) % 2 == 0;

        bool result = oracle.validateProposal(proposalId, hash);

        assertEq(result, expectedResult);
        assertEq(oracle.getTotalValidations(), 1);
    }

    function testFuzz_CheckValidation(bytes32 hash) public view {
        bool expectedResult = uint8(hash[31]) % 2 == 0;
        bool result = oracle.checkValidation(hash);
        assertEq(result, expectedResult);
    }

    function testFuzz_BatchValidation(uint8 batchSize, uint256 seed) public {
        vm.assume(batchSize > 0 && batchSize <= 100);

        uint256[] memory proposalIds = new uint256[](batchSize);
        bytes32[] memory hashes = new bytes32[](batchSize);

        for (uint256 i = 0; i < batchSize; i++) {
            proposalIds[i] = i + 1;
            hashes[i] = keccak256(abi.encodePacked(seed, i));
        }

        bool[] memory results = oracle.batchValidateProposals(proposalIds, hashes);

        assertEq(results.length, batchSize);
        assertEq(oracle.getTotalValidations(), batchSize);

        // Verify each result
        for (uint256 i = 0; i < batchSize; i++) {
            bool expectedResult = uint8(hashes[i][31]) % 2 == 0;
            assertEq(results[i], expectedResult);
        }
    }
}
