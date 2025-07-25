// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IMockLLMOracle } from "./interfaces/IMockLLMOracle.sol";

/**
 * @title MockLLMOracle
 * @dev Mock implementation of an LLM oracle for the GenLayer consensus system.
 * This contract provides deterministic validation responses based on proposal hashes
 * for testing purposes. Even hashes are considered valid, odd hashes are invalid.
 */
contract MockLLMOracle is IMockLLMOracle {
    uint256 public constant MAX_BATCH_SIZE = 100;
    uint256 private totalValidations;

    /**
     * @inheritdoc IMockLLMOracle
     */
    function validateProposal(uint256 proposalId, bytes32 proposalHash) external returns (bool isValid) {
        isValid = _isValidHash(proposalHash);
        totalValidations++;

        emit ValidationPerformed(proposalId, proposalHash, isValid);

        return isValid;
    }

    /**
     * @inheritdoc IMockLLMOracle
     */
    function batchValidateProposals(
        uint256[] calldata proposalIds,
        bytes32[] calldata proposalHashes
    )
        external
        returns (bool[] memory results)
    {
        require(proposalIds.length == proposalHashes.length, ArrayLengthMismatch());
        require(proposalIds.length != 0, EmptyArray());
        require(proposalIds.length <= MAX_BATCH_SIZE, BatchSizeTooLarge());

        results = new bool[](proposalIds.length);

        for (uint256 i = 0; i < proposalIds.length; i++) {
            results[i] = _isValidHash(proposalHashes[i]);
            totalValidations++;
        }

        emit BatchValidationPerformed(proposalIds, results);

        return results;
    }

    /**
     * @inheritdoc IMockLLMOracle
     */
    function getTotalValidations() external view returns (uint256) {
        return totalValidations;
    }

    /**
     * @inheritdoc IMockLLMOracle
     */
    function checkValidation(bytes32 proposalHash) external pure returns (bool isValid) {
        return _isValidHash(proposalHash);
    }

    /**
     * @inheritdoc IMockLLMOracle
     */
    function getMaxBatchSize() external pure returns (uint256) {
        return MAX_BATCH_SIZE;
    }

    /**
     * @dev Internal function to determine if a hash is valid.
     * Uses deterministic logic: even hashes are valid, odd hashes are invalid.
     * @param hash The hash to validate.
     * @return True if the hash is even, false if odd.
     */
    function _isValidHash(bytes32 hash) private pure returns (bool) {
        // Deterministic: even hashes are valid, odd hashes are invalid
        return uint8(hash[31]) % 2 == 0;
    }
}
