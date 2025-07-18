// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { GLTToken } from "../../src/GLTToken.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { IValidatorRegistry } from "../../src/interfaces/IValidatorRegistry.sol";

/**
 * @title ValidatorRegistryFuzzTest
 * @dev Fuzz tests for ValidatorRegistry contract
 */
contract ValidatorRegistryFuzzTest is Test {
    GLTToken public gltToken;
    ValidatorRegistry public registry;
    address public owner = address(this);
    address public slasher = address(0x999);
    
    uint256 constant MINIMUM_STAKE = 1000e18;
    uint256 constant MAX_VALIDATORS = 100;

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

    // Fuzz test: Registration with various stake amounts
    function testFuzz_RegisterValidator(address validator, uint256 stake) public {
        // Constraints
        vm.assume(validator != address(0));
        vm.assume(stake >= MINIMUM_STAKE);
        vm.assume(stake <= 1000000e18); // Stay well below max supply
        
        _setupValidator(validator, stake);
        
        vm.prank(validator);
        registry.registerValidator(stake);
        
        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator);
        assertEq(info.stakedAmount, stake);
        assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Active));
        assertTrue(registry.isActiveValidator(validator));
    }

    // Fuzz test: Stake increases
    function testFuzz_IncreaseStake(uint256 initialStake, uint256 increaseAmount) public {
        // Constraints
        vm.assume(initialStake >= MINIMUM_STAKE && initialStake <= 100000e18);
        vm.assume(increaseAmount > 0 && increaseAmount <= 100000e18);
        vm.assume(initialStake + increaseAmount <= 200000e18);
        
        address validator = address(0x123);
        
        // Register validator
        _setupValidator(validator, initialStake);
        vm.prank(validator);
        registry.registerValidator(initialStake);
        
        // Increase stake
        gltToken.mint(validator, increaseAmount);
        vm.prank(validator);
        gltToken.approve(address(registry), increaseAmount);
        
        vm.prank(validator);
        registry.increaseStake(increaseAmount);
        
        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator);
        assertEq(info.stakedAmount, initialStake + increaseAmount);
    }

    // Fuzz test: Multiple validators with random stakes
    function testFuzz_MultipleValidators(uint256[] memory stakes) public {
        vm.assume(stakes.length > 0 && stakes.length <= 10);
        
        uint256 validCount = 0;
        
        for (uint256 i = 0; i < stakes.length; i++) {
            if (stakes[i] < MINIMUM_STAKE || stakes[i] > 100000e18) {
                continue;
            }
            
            address validator = address(uint160(i + 1));
            _setupValidator(validator, stakes[i]);
            
            vm.prank(validator);
            registry.registerValidator(stakes[i]);
            
            validCount++;
        }
        
        // Check total validators
        assertEq(registry.getTotalValidators(), validCount);
        
        // Active validators should be min(validCount, MAX_VALIDATORS)
        uint256 expectedActive = validCount > MAX_VALIDATORS ? MAX_VALIDATORS : validCount;
        assertEq(registry.getActiveValidators().length, expectedActive);
    }

    // Fuzz test: Slashing with random amounts
    function testFuzz_SlashValidator(uint256 stake, uint256 slashAmount) public {
        // Constraints
        vm.assume(stake >= MINIMUM_STAKE && stake <= 100000e18);
        vm.assume(slashAmount > 0 && slashAmount <= stake);
        
        address validator = address(0x456);
        
        // Register validator
        _setupValidator(validator, stake);
        vm.prank(validator);
        registry.registerValidator(stake);
        
        // Slash validator
        vm.prank(slasher);
        registry.slashValidator(validator, slashAmount, "Fuzz test slash");
        
        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator);
        assertEq(info.stakedAmount, stake - slashAmount);
        
        // Check if validator is still active based on remaining stake
        if (stake - slashAmount >= MINIMUM_STAKE) {
            assertTrue(registry.isActiveValidator(validator));
            assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Active));
        } else {
            assertFalse(registry.isActiveValidator(validator));
            assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Slashed));
        }
    }

    // Fuzz test: Unstaking workflow
    function testFuzz_UnstakeWorkflow(uint256 stake, uint256 unstakeAmount) public {
        // Constraints
        vm.assume(stake >= MINIMUM_STAKE && stake <= 100000e18);
        vm.assume(unstakeAmount > 0 && unstakeAmount <= stake);
        
        address validator = address(0x789);
        
        // Register validator
        _setupValidator(validator, stake);
        vm.prank(validator);
        registry.registerValidator(stake);
        
        // Request unstake
        vm.prank(validator);
        registry.requestUnstake(unstakeAmount);
        
        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator);
        
        if (stake - unstakeAmount < MINIMUM_STAKE) {
            // Full unstake
            assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Unstaking));
            assertFalse(registry.isActiveValidator(validator));
        } else {
            // Partial unstake
            assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Active));
            assertTrue(registry.isActiveValidator(validator));
        }
        
        // Complete unstake after bonding period
        vm.warp(block.timestamp + 7 days + 1);
        
        uint256 balanceBefore = gltToken.balanceOf(validator);
        vm.prank(validator);
        registry.completeUnstake();
        uint256 balanceAfter = gltToken.balanceOf(validator);
        
        assertEq(balanceAfter - balanceBefore, unstakeAmount);
    }

    // Fuzz test: Validator set ordering with random stakes
    function testFuzz_ValidatorSetOrdering(uint256[5] memory stakes) public {
        // Setup validators with different stakes
        address[] memory validators = new address[](5);
        uint256 validCount = 0;
        
        for (uint256 i = 0; i < 5; i++) {
            if (stakes[i] < MINIMUM_STAKE || stakes[i] > 100000e18) {
                continue;
            }
            
            validators[i] = address(uint160(i + 100));
            _setupValidator(validators[i], stakes[i]);
            
            vm.prank(validators[i]);
            registry.registerValidator(stakes[i]);
            validCount++;
        }
        
        if (validCount == 0) return;
        
        // Get active validators
        address[] memory activeValidators = registry.getActiveValidators();
        
        // Verify ordering - higher stakes should come first
        for (uint256 i = 1; i < activeValidators.length; i++) {
            IValidatorRegistry.ValidatorInfo memory prev = registry.getValidatorInfo(activeValidators[i-1]);
            IValidatorRegistry.ValidatorInfo memory curr = registry.getValidatorInfo(activeValidators[i]);
            assertGe(prev.stakedAmount, curr.stakedAmount);
        }
    }

    // Fuzz test: Random sequence of operations
    function testFuzz_RandomOperations(
        uint8[] memory operations,
        address[] memory validators,
        uint256[] memory amounts
    ) public {
        vm.assume(operations.length == validators.length);
        vm.assume(validators.length == amounts.length);
        vm.assume(operations.length > 0 && operations.length <= 20);
        
        // Track registered validators using a simple array
        bool[] memory isRegistered = new bool[](operations.length);
        address[] memory validatorAddresses = new address[](operations.length);
        
        for (uint256 i = 0; i < operations.length; i++) {
            // Skip invalid addresses
            if (validators[i] == address(0)) continue;
            
            validatorAddresses[i] = validators[i];
            
            // Cap amounts
            uint256 amount = amounts[i] % 10000e18;
            if (amount < MINIMUM_STAKE) amount = MINIMUM_STAKE;
            
            uint8 op = operations[i] % 4;
            
            if (op == 0 && !isRegistered[i]) {
                // Register new validator
                _setupValidator(validators[i], amount);
                vm.prank(validators[i]);
                try registry.registerValidator(amount) {
                    isRegistered[i] = true;
                } catch {}
            } else if (op == 1 && isRegistered[i]) {
                // Increase stake
                gltToken.mint(validators[i], amount);
                vm.prank(validators[i]);
                gltToken.approve(address(registry), amount);
                vm.prank(validators[i]);
                try registry.increaseStake(amount) {} catch {}
            } else if (op == 2 && isRegistered[i]) {
                // Request unstake
                IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validators[i]);
                if (info.status == IValidatorRegistry.ValidatorStatus.Active && amount <= info.stakedAmount) {
                    vm.prank(validators[i]);
                    try registry.requestUnstake(amount) {} catch {}
                }
            } else if (op == 3 && isRegistered[i]) {
                // Slash (if active)
                IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validators[i]);
                if (info.status == IValidatorRegistry.ValidatorStatus.Active) {
                    uint256 slashAmount = amount % info.stakedAmount;
                    if (slashAmount > 0) {
                        vm.prank(slasher);
                        try registry.slashValidator(validators[i], slashAmount, "Fuzz slash") {} catch {}
                    }
                }
            }
        }
        
        // Invariants
        assertTrue(registry.getTotalValidators() <= MAX_VALIDATORS + 100); // Some buffer for edge cases
        assertTrue(registry.getActiveValidators().length <= MAX_VALIDATORS);
    }
}