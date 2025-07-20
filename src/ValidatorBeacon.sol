// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { IValidatorBeacon } from "./interfaces/IValidatorBeacon.sol";

/**
 * @title ValidatorBeacon
 * @dev Beacon contract that manages the implementation for all validator proxy contracts.
 * This allows for upgradeable validator logic while keeping individual validator state isolated.
 */
contract ValidatorBeacon is IValidatorBeacon, UpgradeableBeacon {
    /**
     * @dev Initializes the beacon with the validator implementation.
     * @param implementation The initial validator implementation address.
     * @param owner The address that will own the beacon (typically the ValidatorRegistry).
     */
    constructor(address implementation, address owner) UpgradeableBeacon(implementation, owner) { }

    /**
     * @dev Upgrades the validator implementation for all beacon proxies.
     * @param newImplementation The new validator implementation address.
     */
    function upgradeImplementation(address newImplementation) external override onlyOwner {
        require(newImplementation != address(0), ZeroImplementation());
        require(newImplementation != implementation(), ImplementationUnchanged());

        upgradeTo(newImplementation);
        emit ValidatorImplementationUpgraded(newImplementation);
    }
}
