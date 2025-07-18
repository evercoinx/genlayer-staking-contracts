// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IValidatorRegistry
 * @dev Interface for the ValidatorRegistry contract that manages validator registration,
 * staking, and selection for the GenLayer consensus system.
 */
interface IValidatorRegistry {
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
        uint256 unstakeRequestTime;
        uint256 activationTime;
    }

    /**
     * @dev Emitted when a new validator registers.
     * @param validator The address of the validator.
     * @param stakedAmount The amount of GLT tokens staked.
     */
    event ValidatorRegistered(address indexed validator, uint256 stakedAmount);

    /**
     * @dev Emitted when a validator increases their stake.
     * @param validator The address of the validator.
     * @param additionalStake The additional amount staked.
     * @param newTotalStake The new total stake amount.
     */
    event StakeIncreased(address indexed validator, uint256 additionalStake, uint256 newTotalStake);

    /**
     * @dev Emitted when a validator requests to unstake.
     * @param validator The address of the validator.
     * @param unstakeAmount The amount to unstake.
     * @param unstakeRequestTime The timestamp when unstaking was requested.
     */
    event UnstakeRequested(address indexed validator, uint256 unstakeAmount, uint256 unstakeRequestTime);

    /**
     * @dev Emitted when a validator completes unstaking.
     * @param validator The address of the validator.
     * @param unstakedAmount The amount unstaked.
     */
    event UnstakeCompleted(address indexed validator, uint256 unstakedAmount);

    /**
     * @dev Emitted when a validator is slashed.
     * @param validator The address of the validator.
     * @param slashedAmount The amount slashed.
     * @param reason The reason for slashing.
     */
    event ValidatorSlashed(address indexed validator, uint256 slashedAmount, string reason);

    /**
     * @dev Emitted when the active validator set is updated.
     * @param validators The array of active validator addresses.
     * @param blockNumber The block number at which the update occurred.
     */
    event ActiveValidatorSetUpdated(address[] validators, uint256 blockNumber);

    /**
     * @dev Error thrown when attempting to register with insufficient stake.
     */
    error InsufficientStake();

    /**
     * @dev Error thrown when a validator is already registered.
     */
    error ValidatorAlreadyRegistered();

    /**
     * @dev Error thrown when a validator is not found.
     */
    error ValidatorNotFound();

    /**
     * @dev Error thrown when attempting an action with invalid validator status.
     */
    error InvalidValidatorStatus();

    /**
     * @dev Error thrown when unstaking before the bonding period ends.
     */
    error BondingPeriodNotMet();

    /**
     * @dev Error thrown when zero address is provided.
     */
    error ZeroAddress();

    /**
     * @dev Error thrown when zero amount is provided.
     */
    error ZeroAmount();

    /**
     * @dev Error thrown when attempting to unstake more than staked amount.
     */
    error UnstakeExceedsStake();

    /**
     * @dev Error thrown when the maximum number of validators is reached.
     */
    error MaxValidatorsReached();

    /**
     * @dev Registers a new validator with the specified stake.
     * @param stakeAmount The amount of GLT tokens to stake.
     */
    function registerValidator(uint256 stakeAmount) external;

    /**
     * @dev Increases the stake of an existing validator.
     * @param additionalStake The additional amount to stake.
     */
    function increaseStake(uint256 additionalStake) external;

    /**
     * @dev Requests to unstake tokens. Initiates the bonding period.
     * @param unstakeAmount The amount to unstake.
     */
    function requestUnstake(uint256 unstakeAmount) external;

    /**
     * @dev Completes the unstaking process after the bonding period.
     */
    function completeUnstake() external;

    /**
     * @dev Slashes a validator's stake for misbehavior.
     * @param validator The address of the validator to slash.
     * @param slashAmount The amount to slash.
     * @param reason The reason for slashing.
     */
    function slashValidator(address validator, uint256 slashAmount, string calldata reason) external;

    /**
     * @dev Updates the active validator set based on stake amounts.
     */
    function updateActiveValidatorSet() external;

    /**
     * @dev Returns the information of a specific validator.
     * @param validator The address of the validator.
     * @return info The validator information.
     */
    function getValidatorInfo(address validator) external view returns (ValidatorInfo memory info);

    /**
     * @dev Returns the list of active validators.
     * @return validators The array of active validator addresses.
     */
    function getActiveValidators() external view returns (address[] memory validators);

    /**
     * @dev Returns the total number of registered validators.
     * @return count The total number of validators.
     */
    function getTotalValidators() external view returns (uint256 count);

    /**
     * @dev Returns the total amount staked across all validators.
     * @return totalStake The total staked amount.
     */
    function getTotalStake() external view returns (uint256 totalStake);

    /**
     * @dev Checks if an address is an active validator.
     * @param validator The address to check.
     * @return isActive True if the address is an active validator.
     */
    function isActiveValidator(address validator) external view returns (bool isActive);

    /**
     * @dev Returns the minimum stake required to become a validator.
     * @return minStake The minimum stake amount.
     */
    function getMinimumStake() external view returns (uint256 minStake);

    /**
     * @dev Returns the bonding period duration.
     * @return bondingPeriod The bonding period in seconds.
     */
    function getBondingPeriod() external view returns (uint256 bondingPeriod);

    /**
     * @dev Returns the maximum number of active validators.
     * @return maxValidators The maximum number of validators.
     */
    function getMaxValidators() external view returns (uint256 maxValidators);
}