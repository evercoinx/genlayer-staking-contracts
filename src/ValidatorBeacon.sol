// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/**
 * @title ValidatorBeacon
 * @dev Beacon contract that manages the implementation for all validator proxy contracts.
 * This allows for upgradeable validator logic while keeping individual validator state isolated.
 */
contract ValidatorBeacon is UpgradeableBeacon {
    /**
     * @dev Emitted when the validator implementation is upgraded.
     * @param implementation The new implementation address.
     */
    event ValidatorImplementationUpgraded(address indexed implementation);

    /**
     * @dev Initializes the beacon with the validator implementation.
     * @param implementation The initial validator implementation address.
     * @param owner The address that will own the beacon (typically the ValidatorRegistry).
     */
    constructor(address implementation, address owner) UpgradeableBeacon(implementation, owner) {
        // UpgradeableBeacon constructor handles implementation and ownership setup
    }

    /**
     * @dev Upgrades the validator implementation for all beacon proxies.
     * @param newImplementation The new validator implementation address.
     */
    function upgradeImplementation(address newImplementation) external onlyOwner {
        upgradeTo(newImplementation);
        emit ValidatorImplementationUpgraded(newImplementation);
    }

    /**
     * @dev Returns the current validator implementation address.
     * @return The implementation address.
     */
    function getImplementation() external view returns (address) {
        return implementation();
    }
}
