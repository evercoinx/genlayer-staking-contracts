// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IValidatorBeacon
 * @dev Interface for the ValidatorBeacon contract that manages the implementation for all
 * validator proxy contracts.
 */
interface IValidatorBeacon {
    /**
     * @dev Error thrown when attempting to set implementation to zero address.
     */
    error ZeroImplementation();

    /**
     * @dev Error thrown when attempting to upgrade to the same implementation address.
     */
    error ImplementationUnchanged();

    /**
     * @dev Emitted when the validator implementation is upgraded.
     * @param implementation The new implementation address.
     */
    event ValidatorImplementationUpgraded(address indexed implementation);

    /**
     * @dev Upgrades the validator implementation for all beacon proxies.
     * @param newImplementation The new validator implementation address.
     */
    function upgradeImplementation(address newImplementation) external;
}
