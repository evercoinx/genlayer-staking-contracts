// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { console2 } from "@forge-std/console2.sol";
import { Script } from "@forge-std/Script.sol";
import { GLTToken } from "../src/GLTToken.sol";
import { ValidatorRegistry } from "../src/ValidatorRegistry.sol";
import { MockLLMOracle } from "../src/MockLLMOracle.sol";
import { ProposalManager } from "../src/ProposalManager.sol";
import { ConsensusEngine } from "../src/ConsensusEngine.sol";
import { DisputeResolver } from "../src/DisputeResolver.sol";

/**
 * @title Deploy
 * @dev Deployment script for the GenLayer consensus system contracts.
 * Run with: forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
 */
contract Deploy is Script {
    // Initial supply of GLT tokens (100 million)
    uint256 constant INITIAL_GLT_SUPPLY = 100_000_000e18;

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        address deployer = vm.addr(deployerPrivateKey);
        
        console2.log("Deploying GenLayer contracts...");
        console2.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy GLT Token
        GLTToken gltToken = new GLTToken(deployer);
        console2.log("GLTToken deployed at:", address(gltToken));

        // 2. Deploy MockLLMOracle
        MockLLMOracle llmOracle = new MockLLMOracle();
        console2.log("MockLLMOracle deployed at:", address(llmOracle));

        // 3. Deploy ValidatorRegistry
        ValidatorRegistry validatorRegistry = new ValidatorRegistry(
            address(gltToken),
            deployer // slasher role initially set to deployer
        );
        console2.log("ValidatorRegistry deployed at:", address(validatorRegistry));

        // 4. Deploy ProposalManager
        ProposalManager proposalManager = new ProposalManager(
            address(validatorRegistry),
            address(llmOracle),
            deployer // proposal manager role initially set to deployer
        );
        console2.log("ProposalManager deployed at:", address(proposalManager));

        // 5. Deploy ConsensusEngine
        ConsensusEngine consensusEngine = new ConsensusEngine(
            address(validatorRegistry),
            address(proposalManager),
            deployer // consensus initiator role initially set to deployer
        );
        console2.log("ConsensusEngine deployed at:", address(consensusEngine));

        // 6. Deploy DisputeResolver
        DisputeResolver disputeResolver = new DisputeResolver(
            address(gltToken),
            address(validatorRegistry),
            address(proposalManager)
        );
        console2.log("DisputeResolver deployed at:", address(disputeResolver));

        // 7. Initial GLT minting
        gltToken.mint(deployer, INITIAL_GLT_SUPPLY);
        console2.log("Minted", INITIAL_GLT_SUPPLY / 1e18, "GLT tokens to deployer");

        // 8. Update slasher role in ValidatorRegistry to DisputeResolver
        validatorRegistry.setSlasher(address(disputeResolver));
        console2.log("Updated ValidatorRegistry slasher to DisputeResolver");

        vm.stopBroadcast();

        console2.log("\nDeployment complete!");
        console2.log("=====================================");
        console2.log("GLTToken:", address(gltToken));
        console2.log("MockLLMOracle:", address(llmOracle));
        console2.log("ValidatorRegistry:", address(validatorRegistry));
        console2.log("ProposalManager:", address(proposalManager));
        console2.log("ConsensusEngine:", address(consensusEngine));
        console2.log("DisputeResolver:", address(disputeResolver));
        console2.log("=====================================");
    }
}