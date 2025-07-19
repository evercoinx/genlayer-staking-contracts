// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { GLTToken } from "../../src/GLTToken.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { IValidatorRegistry } from "../../src/interfaces/IValidatorRegistry.sol";
import { IValidator } from "../../src/interfaces/IValidator.sol";

/**
 * @title ValidatorRegistryFuzzTest
 * @dev Fuzz tests for ValidatorRegistry contract with beacon proxy pattern
 */
contract ValidatorRegistryFuzzTest is Test {
    GLTToken public gltToken;
    ValidatorRegistry public registry;
    address public owner = address(this);
    address public slasher = address(0x999);
    
    uint256 constant MINIMUM_STAKE = 1000e18;
    uint256 constant MAX_VALIDATORS = 100;
    uint256 constant SLASH_PERCENTAGE = 10;

    function setUp() public {
        gltToken = new GLTToken(owner);
        registry = new ValidatorRegistry(address(gltToken), owner);
        registry.setSlasher(slasher);
    }

    function _setupValidator(address validator, uint256 stake) internal {
        gltToken.mint(validator, stake);
        vm.prank(validator);
        gltToken.approve(address(registry), stake);
    }

    // Fuzz test: Registration with various stake amounts creates beacon proxies
    function testFuzz_RegisterValidator(address validator, uint256 stake) public {
        // Constraints
        vm.assume(validator != address(0));
        stake = bound(stake, MINIMUM_STAKE, 1_000_000e18);
        
        _setupValidator(validator, stake);
        
        vm.prank(validator);
        registry.registerValidator(stake);
        
        // Verify validator info through registry
        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator);
        assertEq(info.stakedAmount, stake);
        assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Active));
        assertTrue(registry.isActiveValidator(validator));
        
        // Verify beacon proxy was created
        address proxyAddress = registry.getValidatorProxy(validator);
        assertTrue(proxyAddress != address(0));
        
        // Verify proxy holds the tokens
        assertEq(gltToken.balanceOf(proxyAddress), stake);
        
        // Verify proxy has correct validator info
        IValidator validatorProxy = IValidator(proxyAddress);
        IValidator.ValidatorInfo memory proxyInfo = validatorProxy.getValidatorInfo();
        assertEq(proxyInfo.validatorAddress, validator);
        assertEq(proxyInfo.stakedAmount, stake);
    }

    // Fuzz test: Stake increases work through beacon proxy
    function testFuzz_IncreaseStake(uint256 initialStake, uint256 increaseAmount) public {
        // Constraints
        initialStake = bound(initialStake, MINIMUM_STAKE, 100_000e18);
        increaseAmount = bound(increaseAmount, 1, 100_000e18);
        
        address validator = address(0x123);
        
        // Register validator
        _setupValidator(validator, initialStake);
        vm.prank(validator);
        registry.registerValidator(initialStake);
        
        address proxyAddress = registry.getValidatorProxy(validator);
        
        // Increase stake
        gltToken.mint(validator, increaseAmount);
        vm.prank(validator);
        gltToken.approve(address(registry), increaseAmount);
        
        vm.prank(validator);
        registry.increaseStake(increaseAmount);
        
        // Verify stake increased in both registry and proxy
        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator);
        assertEq(info.stakedAmount, initialStake + increaseAmount);
        
        // Verify proxy holds the additional tokens
        assertEq(gltToken.balanceOf(proxyAddress), initialStake + increaseAmount);
    }

    // Fuzz test: Multiple validators creates multiple beacon proxies
    function testFuzz_MultipleValidators(uint8 validatorCount) public {
        // Reduce max validators for faster test execution
        validatorCount = uint8(bound(validatorCount, 1, 5));
        
        for (uint256 i = 0; i < validatorCount; i++) {
            address validator = address(uint160(i + 1));
            uint256 stake = MINIMUM_STAKE + (i * 100e18);
            
            _setupValidator(validator, stake);
            
            vm.prank(validator);
            registry.registerValidator(stake);
            
            // Each validator should have a unique proxy
            address proxyAddress = registry.getValidatorProxy(validator);
            assertTrue(proxyAddress != address(0));
            assertEq(gltToken.balanceOf(proxyAddress), stake);
        }
        
        // Check total validators
        assertEq(registry.getTotalValidators(), validatorCount);
        
        // Active validators should be min(validatorCount, MAX_VALIDATORS)
        uint256 expectedActive = validatorCount > MAX_VALIDATORS ? MAX_VALIDATORS : validatorCount;
        assertEq(registry.getActiveValidators().length, expectedActive);
    }

    // Fuzz test: Slashing works correctly with beacon proxy pattern and 10% maximum
    function testFuzz_SlashValidator(uint256 stake, uint256 requestedSlash) public {
        // Constraints
        stake = bound(stake, MINIMUM_STAKE, 100_000e18);
        requestedSlash = bound(requestedSlash, 1e18, stake * 2); // Use minimum 1 GLT
        
        address validator = address(0x456);
        
        // Register validator
        _setupValidator(validator, stake);
        vm.prank(validator);
        registry.registerValidator(stake);
        
        address proxyAddress = registry.getValidatorProxy(validator);
        
        // Calculate expected slash (ValidatorRegistry enforces 10% maximum)
        uint256 maxSlash = (stake * SLASH_PERCENTAGE) / 100;
        uint256 expectedSlash = requestedSlash < maxSlash ? requestedSlash : maxSlash;
        
        // Slash validator
        vm.prank(slasher);
        registry.slashValidator(validator, requestedSlash, "Fuzz test slash");
        
        // Verify slashing worked correctly
        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator);
        assertEq(info.stakedAmount, stake - expectedSlash);
        
        // Verify proxy still holds original tokens (slashed tokens remain in contract)
        assertEq(gltToken.balanceOf(proxyAddress), stake);
        
        // Check validator status based on remaining stake
        if (stake - expectedSlash >= MINIMUM_STAKE) {
            assertTrue(registry.isActiveValidator(validator));
            assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Active));
        } else {
            assertFalse(registry.isActiveValidator(validator));
            assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Slashed));
        }
    }

    // Fuzz test: Unstaking workflow with beacon proxy
    function testFuzz_UnstakeWorkflow(uint256 stake, uint256 unstakeAmount) public {
        // Constraints
        stake = bound(stake, MINIMUM_STAKE * 2, 100_000e18); // Ensure room for partial unstake
        unstakeAmount = bound(unstakeAmount, 1e18, stake - MINIMUM_STAKE); // Leave at least MINIMUM_STAKE
        
        address validator = address(0x789);
        
        // Register validator
        _setupValidator(validator, stake);
        vm.prank(validator);
        registry.registerValidator(stake);
        
        address proxyAddress = registry.getValidatorProxy(validator);
        
        // Request unstake
        vm.prank(validator);
        registry.requestUnstake(unstakeAmount);
        
        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator);
        IValidator validatorProxy = IValidator(proxyAddress);
        IValidator.ValidatorInfo memory proxyInfo = validatorProxy.getValidatorInfo();
        
        if (stake - unstakeAmount < MINIMUM_STAKE) {
            // Full unstake - validator should be in unstaking state
            assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Unstaking));
            assertEq(uint8(proxyInfo.status), uint8(IValidator.ValidatorStatus.Unstaking));
            assertFalse(registry.isActiveValidator(validator));
        } else {
            // Partial unstake - should remain active
            assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Active));
            assertEq(uint8(proxyInfo.status), uint8(IValidator.ValidatorStatus.Active));
            assertTrue(registry.isActiveValidator(validator));
        }
        
        // Complete unstake after bonding period
        vm.roll(block.number + 1); // 1 block bonding period per PRD
        
        uint256 balanceBefore = gltToken.balanceOf(validator);
        uint256 proxyBalanceBefore = gltToken.balanceOf(proxyAddress);
        
        vm.prank(validator);
        registry.completeUnstake();
        
        uint256 balanceAfter = gltToken.balanceOf(validator);
        uint256 proxyBalanceAfter = gltToken.balanceOf(proxyAddress);
        
        // Validator should receive the unstaked tokens
        assertEq(balanceAfter - balanceBefore, unstakeAmount);
        // Proxy should have less tokens
        assertEq(proxyBalanceBefore - proxyBalanceAfter, unstakeAmount);
    }

    // Fuzz test: Validator set ordering with beacon proxies
    function testFuzz_ValidatorSetOrdering(uint256[3] memory stakes) public {
        // Reduce to 3 validators for faster execution
        address[] memory validators = new address[](3);
        uint256 validCount = 0;
        
        for (uint256 i = 0; i < 3; i++) {
            stakes[i] = bound(stakes[i], MINIMUM_STAKE, 100_000e18);
            
            validators[i] = address(uint160(i + 100));
            _setupValidator(validators[i], stakes[i]);
            
            vm.prank(validators[i]);
            registry.registerValidator(stakes[i]);
            validCount++;
        }
        
        // Get active validators
        address[] memory activeValidators = registry.getActiveValidators();
        
        // Verify ordering - higher stakes should come first
        for (uint256 i = 1; i < activeValidators.length; i++) {
            IValidatorRegistry.ValidatorInfo memory prev = registry.getValidatorInfo(activeValidators[i-1]);
            IValidatorRegistry.ValidatorInfo memory curr = registry.getValidatorInfo(activeValidators[i]);
            assertGe(prev.stakedAmount, curr.stakedAmount);
        }
        
        // Verify all validators have beacon proxies
        for (uint256 i = 0; i < activeValidators.length; i++) {
            address proxyAddress = registry.getValidatorProxy(activeValidators[i]);
            assertTrue(proxyAddress != address(0));
        }
    }

    // Fuzz test: Beacon proxy integrity through operations
    function testFuzz_BeaconProxyIntegrity(
        uint256 initialStake,
        uint256 increaseAmount,
        uint256 slashAmount
    ) public {
        // Constraints
        initialStake = bound(initialStake, MINIMUM_STAKE, 50_000e18);
        increaseAmount = bound(increaseAmount, 1e18, 50_000e18); // Use minimum 1 GLT
        slashAmount = bound(slashAmount, 1e18, 10_000e18); // Use minimum 1 GLT
        
        address validator = address(0xABC);
        
        // Register validator
        _setupValidator(validator, initialStake);
        vm.prank(validator);
        registry.registerValidator(initialStake);
        
        address proxyAddress = registry.getValidatorProxy(validator);
        IValidator validatorProxy = IValidator(proxyAddress);
        
        // Verify initial state
        assertEq(gltToken.balanceOf(proxyAddress), initialStake);
        assertEq(validatorProxy.getStakedAmount(), initialStake);
        
        // Increase stake
        gltToken.mint(validator, increaseAmount);
        vm.prank(validator);
        gltToken.approve(address(registry), increaseAmount);
        vm.prank(validator);
        registry.increaseStake(increaseAmount);
        
        uint256 totalStake = initialStake + increaseAmount;
        
        // Verify proxy state after increase
        assertEq(gltToken.balanceOf(proxyAddress), totalStake);
        assertEq(validatorProxy.getStakedAmount(), totalStake);
        
        // Slash validator (limited to 10% of total stake)
        uint256 maxSlash = (totalStake * SLASH_PERCENTAGE) / 100;
        uint256 expectedSlash = slashAmount < maxSlash ? slashAmount : maxSlash;
        
        vm.prank(slasher);
        registry.slashValidator(validator, slashAmount, "Integrity test");
        
        uint256 finalStake = totalStake - expectedSlash;
        
        // Verify proxy state after slash (tokens stay in contract, but staked amount decreases)
        assertEq(gltToken.balanceOf(proxyAddress), totalStake); // Tokens remain in contract
        assertEq(validatorProxy.getStakedAmount(), finalStake); // But staked amount is reduced
        
        // Verify registry and proxy are in sync
        IValidatorRegistry.ValidatorInfo memory registryInfo = registry.getValidatorInfo(validator);
        IValidator.ValidatorInfo memory proxyInfo = validatorProxy.getValidatorInfo();
        
        assertEq(registryInfo.stakedAmount, proxyInfo.stakedAmount);
        assertEq(uint8(registryInfo.status), uint8(proxyInfo.status));
        assertEq(registryInfo.validatorAddress, proxyInfo.validatorAddress);
    }
}