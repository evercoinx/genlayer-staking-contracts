// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "@forge-std/Script.sol";
import { console2 } from "@forge-std/console2.sol";
import { ConsensusEngine } from "../src/ConsensusEngine.sol";
import { DisputeResolver } from "../src/DisputeResolver.sol";
import { GLTToken } from "../src/GLTToken.sol";
import { MockLLMOracle } from "../src/MockLLMOracle.sol";
import { ProposalManager } from "../src/ProposalManager.sol";
import { ValidatorRegistry } from "../src/ValidatorRegistry.sol";

/**
 * @title Deploy
 * @dev Deployment script for the GenLayer consensus system contracts with beacon proxy pattern.
 *
 * Usage:
 * forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
 *
 * For localhost deployment with test setup:
 * forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 */
contract Deploy is Script {
    uint256 public constant INITIAL_GLT_SUPPLY = 100_000_000e18;
    uint256 public constant TEST_VALIDATOR_STAKE = 10_000e18;
    uint256 public constant TEST_VALIDATOR_COUNT = 3;
    address public constant TEST_VALIDATOR_1 = address(0x1111111111111111111111111111111111111111);
    address public constant TEST_VALIDATOR_2 = address(0x2222222222222222222222222222222222222222);
    address public constant TEST_VALIDATOR_3 = address(0x3333333333333333333333333333333333333333);

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("Deploying GenLayer contracts with Beacon Proxy architecture...");
        console2.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        GLTToken gltToken = new GLTToken(deployer);
        console2.log("GLTToken deployed at:", address(gltToken));

        MockLLMOracle llmOracle = new MockLLMOracle();
        console2.log("MockLLMOracle deployed at:", address(llmOracle));

        ValidatorRegistry validatorRegistry = new ValidatorRegistry(address(gltToken), deployer, 5);
        console2.log("ValidatorRegistry deployed at:", address(validatorRegistry));
        console2.log("ValidatorBeacon deployed at:", validatorRegistry.getValidatorBeacon());

        ProposalManager proposalManager = new ProposalManager(address(validatorRegistry), address(llmOracle), deployer);
        console2.log("ProposalManager deployed at:", address(proposalManager));

        ConsensusEngine consensusEngine =
            new ConsensusEngine(address(validatorRegistry), address(proposalManager), deployer);
        console2.log("ConsensusEngine deployed at:", address(consensusEngine));

        DisputeResolver disputeResolver =
            new DisputeResolver(address(gltToken), address(validatorRegistry), address(proposalManager));
        console2.log("DisputeResolver deployed at:", address(disputeResolver));

        gltToken.mint(deployer, INITIAL_GLT_SUPPLY);
        console2.log("Minted", INITIAL_GLT_SUPPLY / 1e18, "GLT tokens to deployer");

        validatorRegistry.setSlasher(address(disputeResolver));
        console2.log("Updated ValidatorRegistry slasher to DisputeResolver");

        vm.stopBroadcast();

        console2.log("\nDeployment complete!");
        _logDeploymentSummary(
            address(gltToken),
            address(llmOracle),
            address(validatorRegistry),
            address(proposalManager),
            address(consensusEngine),
            address(disputeResolver)
        );

        if (block.chainid == 31_337) {
            console2.log("\n=====================================");
            console2.log("Setting up test validators for localhost...");
            console2.log("=====================================");
            _setupTestValidators(gltToken, validatorRegistry, deployerPrivateKey);
        }
    }

    function _logDeploymentSummary(
        address gltToken,
        address llmOracle,
        address validatorRegistry,
        address proposalManager,
        address consensusEngine,
        address disputeResolver
    )
        internal
        view
    {
        console2.log("=====================================");
        console2.log("Architecture: Beacon Proxy Pattern");
        console2.log("=====================================");
        console2.log("GLTToken:", gltToken);
        console2.log("MockLLMOracle:", llmOracle);
        console2.log("ValidatorRegistry:", validatorRegistry);
        console2.log("ValidatorBeacon:", ValidatorRegistry(validatorRegistry).getValidatorBeacon());
        console2.log("ProposalManager:", proposalManager);
        console2.log("ConsensusEngine:", consensusEngine);
        console2.log("DisputeResolver:", disputeResolver);
        console2.log("=====================================");
        console2.log("\nKey Features:");
        console2.log("- Each validator gets their own beacon proxy contract");
        console2.log("- Validator stake and metadata are isolated per validator");
        console2.log("- Upgradeable validator logic through beacon pattern");
        console2.log("- Enhanced metadata support for validator information");
        console2.log("- Top-N validator selection for execution (default: 5)");
        console2.log("- Active validator limit:", ValidatorRegistry(validatorRegistry).activeValidatorLimit());
        console2.log("=====================================");
    }

    function _setupTestValidators(
        GLTToken gltToken,
        ValidatorRegistry validatorRegistry,
        uint256 deployerPrivateKey
    )
        internal
    {
        vm.startBroadcast(deployerPrivateKey);

        address[3] memory testValidators = [TEST_VALIDATOR_1, TEST_VALIDATOR_2, TEST_VALIDATOR_3];

        for (uint256 i = 0; i < TEST_VALIDATOR_COUNT; i++) {
            gltToken.mint(testValidators[i], TEST_VALIDATOR_STAKE);
            console2.log("Minted", TEST_VALIDATOR_STAKE / 1e18, "GLT to validator:", testValidators[i]);
        }

        console2.log("\nTo complete setup, validators need to:");
        console2.log("1. Approve GLT tokens to ValidatorRegistry");
        console2.log("2. Call registerValidator() with their stake");

        for (uint256 i = 0; i < TEST_VALIDATOR_COUNT; i++) {
            console2.log("\nValidator", i + 1, ":", testValidators[i]);
            console2.log("Run these commands:");
            console2.log(
                "cast send <GLT_TOKEN> \"approve(address,uint256)\" <VALIDATOR_REGISTRY> <STAKE_AMOUNT> --private-key <VALIDATOR_PRIVATE_KEY> --rpc-url http://127.0.0.1:8545"
            );
            console2.log(
                "cast send <VALIDATOR_REGISTRY> \"registerValidator(uint256)\" <STAKE_AMOUNT> --private-key <VALIDATOR_PRIVATE_KEY> --rpc-url http://127.0.0.1:8545"
            );
        }

        vm.stopBroadcast();

        console2.log("\n=====================================");
        console2.log("Validator Registry Status:");
        console2.log("=====================================");
        console2.log("Total validators:", validatorRegistry.getTotalValidators());
        console2.log("Total stake:", validatorRegistry.totalStaked() / 1e18, "GLT");
        console2.log("Active validators:", validatorRegistry.getActiveValidators().length);
        console2.log("Max validators:", validatorRegistry.MAX_VALIDATORS());
        console2.log("Minimum stake:", validatorRegistry.MINIMUM_STAKE() / 1e18, "GLT");
        console2.log("=====================================");
    }
}
