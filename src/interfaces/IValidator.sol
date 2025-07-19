// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IValidator
 * @dev Interface for individual validator beacon proxy contracts that hold validator stake and metadata.
 */
interface IValidator {
    /**
     * @dev Enum representing the status of a validator.
     */
    enum ValidatorStatus {
        Inactive,
        Active,
        Unstaking,
        Slashed
    }

    /**
     * @dev Struct containing validator information.
     */
    struct ValidatorInfo {
        address validatorAddress;
        uint256 stakedAmount;
        ValidatorStatus status;
        uint256 unstakeRequestTime; // Actually stores block number now
        uint256 activationTime;
        string metadata;
    }

    /**
     * @dev Emitted when the validator's stake is increased.
     * @param amount The additional amount staked.
     * @param newTotal The new total stake amount.
     */
    event StakeIncreased(uint256 amount, uint256 newTotal);

    /**
     * @dev Emitted when a validator requests to unstake.
     * @param amount The amount to unstake.
     * @param requestBlock The block number when unstaking was requested.
     */
    event UnstakeRequested(uint256 amount, uint256 requestBlock);

    /**
     * @dev Emitted when a validator completes unstaking.
     * @param amount The amount unstaked.
     */
    event UnstakeCompleted(uint256 amount);

    /**
     * @dev Emitted when a validator is slashed.
     * @param amount The amount slashed.
     * @param reason The reason for slashing.
     */
    event ValidatorSlashed(uint256 amount, string reason);

    /**
     * @dev Emitted when validator metadata is updated.
     * @param metadata The new metadata.
     */
    event MetadataUpdated(string metadata);

    /**
     * @dev Error thrown when attempting to perform an action with insufficient stake.
     */
    error InsufficientStake();

    /**
     * @dev Error thrown when attempting an action with invalid validator status.
     */
    error InvalidValidatorStatus();

    /**
     * @dev Error thrown when unstaking before the bonding period ends.
     */
    error BondingPeriodNotMet();

    /**
     * @dev Error thrown when zero amount is provided.
     */
    error ZeroAmount();

    /**
     * @dev Error thrown when attempting to unstake more than staked amount.
     */
    error UnstakeExceedsStake();

    /**
     * @dev Error thrown when caller is not authorized.
     */
    error Unauthorized();

    /**
     * @dev Initializes the validator with initial stake and metadata.
     * @param _validatorAddress The address of the validator.
     * @param _initialStake The initial stake amount.
     * @param _metadata The validator metadata.
     * @param _gltToken The GLT token address.
     * @param _registry The validator registry address.
     */
    function initialize(
        address _validatorAddress,
        uint256 _initialStake,
        string calldata _metadata,
        address _gltToken,
        address _registry
    ) external;

    /**
     * @dev Increases the validator's stake.
     * @param amount The additional amount to stake.
     */
    function increaseStake(uint256 amount) external;

    /**
     * @dev Requests to unstake tokens. Initiates the bonding period.
     * @param amount The amount to unstake.
     */
    function requestUnstake(uint256 amount) external;

    /**
     * @dev Completes the unstaking process after the bonding period.
     */
    function completeUnstake() external;

    /**
     * @dev Slashes the validator's stake. Only callable by registry.
     * @param amount The amount to slash.
     * @param reason The reason for slashing.
     */
    function slash(uint256 amount, string calldata reason) external;

    /**
     * @dev Updates the validator metadata.
     * @param _metadata The new metadata.
     */
    function updateMetadata(string calldata _metadata) external;

    /**
     * @dev Returns the validator information.
     * @return info The validator information struct.
     */
    function getValidatorInfo() external view returns (ValidatorInfo memory info);

    /**
     * @dev Returns the validator's address.
     * @return The validator address.
     */
    function getValidatorAddress() external view returns (address);

    /**
     * @dev Returns the current staked amount.
     * @return The staked amount.
     */
    function getStakedAmount() external view returns (uint256);

    /**
     * @dev Returns the validator's status.
     * @return The validator status.
     */
    function getStatus() external view returns (ValidatorStatus);

    /**
     * @dev Returns the validator's metadata.
     * @return The validator metadata.
     */
    function getMetadata() external view returns (string memory);

    /**
     * @dev Checks if the validator can complete unstaking.
     * @return True if unstaking can be completed.
     */
    function canCompleteUnstake() external view returns (bool);
}