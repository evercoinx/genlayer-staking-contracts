// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "@forge-std/Script.sol";
import { console2 } from "@forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { GLTToken } from "../src/GLTToken.sol";
import { ValidatorRegistry } from "../src/ValidatorRegistry.sol";

/**
 * @title DeployHelpers
 * @dev Helper scripts for post-deployment tasks like validator registration and token distribution.
 */
contract DeployHelpers is Script {
    // Addresses from deployment (update these after deployment)
    address constant GLT_TOKEN = address(0);
    address constant VALIDATOR_REGISTRY = address(0);

    // Test validator addresses
    address constant VALIDATOR_1 = address(0x1111111111111111111111111111111111111111);
    address constant VALIDATOR_2 = address(0x2222222222222222222222222222222222222222);
    address constant VALIDATOR_3 = address(0x3333333333333333333333333333333333333333);

    /**
     * @dev Distributes GLT tokens to test validators.
     * Run with: forge script script/DeployHelpers.s.sol:DeployHelpers --sig "distributeTokens()" --rpc-url $RPC_URL
     * --broadcast
     */
    function distributeTokens() external {
        require(GLT_TOKEN != address(0), "Update GLT_TOKEN address");

        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        vm.startBroadcast(deployerPrivateKey);

        GLTToken gltToken = GLTToken(GLT_TOKEN);
        uint256 amountPerValidator = 10_000e18; // 10,000 GLT per validator

        console2.log("Distributing GLT tokens to validators...");

        gltToken.mint(VALIDATOR_1, amountPerValidator);
        console2.log("Minted", amountPerValidator / 1e18, "GLT to validator 1:", VALIDATOR_1);

        gltToken.mint(VALIDATOR_2, amountPerValidator);
        console2.log("Minted", amountPerValidator / 1e18, "GLT to validator 2:", VALIDATOR_2);

        gltToken.mint(VALIDATOR_3, amountPerValidator);
        console2.log("Minted", amountPerValidator / 1e18, "GLT to validator 3:", VALIDATOR_3);

        vm.stopBroadcast();

        console2.log("Token distribution complete!");
    }

    /**
     * @dev Registers test validators (requires validators to have approved GLT tokens).
     * Run with: forge script script/DeployHelpers.s.sol:DeployHelpers --sig "registerValidators()" --rpc-url $RPC_URL
     * --broadcast
     */
    function registerValidators() external pure {
        require(GLT_TOKEN != address(0), "Update GLT_TOKEN address");
        require(VALIDATOR_REGISTRY != address(0), "Update VALIDATOR_REGISTRY address");

        // This would need to be run by each validator individually
        // This is just an example of how to register
        console2.log("Validators need to:");
        console2.log("1. Approve GLT tokens to ValidatorRegistry");
        console2.log("2. Call registerValidator() with stake amount");
        console2.log("");
        console2.log("Example commands:");
        console2.log("cast send <GLT_TOKEN> 'approve(address,uint256)' <VALIDATOR_REGISTRY> 2000000000000000000000");
        console2.log("cast send <VALIDATOR_REGISTRY> 'registerValidator(uint256)' 2000000000000000000000");
    }

    /**
     * @dev Checks the current state of validators.
     * Run with: forge script script/DeployHelpers.s.sol:DeployHelpers --sig "checkValidatorStatus()" --rpc-url $RPC_URL
     */
    function checkValidatorStatus() external view {
        require(VALIDATOR_REGISTRY != address(0), "Update VALIDATOR_REGISTRY address");

        ValidatorRegistry registry = ValidatorRegistry(VALIDATOR_REGISTRY);

        console2.log("Validator Registry Status:");
        console2.log("Total validators:", registry.getTotalValidators());
        console2.log("Total stake:", registry.getTotalStake());
        console2.log("Active validators:", registry.getActiveValidators().length);
        console2.log("Max validators:", registry.getMaxValidators());
        console2.log("Minimum stake:", registry.getMinimumStake());
    }
}
