// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IValidator } from "./IValidator.sol";

/**
 * @title IValidatorRegistry
 * @dev Interface for the ValidatorRegistry contract that manages validator registration,
 * staking, and selection for the GenLayer consensus system using beacon proxy pattern.
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
        uint256 unstakeRequestBlock;
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
     * @param unstakeRequestBlock The block number when unstaking was requested.
     */
    event UnstakeRequested(address indexed validator, uint256 unstakeAmount, uint256 unstakeRequestBlock);

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
     * @dev Emitted when a new validator proxy is created.
     * @param validator The validator address.
     * @param proxy The beacon proxy contract address.
     * @param stakedAmount The initial stake amount.
     */
    event ValidatorProxyCreated(address indexed validator, address indexed proxy, uint256 stakedAmount);

    /**
     * @dev Emitted when the active validator limit is changed.
     * @param oldLimit The previous limit.
     * @param newLimit The new limit.
     */
    event ActiveValidatorLimitChanged(uint256 oldLimit, uint256 newLimit);

    /**
     * @dev Emitted when the slasher is updated.
     * @param oldSlasher The previous slasher address.
     * @param newSlasher The new slasher address.
     */
    event SlasherUpdated(address indexed oldSlasher, address indexed newSlasher);

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
     * @dev Error thrown when zero address is provided for GLT token.
     */
    error ZeroGLTToken();

    /**
     * @dev Error thrown when zero address is provided for slasher.
     */
    error ZeroSlasher();

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
     * @dev Error thrown when caller is not the slasher.
     */
    error CallerNotSlasher();

    /**
     * @dev Error thrown when validator limit is invalid.
     */
    error InvalidValidatorLimit();

    /**
     * @dev Error thrown when count parameter is invalid.
     */
    error InvalidCount();

    /**
     * @dev Error thrown when active validator limit is zero.
     */
    error ZeroActiveValidatorLimit();

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
     * @dev Updates the active validator set based on stake amounts. Only callable by owner.
     */
    function updateActiveValidatorSet() external;

    /**
     * @dev Returns the information of a specific validator.
     * @param validator The address of the validator.
     * @return info The validator information.
     */
    function getValidatorInfo(address validator) external view returns (ValidatorInfo memory info);

    /**
     * @dev Returns the total number of registered validators.
     * @return count The total number of validators.
     */
    function getTotalValidators() external view returns (uint256 count);

    /**
     * @dev Checks if an address is an active validator.
     * @param validator The address to check.
     * @return isActive True if the address is an active validator.
     */
    function isActiveValidator(address validator) external view returns (bool isActive);


    /**
     * @dev Registers a new validator with metadata using beacon proxy pattern.
     * @param stakeAmount The amount of GLT tokens to stake.
     * @param metadata The validator metadata.
     */
    function registerValidatorWithMetadata(uint256 stakeAmount, string memory metadata) external;

    /**
     * @dev Returns the validator info with metadata.
     * @param validator The validator address.
     * @return info The validator info including metadata.
     */
    function getValidatorInfoWithMetadata(address validator)
        external
        view
        returns (IValidator.ValidatorInfo memory info);

    /**
     * @dev Returns the beacon proxy address for a validator.
     * @param validator The validator address.
     * @return proxy The beacon proxy address.
     */
    function getValidatorProxy(address validator) external view returns (address proxy);

    /**
     * @dev Returns the validator beacon address.
     * @return The beacon address.
     */
    function getValidatorBeacon() external view returns (address);

    /**
     * @dev Upgrades the validator implementation for all beacon proxies.
     * @param newImplementation The new validator implementation address.
     */
    function upgradeValidatorImplementation(address newImplementation) external;

    /**
     * @dev Returns the top N validators based on stake amount.
     * @param n The number of top validators to return.
     * @return topValidators The addresses of the top N validators.
     */
    function getTopValidators(uint256 n) external view returns (address[] memory topValidators);

    /**
     * @dev Checks if an address is in the top N validators.
     * @param validator The validator address to check.
     * @param n The size of the top validator set.
     * @return isTop True if the validator is in the top N.
     */
    function isTopValidator(address validator, uint256 n) external view returns (bool isTop);

    /**
     * @dev Sets the number of active validators. Only callable by owner.
     * @param newLimit The new active validator limit (must be between 1 and MAX_VALIDATORS).
     */
    function setActiveValidatorLimit(uint256 newLimit) external;


    /**
     * @dev Sets a new slasher address. Only callable by owner.
     * @param newSlasher The address to grant slashing privileges to.
     */
    function setSlasher(address newSlasher) external;

    /**
     * @dev Returns the active validator limit.
     * @return The active validator limit.
     */
    function activeValidatorLimit() external view returns (uint256);

    /**
     * @dev Returns the total amount staked across all validators.
     * @return The total staked amount.
     */
    function totalStaked() external view returns (uint256);

    /**
     * @dev Returns the array of active validators.
     * @return The array of active validator addresses.
     */
    function getActiveValidators() external view returns (address[] memory);
}
