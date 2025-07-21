// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { IValidator } from "../../src/interfaces/IValidator.sol";
import { Validator } from "../../src/Validator.sol";
import { ValidatorBeacon } from "../../src/ValidatorBeacon.sol";
import { GLTToken } from "../../src/GLTToken.sol";

/**
 * @title ValidatorFuzzTest
 * @dev Fuzz tests for Validator contract
 */
contract ValidatorFuzzTest is Test {
    // Constants
    uint256 private constant MINIMUM_STAKE = 1000e18;
    uint256 private constant BONDING_PERIOD = 1;

    Validator public validatorImplementation;
    ValidatorBeacon public beacon;
    GLTToken public gltToken;

    address public validatorAddress;
    address public registry;
    address public unauthorized;

    function setUp() public {
        validatorAddress = makeAddr("validator");
        registry = makeAddr("registry");
        unauthorized = makeAddr("unauthorized");

        gltToken = new GLTToken(address(this));
        validatorImplementation = new Validator();
        beacon = new ValidatorBeacon(address(validatorImplementation), registry);
        gltToken.mint(validatorAddress, 1_000_000e18);
    }

    function _deployValidatorProxy(uint256 stakeAmount, string memory metadata) internal returns (IValidator) {
        // Transfer tokens to this contract (simulating registry behavior)
        vm.startPrank(validatorAddress);
        gltToken.approve(address(this), stakeAmount);
        vm.stopPrank();
        gltToken.transferFrom(validatorAddress, address(this), stakeAmount);

        // Deploy beacon proxy
        BeaconProxy proxy = new BeaconProxy(
            address(beacon),
            abi.encodeWithSelector(
                IValidator.initialize.selector, validatorAddress, stakeAmount, metadata, address(gltToken), registry
            )
        );

        // Transfer tokens to the validator proxy (simulating registry behavior)
        gltToken.transfer(address(proxy), stakeAmount);

        return IValidator(address(proxy));
    }

    function testFuzz_Initialize(uint256 stakeAmount, string memory metadata) public {
        stakeAmount = bound(stakeAmount, MINIMUM_STAKE, 100_000e18);
        vm.assume(bytes(metadata).length <= 1000);

        IValidator validator = _deployValidatorProxy(stakeAmount, metadata);

        assertEq(validator.getValidatorAddress(), validatorAddress);
        assertEq(validator.getStakedAmount(), stakeAmount);
        assertEq(validator.getMetadata(), metadata);
        assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Active));
        assertEq(gltToken.balanceOf(address(validator)), stakeAmount);
    }

    function testFuzz_IncreaseStake(uint256 initialStake, uint256 additionalStake) public {
        initialStake = bound(initialStake, MINIMUM_STAKE, 50_000e18);
        additionalStake = bound(additionalStake, 1, 50_000e18);

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(validatorAddress);
        gltToken.approve(address(this), additionalStake);
        vm.stopPrank();
        gltToken.transferFrom(validatorAddress, address(this), additionalStake);

        vm.startPrank(registry);
        validator.increaseStake(additionalStake);
        vm.stopPrank();

        gltToken.transfer(address(validator), additionalStake);

        assertEq(validator.getStakedAmount(), initialStake + additionalStake);
        assertEq(gltToken.balanceOf(address(validator)), initialStake + additionalStake);
    }

    function testFuzz_RequestUnstake_Partial(uint256 initialStake, uint256 unstakeAmount) public {
        initialStake = bound(initialStake, MINIMUM_STAKE * 2, 100_000e18);
        unstakeAmount = bound(unstakeAmount, 1, initialStake - MINIMUM_STAKE);

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(registry);
        validator.requestUnstake(unstakeAmount);
        vm.stopPrank();

        assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Active));
        assertFalse(validator.canCompleteUnstake());
    }

    function testFuzz_RequestUnstake_Full(uint256 stakeAmount) public {
        stakeAmount = bound(stakeAmount, MINIMUM_STAKE, 100_000e18);

        IValidator validator = _deployValidatorProxy(stakeAmount, "");

        vm.startPrank(registry);
        validator.requestUnstake(stakeAmount);
        vm.stopPrank();

        assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Unstaking));
        assertFalse(validator.canCompleteUnstake());
    }

    function testFuzz_CompleteUnstake(uint256 initialStake, uint256 unstakeAmount) public {
        initialStake = bound(initialStake, MINIMUM_STAKE, 100_000e18);
        unstakeAmount = bound(unstakeAmount, 1, initialStake);

        uint256 remainingStake = initialStake - unstakeAmount;
        vm.assume(remainingStake == 0 || remainingStake >= MINIMUM_STAKE);

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(registry);
        validator.requestUnstake(unstakeAmount);
        vm.stopPrank();

        vm.roll(block.number + BONDING_PERIOD);

        assertTrue(validator.canCompleteUnstake());

        uint256 balanceBefore = gltToken.balanceOf(validatorAddress);

        vm.startPrank(registry);
        validator.completeUnstake();
        vm.stopPrank();

        uint256 balanceAfter = gltToken.balanceOf(validatorAddress);
        assertEq(balanceAfter - balanceBefore, unstakeAmount);
        assertEq(validator.getStakedAmount(), initialStake - unstakeAmount);
        if (remainingStake == 0) {
            assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Inactive));
        } else {
            assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Active));
        }
    }

    function testFuzz_Slash(uint256 initialStake, uint256 slashAmount, string memory reason) public {
        initialStake = bound(initialStake, MINIMUM_STAKE, 100_000e18);
        slashAmount = bound(slashAmount, 1, initialStake);
        vm.assume(bytes(reason).length <= 100);

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(registry);
        validator.slash(slashAmount, reason);
        vm.stopPrank();

        assertEq(validator.getStakedAmount(), initialStake - slashAmount);
        uint256 remainingStake = initialStake - slashAmount;
        if (remainingStake == 0) {
            assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Inactive));
        } else if (remainingStake < MINIMUM_STAKE) {
            assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Slashed));
        } else {
            assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Active));
        }
    }

    function testFuzz_UpdateMetadata(string memory initialMetadata, string memory newMetadata) public {
        vm.assume(bytes(initialMetadata).length <= 500);
        vm.assume(bytes(newMetadata).length <= 500);
        vm.assume(keccak256(bytes(initialMetadata)) != keccak256(bytes(newMetadata)));

        IValidator validator = _deployValidatorProxy(MINIMUM_STAKE, initialMetadata);

        vm.startPrank(validatorAddress);
        validator.updateMetadata(newMetadata);
        vm.stopPrank();

        assertEq(validator.getMetadata(), newMetadata);
    }

    function testFuzz_MultipleOperations(uint256 seed) public {
        uint256 initialStake = bound(seed, MINIMUM_STAKE * 2, 50_000e18);
        IValidator validator = _deployValidatorProxy(initialStake, "initial");

        uint256 currentStake = initialStake;
        uint256 stakedInValidator = initialStake;
        uint256 operations = seed % 5 + 1;

        for (uint256 i = 0; i < operations; ++i) {
            uint256 opType = uint256(keccak256(abi.encode(seed, i))) % 3;

            if (opType == 0 && currentStake < 80_000e18) {
                uint256 increase = bound(uint256(keccak256(abi.encode(seed, i, "increase"))), 1, 10_000e18);

                vm.startPrank(validatorAddress);
                gltToken.approve(address(this), increase);
                vm.stopPrank();
                gltToken.transferFrom(validatorAddress, address(this), increase);

                vm.startPrank(registry);
                validator.increaseStake(increase);
                vm.stopPrank();

                gltToken.transfer(address(validator), increase);
                currentStake += increase;
                stakedInValidator += increase;
            } else if (opType == 1 && currentStake > MINIMUM_STAKE * 2) {
                uint256 slashAmount = bound(uint256(keccak256(abi.encode(seed, i, "slash"))), 1, currentStake / 2);

                vm.startPrank(registry);
                validator.slash(slashAmount, "fuzz slash");
                vm.stopPrank();

                currentStake -= slashAmount;
            } else {
                string memory newMetadata = string(abi.encodePacked("metadata-", vm.toString(i)));

                vm.startPrank(validatorAddress);
                validator.updateMetadata(newMetadata);
                vm.stopPrank();
            }
        }

        assertEq(validator.getStakedAmount(), currentStake);
        assertEq(gltToken.balanceOf(address(validator)), stakedInValidator);
    }

    function testFuzz_StakeUnstakeCycle(uint256 initialStake, uint256 cycleCount, uint256 seed) public {
        initialStake = bound(initialStake, MINIMUM_STAKE * 3, 50_000e18);
        cycleCount = bound(cycleCount, 1, 5);

        IValidator validator = _deployValidatorProxy(initialStake, "");
        uint256 currentStake = initialStake;
        bool hasUnstakeRequest = false;

        for (uint256 i = 0; i < cycleCount; ++i) {
            if (hasUnstakeRequest) {
                vm.roll(block.number + BONDING_PERIOD);

                vm.startPrank(registry);
                validator.completeUnstake();
                vm.stopPrank();

                hasUnstakeRequest = false;
            }

            uint256 unstakeAmount = bound(uint256(keccak256(abi.encode(seed, i))), 1, currentStake / 2);

            if (currentStake - unstakeAmount < MINIMUM_STAKE) {
                unstakeAmount = currentStake - MINIMUM_STAKE;
            }

            if (unstakeAmount > 0) {
                vm.startPrank(registry);
                validator.requestUnstake(unstakeAmount);
                vm.stopPrank();

                currentStake -= unstakeAmount;
                hasUnstakeRequest = true;
            }

            if (i % 2 == 0 && currentStake < 40_000e18) {
                uint256 increase = bound(uint256(keccak256(abi.encode(seed, i, "increase"))), 1000e18, 10_000e18);

                vm.startPrank(validatorAddress);
                gltToken.approve(address(this), increase);
                vm.stopPrank();
                gltToken.transferFrom(validatorAddress, address(this), increase);

                vm.startPrank(registry);
                validator.increaseStake(increase);
                vm.stopPrank();

                gltToken.transfer(address(validator), increase);
                currentStake += increase;
            }
        }

        if (hasUnstakeRequest) {
            vm.roll(block.number + BONDING_PERIOD);
            vm.startPrank(registry);
            validator.completeUnstake();
            vm.stopPrank();
        }

        assertEq(validator.getStakedAmount(), currentStake);
        assertGe(currentStake, MINIMUM_STAKE);
        assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Active));
    }

    function testFuzz_RevertConditions(uint256 stakeAmount, uint256 amount, address caller) public {
        vm.assume(caller != address(0) && caller != registry && caller != validatorAddress);

        if (stakeAmount < MINIMUM_STAKE && stakeAmount > 0) {
            vm.expectRevert(IValidator.InsufficientStake.selector);
            new BeaconProxy(
                address(beacon),
                abi.encodeWithSelector(
                    IValidator.initialize.selector, validatorAddress, stakeAmount, "", address(gltToken), registry
                )
            );
        }

        if (stakeAmount >= MINIMUM_STAKE && stakeAmount <= 100_000e18) {
            IValidator validator = _deployValidatorProxy(stakeAmount, "");

            vm.startPrank(caller);
            vm.expectRevert(IValidator.Unauthorized.selector);
            validator.increaseStake(amount);

            vm.expectRevert(IValidator.Unauthorized.selector);
            validator.slash(amount, "unauthorized");
            vm.stopPrank();

            if (caller != validatorAddress) {
                vm.startPrank(caller);
                vm.expectRevert(IValidator.Unauthorized.selector);
                validator.updateMetadata("new");
                vm.stopPrank();
            }
        }
    }
}
