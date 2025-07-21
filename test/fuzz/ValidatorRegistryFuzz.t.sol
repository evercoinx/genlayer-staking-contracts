// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { IValidatorRegistry } from "../../src/interfaces/IValidatorRegistry.sol";
import { IValidator } from "../../src/interfaces/IValidator.sol";
import { GLTToken } from "../../src/GLTToken.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";

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
        registry = new ValidatorRegistry(address(gltToken), owner, 5);
        registry.setSlasher(slasher);
    }

    function _setupValidator(address validator, uint256 stake) internal {
        gltToken.mint(validator, stake);
        vm.prank(validator);
        gltToken.approve(address(registry), stake);
    }

    function testFuzz_RegisterValidator(address validator, uint256 stake) public {
        vm.assume(validator != address(0));
        stake = bound(stake, MINIMUM_STAKE, 1_000_000e18);

        _setupValidator(validator, stake);

        vm.prank(validator);
        registry.registerValidator(stake);

        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator);
        assertEq(info.stakedAmount, stake);
        assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Active));
        assertTrue(registry.isActiveValidator(validator));

        address proxyAddress = registry.getValidatorProxy(validator);
        assertTrue(proxyAddress != address(0));

        assertEq(gltToken.balanceOf(proxyAddress), stake);

        IValidator validatorProxy = IValidator(proxyAddress);
        IValidator.ValidatorInfo memory proxyInfo = validatorProxy.getValidatorInfo();
        assertEq(proxyInfo.validatorAddress, validator);
        assertEq(proxyInfo.stakedAmount, stake);
    }

    function testFuzz_IncreaseStake(uint256 initialStake, uint256 increaseAmount) public {
        initialStake = bound(initialStake, MINIMUM_STAKE, 100_000e18);
        increaseAmount = bound(increaseAmount, 1, 100_000e18);

        address validator = address(0x123);

        _setupValidator(validator, initialStake);
        vm.prank(validator);
        registry.registerValidator(initialStake);

        address proxyAddress = registry.getValidatorProxy(validator);

        gltToken.mint(validator, increaseAmount);
        vm.prank(validator);
        gltToken.approve(address(registry), increaseAmount);

        vm.prank(validator);
        registry.increaseStake(increaseAmount);

        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator);
        assertEq(info.stakedAmount, initialStake + increaseAmount);

        assertEq(gltToken.balanceOf(proxyAddress), initialStake + increaseAmount);
    }

    function testFuzz_MultipleValidators(uint8 validatorCount) public {
        validatorCount = uint8(bound(validatorCount, 1, 5));

        for (uint256 i = 0; i < validatorCount; ++i) {
            address validator = address(uint160(i + 1));
            uint256 stake = MINIMUM_STAKE + (i * 100e18);

            _setupValidator(validator, stake);

            vm.prank(validator);
            registry.registerValidator(stake);

            address proxyAddress = registry.getValidatorProxy(validator);
            assertTrue(proxyAddress != address(0));
            assertEq(gltToken.balanceOf(proxyAddress), stake);
        }

        assertEq(registry.getTotalValidators(), validatorCount);

        uint256 expectedActive = validatorCount > MAX_VALIDATORS ? MAX_VALIDATORS : validatorCount;
        assertEq(registry.getActiveValidators().length, expectedActive);
    }

    function testFuzz_SlashValidator(uint256 stake, uint256 requestedSlash) public {
        stake = bound(stake, MINIMUM_STAKE, 100_000e18);
        requestedSlash = bound(requestedSlash, 1e18, stake * 2);

        address validator = address(0x456);

        _setupValidator(validator, stake);
        vm.prank(validator);
        registry.registerValidator(stake);

        address proxyAddress = registry.getValidatorProxy(validator);

        uint256 maxSlash = (stake * SLASH_PERCENTAGE) / 100;
        uint256 expectedSlash = requestedSlash < maxSlash ? requestedSlash : maxSlash;

        vm.prank(slasher);
        registry.slashValidator(validator, requestedSlash, "Fuzz test slash");

        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator);
        assertEq(info.stakedAmount, stake - expectedSlash);

        assertEq(gltToken.balanceOf(proxyAddress), stake);

        if (stake - expectedSlash >= MINIMUM_STAKE) {
            assertTrue(registry.isActiveValidator(validator));
            assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Active));
        } else {
            assertFalse(registry.isActiveValidator(validator));
            assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Slashed));
        }
    }

    function testFuzz_UnstakeWorkflow(uint256 stake, uint256 unstakeAmount) public {
        stake = bound(stake, MINIMUM_STAKE * 2, 100_000e18);
        unstakeAmount = bound(unstakeAmount, 1e18, stake - MINIMUM_STAKE);

        address validator = address(0x789);

        _setupValidator(validator, stake);
        vm.prank(validator);
        registry.registerValidator(stake);

        address proxyAddress = registry.getValidatorProxy(validator);

        vm.prank(validator);
        registry.requestUnstake(unstakeAmount);

        IValidatorRegistry.ValidatorInfo memory info = registry.getValidatorInfo(validator);
        IValidator validatorProxy = IValidator(proxyAddress);
        IValidator.ValidatorInfo memory proxyInfo = validatorProxy.getValidatorInfo();

        if (stake - unstakeAmount < MINIMUM_STAKE) {
            assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Unstaking));
            assertEq(uint8(proxyInfo.status), uint8(IValidator.ValidatorStatus.Unstaking));
            assertFalse(registry.isActiveValidator(validator));
        } else {
            assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Active));
            assertEq(uint8(proxyInfo.status), uint8(IValidator.ValidatorStatus.Active));
            assertTrue(registry.isActiveValidator(validator));
        }

        vm.roll(block.number + 1);

        uint256 balanceBefore = gltToken.balanceOf(validator);
        uint256 proxyBalanceBefore = gltToken.balanceOf(proxyAddress);

        vm.prank(validator);
        registry.completeUnstake();

        uint256 balanceAfter = gltToken.balanceOf(validator);
        uint256 proxyBalanceAfter = gltToken.balanceOf(proxyAddress);

        assertEq(balanceAfter - balanceBefore, unstakeAmount);
        assertEq(proxyBalanceBefore - proxyBalanceAfter, unstakeAmount);
    }

    function testFuzz_ValidatorSetOrdering(uint256[3] memory stakes) public {
        address[] memory validators = new address[](3);
        uint256 validCount = 0;

        for (uint256 i = 0; i < 3; ++i) {
            stakes[i] = bound(stakes[i], MINIMUM_STAKE, 100_000e18);

            validators[i] = address(uint160(i + 100));
            _setupValidator(validators[i], stakes[i]);

            vm.prank(validators[i]);
            registry.registerValidator(stakes[i]);
            ++validCount;
        }

        address[] memory activeValidators = registry.getActiveValidators();

        uint256 activeValidatorsLength = activeValidators.length;
        for (uint256 i = 1; i < activeValidatorsLength; ++i) {
            IValidatorRegistry.ValidatorInfo memory prev = registry.getValidatorInfo(activeValidators[i - 1]);
            IValidatorRegistry.ValidatorInfo memory curr = registry.getValidatorInfo(activeValidators[i]);
            assertGe(prev.stakedAmount, curr.stakedAmount);
        }

        for (uint256 i = 0; i < activeValidatorsLength; ++i) {
            address proxyAddress = registry.getValidatorProxy(activeValidators[i]);
            assertTrue(proxyAddress != address(0));
        }
    }

    function testFuzz_BeaconProxyIntegrity(uint256 initialStake, uint256 increaseAmount, uint256 slashAmount) public {
        initialStake = bound(initialStake, MINIMUM_STAKE, 50_000e18);
        increaseAmount = bound(increaseAmount, 1e18, 50_000e18);
        slashAmount = bound(slashAmount, 1e18, 10_000e18);

        address validator = address(0xABC);

        _setupValidator(validator, initialStake);
        vm.prank(validator);
        registry.registerValidator(initialStake);

        address proxyAddress = registry.getValidatorProxy(validator);
        IValidator validatorProxy = IValidator(proxyAddress);

        assertEq(gltToken.balanceOf(proxyAddress), initialStake);
        assertEq(validatorProxy.getStakedAmount(), initialStake);

        gltToken.mint(validator, increaseAmount);
        vm.prank(validator);
        gltToken.approve(address(registry), increaseAmount);
        vm.prank(validator);
        registry.increaseStake(increaseAmount);

        uint256 totalStake = initialStake + increaseAmount;

        assertEq(gltToken.balanceOf(proxyAddress), totalStake);
        assertEq(validatorProxy.getStakedAmount(), totalStake);

        uint256 maxSlash = (totalStake * SLASH_PERCENTAGE) / 100;
        uint256 expectedSlash = slashAmount < maxSlash ? slashAmount : maxSlash;

        vm.prank(slasher);
        registry.slashValidator(validator, slashAmount, "Integrity test");

        uint256 finalStake = totalStake - expectedSlash;

        assertEq(gltToken.balanceOf(proxyAddress), totalStake);
        assertEq(validatorProxy.getStakedAmount(), finalStake);

        IValidatorRegistry.ValidatorInfo memory registryInfo = registry.getValidatorInfo(validator);
        IValidator.ValidatorInfo memory proxyInfo = validatorProxy.getValidatorInfo();

        assertEq(registryInfo.stakedAmount, proxyInfo.stakedAmount);
        assertEq(uint8(registryInfo.status), uint8(proxyInfo.status));
        assertEq(registryInfo.validatorAddress, proxyInfo.validatorAddress);
    }
}
