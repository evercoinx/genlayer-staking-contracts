// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { IValidator } from "../../src/interfaces/IValidator.sol";
import { Validator } from "../../src/Validator.sol";
import { ValidatorBeacon } from "../../src/ValidatorBeacon.sol";
import { GLTToken } from "../../src/GLTToken.sol";

contract ValidatorTest is Test {
    Validator public validatorImplementation;
    ValidatorBeacon public beacon;
    GLTToken public gltToken;

    address public validatorAddress;
    address public registry;
    address public unauthorized;

    uint256 public constant MINIMUM_STAKE = 1000e18;
    uint256 public constant BONDING_PERIOD = 1; // 1 block per PRD

    function setUp() public {
        validatorAddress = makeAddr("validator");
        registry = makeAddr("registry");
        unauthorized = makeAddr("unauthorized");

        // Deploy GLT token
        gltToken = new GLTToken(address(this));

        // Deploy validator implementation
        validatorImplementation = new Validator();

        // Deploy beacon
        beacon = new ValidatorBeacon(address(validatorImplementation), registry);

        // Mint tokens to validator
        gltToken.mint(validatorAddress, 10_000e18);
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

    function test_Initialize() public {
        uint256 stakeAmount = 2000e18;
        string memory metadata = "test-metadata";

        IValidator validator = _deployValidatorProxy(stakeAmount, metadata);

        // Check initialization
        assertEq(validator.getValidatorAddress(), validatorAddress);
        assertEq(validator.getStakedAmount(), stakeAmount);
        assertEq(validator.getMetadata(), metadata);
        assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Active));

        // Check validator info
        IValidator.ValidatorInfo memory info = validator.getValidatorInfo();
        assertEq(info.validatorAddress, validatorAddress);
        assertEq(info.stakedAmount, stakeAmount);
        assertEq(uint8(info.status), uint8(IValidator.ValidatorStatus.Active));
        assertEq(info.metadata, metadata);
        assertEq(info.activationTime, 0); // Deprecated field

        // Check tokens were transferred
        assertEq(gltToken.balanceOf(address(validator)), stakeAmount);
    }

    function test_RevertWhen_Initialize_InsufficientStake() public {
        uint256 stakeAmount = 500e18; // Below minimum

        vm.startPrank(validatorAddress);
        gltToken.approve(address(validatorImplementation), stakeAmount);
        vm.stopPrank();

        vm.expectRevert(IValidator.InsufficientStake.selector);
        new BeaconProxy(
            address(beacon),
            abi.encodeWithSelector(
                IValidator.initialize.selector, validatorAddress, stakeAmount, "", address(gltToken), registry
            )
        );
    }

    function test_RevertWhen_Initialize_ZeroAddress() public {
        uint256 stakeAmount = 2000e18;

        vm.expectRevert(IValidator.Unauthorized.selector);
        new BeaconProxy(
            address(beacon),
            abi.encodeWithSelector(
                IValidator.initialize.selector, address(0), stakeAmount, "", address(gltToken), registry
            )
        );
    }

    function test_IncreaseStake() public {
        uint256 initialStake = 2000e18;
        uint256 additionalStake = 1000e18;

        IValidator validator = _deployValidatorProxy(initialStake, "");

        // Transfer additional tokens to this contract (simulating registry)
        vm.startPrank(validatorAddress);
        gltToken.approve(address(this), additionalStake);
        vm.stopPrank();
        gltToken.transferFrom(validatorAddress, address(this), additionalStake);

        vm.expectEmit(false, false, false, true);
        emit IValidator.StakeIncreased(additionalStake, initialStake + additionalStake);

        // Call as registry
        vm.startPrank(registry);
        validator.increaseStake(additionalStake);
        vm.stopPrank();

        // Transfer tokens to validator (simulating registry behavior)
        gltToken.transfer(address(validator), additionalStake);

        // Check updated stake
        assertEq(validator.getStakedAmount(), initialStake + additionalStake);
        assertEq(gltToken.balanceOf(address(validator)), initialStake + additionalStake);
    }

    function test_RevertWhen_IncreaseStake_Unauthorized() public {
        uint256 initialStake = 2000e18;
        uint256 additionalStake = 1000e18;

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(unauthorized);
        vm.expectRevert(IValidator.Unauthorized.selector);
        validator.increaseStake(additionalStake);
        vm.stopPrank();
    }

    function test_RevertWhen_IncreaseStake_ZeroAmount() public {
        uint256 initialStake = 2000e18;

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(registry);
        vm.expectRevert(IValidator.ZeroAmount.selector);
        validator.increaseStake(0);
        vm.stopPrank();
    }

    function test_RequestUnstake() public {
        uint256 initialStake = 2000e18;
        uint256 unstakeAmount = 500e18;

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(registry);
        vm.expectEmit(false, false, false, true);
        emit IValidator.UnstakeRequested(unstakeAmount, block.timestamp);

        validator.requestUnstake(unstakeAmount);
        vm.stopPrank();

        // Check validator still active (partial unstake)
        assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Active));
        assertFalse(validator.canCompleteUnstake()); // Bonding period not met
    }

    function test_RequestUnstake_Full() public {
        uint256 initialStake = 2000e18;

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(registry);
        vm.expectEmit(false, false, false, true);
        emit IValidator.UnstakeRequested(initialStake, block.timestamp);

        validator.requestUnstake(initialStake);
        vm.stopPrank();

        // Check validator marked as unstaking
        assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Unstaking));
        assertFalse(validator.canCompleteUnstake()); // Bonding period not met
    }

    function test_RevertWhen_RequestUnstake_ExceedsStake() public {
        uint256 initialStake = 2000e18;
        uint256 unstakeAmount = 3000e18; // More than staked

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(registry);
        vm.expectRevert(IValidator.UnstakeExceedsStake.selector);
        validator.requestUnstake(unstakeAmount);
        vm.stopPrank();
    }

    function test_RevertWhen_RequestUnstake_InsufficientRemaining() public {
        uint256 initialStake = 1200e18;
        uint256 unstakeAmount = 500e18; // Would leave 700e18, below minimum

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(registry);
        vm.expectRevert(IValidator.InsufficientStake.selector);
        validator.requestUnstake(unstakeAmount);
        vm.stopPrank();
    }

    function test_CompleteUnstake() public {
        uint256 initialStake = 2000e18;
        uint256 unstakeAmount = 500e18;

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(registry);
        validator.requestUnstake(unstakeAmount);
        vm.stopPrank();

        // Fast forward bonding period
        vm.roll(block.number + BONDING_PERIOD);

        assertTrue(validator.canCompleteUnstake());

        uint256 balanceBefore = gltToken.balanceOf(validatorAddress);

        vm.startPrank(registry);
        vm.expectEmit(false, false, false, true);
        emit IValidator.UnstakeCompleted(unstakeAmount);

        validator.completeUnstake();
        vm.stopPrank();

        // Check tokens returned
        uint256 balanceAfter = gltToken.balanceOf(validatorAddress);
        assertEq(balanceAfter - balanceBefore, unstakeAmount);

        // Check updated stake
        assertEq(validator.getStakedAmount(), initialStake - unstakeAmount);

        // Should still be active
        assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Active));
    }

    function test_CompleteUnstake_Full() public {
        uint256 initialStake = 2000e18;

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(registry);
        validator.requestUnstake(initialStake);
        vm.stopPrank();

        // Fast forward bonding period
        vm.roll(block.number + BONDING_PERIOD);

        uint256 balanceBefore = gltToken.balanceOf(validatorAddress);

        vm.startPrank(registry);
        validator.completeUnstake();
        vm.stopPrank();

        // Check all tokens returned
        uint256 balanceAfter = gltToken.balanceOf(validatorAddress);
        assertEq(balanceAfter - balanceBefore, initialStake);

        // Check validator inactive
        assertEq(validator.getStakedAmount(), 0);
        assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Inactive));
    }

    function test_RevertWhen_CompleteUnstake_BondingPeriodNotMet() public {
        uint256 initialStake = 2000e18;
        uint256 unstakeAmount = 500e18;

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(registry);
        validator.requestUnstake(unstakeAmount);

        vm.expectRevert(IValidator.BondingPeriodNotMet.selector);
        validator.completeUnstake();
        vm.stopPrank();
    }

    function test_Slash() public {
        uint256 initialStake = 2000e18;
        uint256 slashAmount = 200e18;
        string memory reason = "Misbehavior";

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(registry);
        vm.expectEmit(false, false, false, true);
        emit IValidator.ValidatorSlashed(slashAmount, reason);

        validator.slash(slashAmount, reason);
        vm.stopPrank();

        // Check updated stake
        assertEq(validator.getStakedAmount(), initialStake - slashAmount);

        // Should still be active since remaining stake > minimum
        assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Active));
    }

    function test_Slash_BelowMinimum() public {
        uint256 initialStake = MINIMUM_STAKE;
        uint256 slashAmount = 1e18;
        string memory reason = "Minor infraction";

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(registry);
        validator.slash(slashAmount, reason);
        vm.stopPrank();

        // Check validator marked as slashed
        assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Slashed));
        assertEq(validator.getStakedAmount(), initialStake - slashAmount);
    }

    function test_Slash_FullAmount() public {
        uint256 initialStake = 2000e18;

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(registry);
        validator.slash(initialStake, "Full slash");
        vm.stopPrank();

        // Check validator marked as inactive when fully slashed
        assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Inactive));
        assertEq(validator.getStakedAmount(), 0);
    }

    function test_RevertWhen_Slash_Unauthorized() public {
        uint256 initialStake = 2000e18;

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(unauthorized);
        vm.expectRevert(IValidator.Unauthorized.selector);
        validator.slash(100e18, "reason");
        vm.stopPrank();
    }

    function test_UpdateMetadata() public {
        uint256 initialStake = 2000e18;
        string memory initialMetadata = "initial";
        string memory newMetadata = "updated";

        IValidator validator = _deployValidatorProxy(initialStake, initialMetadata);

        vm.startPrank(validatorAddress);
        vm.expectEmit(false, false, false, true);
        emit IValidator.MetadataUpdated(newMetadata);

        validator.updateMetadata(newMetadata);
        vm.stopPrank();

        assertEq(validator.getMetadata(), newMetadata);
    }

    function test_RevertWhen_UpdateMetadata_Unauthorized() public {
        uint256 initialStake = 2000e18;

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(unauthorized);
        vm.expectRevert(IValidator.Unauthorized.selector);
        validator.updateMetadata("new");
        vm.stopPrank();
    }

    function testFuzz_Initialize(uint256 stakeAmount, string memory metadata) public {
        stakeAmount = bound(stakeAmount, MINIMUM_STAKE, 10_000e18);
        vm.assume(bytes(metadata).length <= 100); // Reasonable metadata length

        IValidator validator = _deployValidatorProxy(stakeAmount, metadata);

        assertEq(validator.getValidatorAddress(), validatorAddress);
        assertEq(validator.getStakedAmount(), stakeAmount);
        assertEq(validator.getMetadata(), metadata);
        assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Active));
    }

    function testFuzz_IncreaseStake(uint256 initialStake, uint256 additionalStake) public {
        initialStake = bound(initialStake, MINIMUM_STAKE, 5000e18);
        additionalStake = bound(additionalStake, 1, 5000e18 - (initialStake - MINIMUM_STAKE));

        IValidator validator = _deployValidatorProxy(initialStake, "");

        // Transfer additional tokens to this contract (simulating registry)
        vm.startPrank(validatorAddress);
        gltToken.approve(address(this), additionalStake);
        vm.stopPrank();
        gltToken.transferFrom(validatorAddress, address(this), additionalStake);

        // Call as registry
        vm.startPrank(registry);
        validator.increaseStake(additionalStake);
        vm.stopPrank();

        // Transfer tokens to validator (simulating registry behavior)
        gltToken.transfer(address(validator), additionalStake);

        assertEq(validator.getStakedAmount(), initialStake + additionalStake);
    }

    function testFuzz_RequestUnstake(uint256 initialStake, uint256 unstakeAmount) public {
        initialStake = bound(initialStake, MINIMUM_STAKE, 10_000e18);
        unstakeAmount = bound(unstakeAmount, 1, initialStake);

        uint256 remainingStake = initialStake - unstakeAmount;
        // Skip if would leave insufficient remaining stake
        if (remainingStake > 0 && remainingStake < MINIMUM_STAKE) {
            return;
        }

        IValidator validator = _deployValidatorProxy(initialStake, "");

        vm.startPrank(registry);
        validator.requestUnstake(unstakeAmount);
        vm.stopPrank();

        if (remainingStake == 0) {
            assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Unstaking));
        } else {
            assertEq(uint8(validator.getStatus()), uint8(IValidator.ValidatorStatus.Active));
        }
    }
}
