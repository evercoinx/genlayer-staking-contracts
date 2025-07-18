// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IMockLLMOracle
 * @dev Interface for the Mock LLM Oracle that simulates validation responses
 * in the GenLayer consensus system. This mock implementation provides deterministic
 * responses based on proposal hashes for testing purposes.
 */
interface IMockLLMOracle {
    /**
     * @dev Emitted when a validation is performed.
     * @param proposalId The ID of the proposal being validated.
     * @param proposalHash The hash of the proposal.
     * @param isValid The validation result.
     */
    event ValidationPerformed(uint256 indexed proposalId, bytes32 proposalHash, bool isValid);

    /**
     * @dev Emitted when batch validation is performed.
     * @param proposalIds The array of proposal IDs validated.
     * @param results The array of validation results.
     */
    event BatchValidationPerformed(uint256[] proposalIds, bool[] results);

    /**
     * @dev Error thrown when arrays have mismatched lengths.
     */
    error ArrayLengthMismatch();

    /**
     * @dev Error thrown when an empty array is provided.
     */
    error EmptyArray();

    /**
     * @dev Error thrown when the maximum batch size is exceeded.
     */
    error BatchSizeTooLarge();

    /**
     * @dev Validates a proposal based on its hash.
     * Returns true for even hashes and false for odd hashes.
     * @param proposalId The ID of the proposal to validate.
     * @param proposalHash The hash of the proposal content.
     * @return isValid True if the proposal is valid (even hash), false otherwise.
     */
    function validateProposal(uint256 proposalId, bytes32 proposalHash) external returns (bool isValid);

    /**
     * @dev Validates multiple proposals in a single call.
     * @param proposalIds Array of proposal IDs to validate.
     * @param proposalHashes Array of proposal hashes.
     * @return results Array of validation results.
     */
    function batchValidateProposals(
        uint256[] calldata proposalIds,
        bytes32[] calldata proposalHashes
    ) external returns (bool[] memory results);

    /**
     * @dev View function to check if a proposal would be valid without emitting events.
     * @param proposalHash The hash of the proposal to check.
     * @return isValid True if the proposal would be valid (even hash), false otherwise.
     */
    function checkValidation(bytes32 proposalHash) external pure returns (bool isValid);

    /**
     * @dev Returns the maximum batch size allowed for batch validation.
     * @return maxBatchSize The maximum number of proposals that can be validated in one batch.
     */
    function getMaxBatchSize() external pure returns (uint256 maxBatchSize);

    /**
     * @dev Returns the total number of validations performed by this oracle.
     * @return count The total validation count.
     */
    function getTotalValidations() external view returns (uint256 count);
}