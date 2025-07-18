// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { IValidatorRegistry } from "../../src/interfaces/IValidatorRegistry.sol";
import { GLTToken } from "../../src/GLTToken.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ValidatorRegistryTest
 * @dev Test suite for ValidatorRegistry contract.
 */
contract ValidatorRegistryTest is Test {
    ValidatorRegistry public registry;
    GLTToken public gltToken;
    
    address public deployer = address(this);
    address public slasher = address(0x1);
    address public validator1 = address(0x2);
    address public validator2 = address(0x3);
    address public validator3 = address(0x4);
    
    uint256 constant MINIMUM_STAKE = 1000e18;
    uint256 constant BONDING_PERIOD = 7 days;
    uint256 constant MAX_VALIDATORS = 100;

    event ValidatorRegistered(address indexed validator, uint256 stakedAmount);
    event StakeIncreased(address indexed validator, uint256 additionalStake, uint256 newTotalStake);
    event UnstakeRequested(address indexed validator, uint256 unstakeAmount, uint256 unstakeRequestTime);
    event UnstakeCompleted(address indexed validator, uint256 unstakedAmount);
    event ValidatorSlashed(address indexed validator, uint256 slashedAmount, string reason);
    event ActiveValidatorSetUpdated(address[] validators, uint256 blockNumber);

    function setUp() public {
        // Deploy GLT token
        gltToken = new GLTToken(deployer);
        
        // Deploy ValidatorRegistry
        registry = new ValidatorRegistry(address(gltToken), slasher);
        
        // Mint tokens to validators
        gltToken.mint(validator1, 10_000e18);
        gltToken.mint(validator2, 10_000e18);
        gltToken.mint(validator3, 10_000e18);
        
        // Approve registry to spend tokens
        vm.prank(validator1);
        gltToken.approve(address(registry), type(uint256).max);
        
        vm.prank(validator2);
        gltToken.approve(address(registry), type(uint256).max);
        
        vm.prank(validator3);
        gltToken.approve(address(registry), type(uint256).max);
    }

    // Registration Tests
    function test_RegisterValidator_Success() public {
        uint256 stakeAmount = 2000e18;
        
        vm.expectEmit(true, false, false, true);
        emit ValidatorRegistered(validator1, stakeAmount);
        
        vm.prank(validator1);
        registry.registerValidator(stakeAmount);
        
        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator1);
        
        assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Active), "Validator should be active");
        assertEq(info.stakedAmount, stakeAmount, "Stake amount incorrect");
        assertEq(info.activationTime, block.timestamp, "Activation time incorrect");
        assertEq(info.unstakeRequestTime, 0, "Unstake request time should be 0");
        assertEq(registry.getTotalValidators(), 1, "Total validators incorrect");
        assertEq(registry.getTotalStake(), stakeAmount, "Total stake incorrect");
    }

    function test_RegisterValidator_RevertIfAlreadyRegistered() public {
        vm.prank(validator1);
        registry.registerValidator(MINIMUM_STAKE);
        
        vm.expectRevert(IValidatorRegistry.ValidatorAlreadyRegistered.selector);
        vm.prank(validator1);
        registry.registerValidator(MINIMUM_STAKE);
    }

    function test_RegisterValidator_RevertIfInsufficientStake() public {
        uint256 insufficientStake = MINIMUM_STAKE - 1;
        
        vm.expectRevert(IValidatorRegistry.InsufficientStake.selector);
        vm.prank(validator1);
        registry.registerValidator(insufficientStake);
    }

    // Stake Management Tests
    function test_IncreaseStake_Success() public {
        uint256 initialStake = MINIMUM_STAKE;
        uint256 additionalStake = 500e18;
        
        vm.prank(validator1);
        registry.registerValidator(initialStake);
        
        vm.expectEmit(true, false, false, true);
        emit StakeIncreased(validator1, additionalStake, initialStake + additionalStake);
        
        vm.prank(validator1);
        registry.increaseStake(additionalStake);
        
        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator1);
        assertEq(info.stakedAmount, initialStake + additionalStake, "Stake not increased");
        assertEq(registry.getTotalStake(), initialStake + additionalStake, "Total stake incorrect");
    }

    function test_IncreaseStake_RevertIfNotRegistered() public {
        vm.expectRevert(IValidatorRegistry.ValidatorNotFound.selector);
        vm.prank(validator1);
        registry.increaseStake(100e18);
    }

    function test_IncreaseStake_RevertIfZeroAmount() public {
        vm.prank(validator1);
        registry.registerValidator(MINIMUM_STAKE);
        
        vm.expectRevert(IValidatorRegistry.ZeroAmount.selector);
        vm.prank(validator1);
        registry.increaseStake(0);
    }

    // Unstaking Tests
    function test_RequestUnstake_FullAmount() public {
        uint256 stakeAmount = 2000e18;
        
        vm.prank(validator1);
        registry.registerValidator(stakeAmount);
        
        vm.expectEmit(true, false, false, true);
        emit UnstakeRequested(validator1, stakeAmount, block.timestamp);
        
        vm.prank(validator1);
        registry.requestUnstake(stakeAmount);
        
        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator1);
        assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Unstaking), "Should be unstaking");
        assertEq(info.unstakeRequestTime, block.timestamp, "Unstake request time incorrect");
    }

    function test_RequestUnstake_PartialAmount() public {
        uint256 stakeAmount = 2000e18;
        uint256 unstakeAmount = 500e18;
        
        vm.prank(validator1);
        registry.registerValidator(stakeAmount);
        
        vm.expectEmit(true, false, false, true);
        emit UnstakeRequested(validator1, unstakeAmount, block.timestamp);
        
        vm.prank(validator1);
        registry.requestUnstake(unstakeAmount);
        
        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator1);
        assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Active), "Should still be active");
        assertEq(info.unstakeRequestTime, block.timestamp, "Unstake request time incorrect");
    }

    function test_RequestUnstake_RevertIfBelowMinimum() public {
        uint256 stakeAmount = 1500e18;
        uint256 unstakeAmount = 600e18; // Would leave 900 GLT, below minimum
        
        vm.prank(validator1);
        registry.registerValidator(stakeAmount);
        
        vm.expectRevert(IValidatorRegistry.InsufficientStake.selector);
        vm.prank(validator1);
        registry.requestUnstake(unstakeAmount);
    }

    function test_RequestUnstake_RevertIfExceedsStake() public {
        uint256 stakeAmount = 1000e18;
        
        vm.prank(validator1);
        registry.registerValidator(stakeAmount);
        
        vm.expectRevert(IValidatorRegistry.UnstakeExceedsStake.selector);
        vm.prank(validator1);
        registry.requestUnstake(stakeAmount + 1);
    }

    function test_CompleteUnstake_Success() public {
        uint256 stakeAmount = 2000e18;
        
        // Register and request unstake
        vm.prank(validator1);
        registry.registerValidator(stakeAmount);
        
        vm.prank(validator1);
        registry.requestUnstake(stakeAmount);
        
        // Warp past bonding period
        vm.warp(block.timestamp + BONDING_PERIOD + 1);
        
        uint256 balanceBefore = gltToken.balanceOf(validator1);
        
        vm.expectEmit(true, false, false, true);
        emit UnstakeCompleted(validator1, stakeAmount);
        
        vm.prank(validator1);
        registry.completeUnstake();
        
        uint256 balanceAfter = gltToken.balanceOf(validator1);
        assertEq(balanceAfter - balanceBefore, stakeAmount, "Stake not returned");
        
        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator1);
        assertEq(info.stakedAmount, 0, "Stake should be 0");
        assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Inactive), "Should be inactive");
    }

    function test_CompleteUnstake_RevertIfBondingPeriodNotMet() public {
        uint256 stakeAmount = 2000e18;
        
        vm.prank(validator1);
        registry.registerValidator(stakeAmount);
        
        vm.prank(validator1);
        registry.requestUnstake(stakeAmount);
        
        // Try to complete before bonding period
        vm.warp(block.timestamp + BONDING_PERIOD - 1);
        
        vm.expectRevert(IValidatorRegistry.BondingPeriodNotMet.selector);
        vm.prank(validator1);
        registry.completeUnstake();
    }

    function test_CompleteUnstake_RevertIfNotUnstaking() public {
        vm.prank(validator1);
        registry.registerValidator(MINIMUM_STAKE);
        
        vm.expectRevert(IValidatorRegistry.InvalidValidatorStatus.selector);
        vm.prank(validator1);
        registry.completeUnstake();
    }

    // Slashing Tests
    function test_SlashValidator_Success() public {
        uint256 stakeAmount = 2000e18;
        uint256 slashAmount = 200e18;
        string memory reason = "Misbehavior";
        
        vm.prank(validator1);
        registry.registerValidator(stakeAmount);
        
        vm.expectEmit(true, false, false, true);
        emit ValidatorSlashed(validator1, slashAmount, reason);
        
        vm.prank(slasher);
        registry.slashValidator(validator1, slashAmount, reason);
        
        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator1);
        assertEq(info.stakedAmount, stakeAmount - slashAmount, "Stake not slashed");
        assertEq(registry.getTotalStake(), stakeAmount - slashAmount, "Total stake incorrect");
    }

    function test_SlashValidator_RevertIfUnauthorized() public {
        vm.prank(validator1);
        registry.registerValidator(MINIMUM_STAKE);
        
        vm.expectRevert("ValidatorRegistry: caller is not the slasher");
        vm.prank(validator2);
        registry.slashValidator(validator1, 100e18, "Unauthorized slash");
    }

    function test_SlashValidator_DeactivatesIfBelowMinimum() public {
        uint256 stakeAmount = MINIMUM_STAKE;
        uint256 slashAmount = 100e18;
        
        vm.prank(validator1);
        registry.registerValidator(stakeAmount);
        
        vm.prank(slasher);
        registry.slashValidator(validator1, slashAmount, "Large slash");
        
        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator1);
        assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Slashed), "Should be slashed");
        assertEq(info.stakedAmount, stakeAmount - slashAmount, "Stake calculation incorrect");
    }

    function test_SlashValidator_CapsAtFullStake() public {
        uint256 stakeAmount = 1000e18;
        uint256 slashAmount = 2000e18; // More than staked
        
        vm.prank(validator1);
        registry.registerValidator(stakeAmount);
        
        vm.prank(slasher);
        registry.slashValidator(validator1, slashAmount, "Excessive slash");
        
        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator1);
        assertEq(info.stakedAmount, 0, "Stake should be 0");
        assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Slashed), "Should be slashed");
    }

    // Admin Tests
    function test_SetSlasher_Success() public {
        address newSlasher = address(0x999);
        
        registry.setSlasher(newSlasher);
        
        assertEq(registry.slasher(), newSlasher, "Slasher not updated");
    }

    function test_SetSlasher_RevertIfUnauthorized() public {
        vm.expectRevert();
        vm.prank(validator1);
        registry.setSlasher(address(0x999));
    }

    function test_SetSlasher_RevertIfZeroAddress() public {
        vm.expectRevert(IValidatorRegistry.ZeroAddress.selector);
        registry.setSlasher(address(0));
    }

    // View Functions Tests
    function test_GetMinimumStake() public view {
        assertEq(registry.getMinimumStake(), MINIMUM_STAKE);
    }

    function test_GetBondingPeriod() public view {
        assertEq(registry.getBondingPeriod(), BONDING_PERIOD);
    }

    function test_GetMaxValidators() public view {
        assertEq(registry.getMaxValidators(), MAX_VALIDATORS);
    }

    function test_IsActiveValidator() public {
        assertFalse(registry.isActiveValidator(validator1));
        
        vm.prank(validator1);
        registry.registerValidator(MINIMUM_STAKE);
        
        assertTrue(registry.isActiveValidator(validator1));
        
        vm.prank(validator1);
        registry.requestUnstake(MINIMUM_STAKE);
        
        assertFalse(registry.isActiveValidator(validator1));
    }

    function test_GetActiveValidators() public {
        // Register multiple validators
        vm.prank(validator1);
        registry.registerValidator(3000e18);
        
        vm.prank(validator2);
        registry.registerValidator(2000e18);
        
        vm.prank(validator3);
        registry.registerValidator(1000e18);
        
        address[] memory activeValidators = registry.getActiveValidators();
        assertEq(activeValidators.length, 3, "Should have 3 active validators");
        
        // Validators should be sorted by stake (highest first)
        assertEq(activeValidators[0], validator1);
        assertEq(activeValidators[1], validator2);
        assertEq(activeValidators[2], validator3);
    }

    function test_UpdateActiveValidatorSet() public {
        // This tests the maximum validator limit
        uint256 validatorCount = 10;
        
        // Register validators
        for (uint256 i = 0; i < validatorCount; i++) {
            address validator = address(uint160(0x1000 + i));
            gltToken.mint(validator, MINIMUM_STAKE * 2);
            
            vm.prank(validator);
            gltToken.approve(address(registry), MINIMUM_STAKE * 2);
            
            vm.prank(validator);
            registry.registerValidator(MINIMUM_STAKE + (i * 100e18));
        }
        
        // Check active set
        address[] memory activeValidators = registry.getActiveValidators();
        assertEq(activeValidators.length, validatorCount);
        
        // Call update explicitly
        registry.updateActiveValidatorSet();
        
        // Verify event was emitted
        vm.expectEmit(false, false, false, true);
        emit ActiveValidatorSetUpdated(activeValidators, block.number);
        registry.updateActiveValidatorSet();
    }

    // Multi-validator Tests
    function test_MaximumValidators_ReachedLimit() public {
        // Register exactly MAX_VALIDATORS
        for (uint256 i = 0; i < MAX_VALIDATORS; i++) {
            address validator = address(uint160(0x1000 + i));
            gltToken.mint(validator, MINIMUM_STAKE);
            
            vm.prank(validator);
            gltToken.approve(address(registry), MINIMUM_STAKE);
            
            vm.prank(validator);
            registry.registerValidator(MINIMUM_STAKE);
        }
        
        assertEq(registry.getActiveValidators().length, MAX_VALIDATORS);
        
        // Try to register one more with higher stake
        address extraValidator = address(0x9999);
        gltToken.mint(extraValidator, MINIMUM_STAKE * 2);
        
        vm.prank(extraValidator);
        gltToken.approve(address(registry), MINIMUM_STAKE * 2);
        
        // Should succeed but only top MAX_VALIDATORS should be active
        vm.prank(extraValidator);
        registry.registerValidator(MINIMUM_STAKE * 2);
        
        // Active set should still be MAX_VALIDATORS
        assertEq(registry.getActiveValidators().length, MAX_VALIDATORS);
        
        // The new validator with higher stake should be in the active set
        assertTrue(registry.isActiveValidator(extraValidator));
    }

    // Fuzz Tests
    function testFuzz_RegisterValidator(uint256 stakeAmount) public {
        // Bound the stake amount to reasonable values
        stakeAmount = bound(stakeAmount, MINIMUM_STAKE, 10_000e18);
        
        gltToken.mint(validator1, stakeAmount);
        vm.prank(validator1);
        gltToken.approve(address(registry), stakeAmount);
        
        vm.prank(validator1);
        registry.registerValidator(stakeAmount);
        
        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator1);
        assertEq(info.stakedAmount, stakeAmount);
    }

    function testFuzz_SlashValidator(uint256 initialStake, uint256 slashAmount) public {
        // Bound the stake and slash amounts
        initialStake = bound(initialStake, MINIMUM_STAKE, 10_000e18);
        slashAmount = bound(slashAmount, 1, initialStake * 2);
        
        gltToken.mint(validator1, initialStake);
        vm.prank(validator1);
        gltToken.approve(address(registry), initialStake);
        
        vm.prank(validator1);
        registry.registerValidator(initialStake);
        
        vm.prank(slasher);
        registry.slashValidator(validator1, slashAmount, "Fuzz slash");
        
        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator1);
        
        uint256 expectedStake = slashAmount > initialStake ? 0 : initialStake - slashAmount;
        assertEq(info.stakedAmount, expectedStake);
        
        if (expectedStake < MINIMUM_STAKE) {
            assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Slashed));
        } else {
            assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Active));
        }
    }
}