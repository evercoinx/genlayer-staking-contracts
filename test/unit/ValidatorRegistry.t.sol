// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IValidator } from "../../src/interfaces/IValidator.sol";
import { IValidatorRegistry } from "../../src/interfaces/IValidatorRegistry.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { ValidatorBeacon } from "../../src/ValidatorBeacon.sol";
import { Validator } from "../../src/Validator.sol";
import { GLTToken } from "../../src/GLTToken.sol";

/**
 * @title ValidatorRegistryTest
 * @dev Test suite for ValidatorRegistry contract.
 */
contract ValidatorRegistryTest is Test {
    ValidatorRegistry public registry;
    GLTToken public gltToken;
    address public slasher;
    address public validator1;
    address public validator2;
    address public validator3;

    uint256 public constant MINIMUM_STAKE = 1000e18;
    uint256 public constant BONDING_PERIOD = 1;
    uint256 public constant MAX_VALIDATORS = 100;

    event ValidatorRegistered(address indexed validator, uint256 stakedAmount);
    event ValidatorProxyCreated(address indexed validator, address indexed proxy, uint256 stakedAmount);
    event StakeIncreased(address indexed validator, uint256 additionalStake, uint256 newTotalStake);
    event UnstakeRequested(address indexed validator, uint256 unstakeAmount, uint256 unstakeRequestTime);
    event UnstakeCompleted(address indexed validator, uint256 unstakedAmount);
    event ValidatorSlashed(address indexed validator, uint256 slashedAmount, string reason);
    event ActiveValidatorSetUpdated(address[] validators, uint256 blockNumber);

    function setUp() public {
        slasher = makeAddr("slasher");
        validator1 = makeAddr("validator1");
        validator2 = makeAddr("validator2");
        validator3 = makeAddr("validator3");

        gltToken = new GLTToken(address(this));
        registry = new ValidatorRegistry(address(gltToken), slasher);

        gltToken.mint(validator1, 10_000e18);
        gltToken.mint(validator2, 10_000e18);
        gltToken.mint(validator3, 10_000e18);
    }

    function test_Constructor() public view {
        assertEq(address(registry.gltToken()), address(gltToken));
        assertEq(registry.slasher(), slasher);
        assertEq(registry.getMinimumStake(), MINIMUM_STAKE);
        assertEq(registry.getBondingPeriod(), BONDING_PERIOD);
        assertEq(registry.getMaxValidators(), MAX_VALIDATORS);
        assertNotEq(address(registry.getValidatorBeacon()), address(0));
    }

    function test_RegisterValidator() public {
        uint256 stakeAmount = 2000e18;
        string memory metadata = "validator1-metadata";

        vm.startPrank(validator1);
        gltToken.approve(address(registry), stakeAmount);

        vm.expectEmit(true, false, false, true);
        emit ValidatorRegistered(validator1, stakeAmount);

        vm.expectEmit(true, false, false, true);
        emit ValidatorProxyCreated(validator1, address(0), stakeAmount); // address(0) placeholder

        registry.registerValidatorWithMetadata(stakeAmount, metadata);
        vm.stopPrank();

        assertEq(registry.getTotalValidators(), 1);
        assertEq(registry.getTotalStake(), stakeAmount);
        assertTrue(registry.isActiveValidator(validator1));

        address proxy = registry.getValidatorProxy(validator1);
        assertNotEq(proxy, address(0));

        IValidator.ValidatorInfo memory info = registry.getValidatorInfoWithMetadata(validator1);
        assertEq(info.validatorAddress, validator1);
        assertEq(info.stakedAmount, stakeAmount);
        assertEq(uint8(info.status), uint8(IValidator.ValidatorStatus.Active));
        assertEq(info.metadata, metadata);

        address[] memory activeValidators = registry.getActiveValidators();
        assertEq(activeValidators.length, 1);
        assertEq(activeValidators[0], validator1);
    }

    function test_RegisterValidator_WithoutMetadata() public {
        uint256 stakeAmount = 2000e18;

        vm.startPrank(validator1);
        gltToken.approve(address(registry), stakeAmount);
        registry.registerValidator(stakeAmount);
        vm.stopPrank();

        assertEq(registry.getTotalValidators(), 1);
        assertTrue(registry.isActiveValidator(validator1));

        IValidator.ValidatorInfo memory info = registry.getValidatorInfoWithMetadata(validator1);
        assertEq(info.metadata, "");
    }

    function test_RevertWhen_RegisterValidator_InsufficientStake() public {
        uint256 stakeAmount = 500e18;

        vm.startPrank(validator1);
        gltToken.approve(address(registry), stakeAmount);

        vm.expectRevert(IValidatorRegistry.InsufficientStake.selector);
        registry.registerValidator(stakeAmount);
        vm.stopPrank();
    }

    function test_RevertWhen_RegisterValidator_AlreadyRegistered() public {
        uint256 stakeAmount = 2000e18;

        vm.startPrank(validator1);
        gltToken.approve(address(registry), stakeAmount * 2);
        registry.registerValidator(stakeAmount);

        vm.expectRevert(IValidatorRegistry.ValidatorAlreadyRegistered.selector);
        registry.registerValidator(stakeAmount);
        vm.stopPrank();
    }

    function test_IncreaseStake() public {
        uint256 initialStake = 2000e18;
        uint256 additionalStake = 1000e18;

        vm.startPrank(validator1);
        gltToken.approve(address(registry), initialStake + additionalStake);
        registry.registerValidator(initialStake);

        vm.expectEmit(true, false, false, true);
        emit StakeIncreased(validator1, additionalStake, initialStake + additionalStake);

        registry.increaseStake(additionalStake);
        vm.stopPrank();

        IValidator.ValidatorInfo memory info = registry.getValidatorInfoWithMetadata(validator1);
        assertEq(info.stakedAmount, initialStake + additionalStake);
        assertEq(registry.getTotalStake(), initialStake + additionalStake);
    }

    function test_RevertWhen_IncreaseStake_ValidatorNotFound() public {
        uint256 additionalStake = 1000e18;

        vm.startPrank(validator1);
        gltToken.approve(address(registry), additionalStake);

        vm.expectRevert(IValidatorRegistry.ValidatorNotFound.selector);
        registry.increaseStake(additionalStake);
        vm.stopPrank();
    }

    function test_RevertWhen_IncreaseStake_ZeroAmount() public {
        uint256 initialStake = 2000e18;

        vm.startPrank(validator1);
        gltToken.approve(address(registry), initialStake);
        registry.registerValidator(initialStake);

        vm.expectRevert(IValidatorRegistry.ZeroAmount.selector);
        registry.increaseStake(0);
        vm.stopPrank();
    }

    function test_RequestUnstake() public {
        uint256 initialStake = 2000e18;
        uint256 unstakeAmount = 500e18;

        vm.startPrank(validator1);
        gltToken.approve(address(registry), initialStake);
        registry.registerValidator(initialStake);

        vm.expectEmit(true, false, false, true);
        emit UnstakeRequested(validator1, unstakeAmount, block.timestamp);

        registry.requestUnstake(unstakeAmount);
        vm.stopPrank();

        assertTrue(registry.isActiveValidator(validator1));
    }

    function test_RequestUnstake_Full() public {
        uint256 initialStake = 2000e18;

        vm.startPrank(validator1);
        gltToken.approve(address(registry), initialStake);
        registry.registerValidator(initialStake);

        vm.expectEmit(true, false, false, true);
        emit UnstakeRequested(validator1, initialStake, block.timestamp);

        registry.requestUnstake(initialStake);
        vm.stopPrank();

        assertFalse(registry.isActiveValidator(validator1));

        IValidator.ValidatorInfo memory info = registry.getValidatorInfoWithMetadata(validator1);
        assertEq(uint8(info.status), uint8(IValidator.ValidatorStatus.Unstaking));
    }

    function test_CompleteUnstake() public {
        uint256 initialStake = 2000e18;

        vm.startPrank(validator1);
        gltToken.approve(address(registry), initialStake);
        registry.registerValidator(initialStake);
        registry.requestUnstake(initialStake);
        vm.stopPrank();

        vm.roll(block.number + BONDING_PERIOD);

        uint256 balanceBefore = gltToken.balanceOf(validator1);

        vm.startPrank(validator1);
        vm.expectEmit(true, false, false, true);
        emit UnstakeCompleted(validator1, initialStake);

        registry.completeUnstake();
        vm.stopPrank();

        uint256 balanceAfter = gltToken.balanceOf(validator1);
        assertEq(balanceAfter - balanceBefore, initialStake);

        assertEq(registry.getTotalStake(), 0);

        IValidator.ValidatorInfo memory info = registry.getValidatorInfoWithMetadata(validator1);
        assertEq(uint8(info.status), uint8(IValidator.ValidatorStatus.Inactive));
    }

    function test_SlashValidator() public {
        uint256 initialStake = 2000e18;
        uint256 slashAmount = 200e18;
        string memory reason = "Misbehavior detected";

        vm.startPrank(validator1);
        gltToken.approve(address(registry), initialStake);
        registry.registerValidator(initialStake);
        vm.stopPrank();

        vm.startPrank(slasher);
        vm.expectEmit(true, false, false, true);
        emit ValidatorSlashed(validator1, slashAmount, reason);

        registry.slashValidator(validator1, slashAmount, reason);
        vm.stopPrank();

        IValidator.ValidatorInfo memory info = registry.getValidatorInfoWithMetadata(validator1);
        assertEq(info.stakedAmount, initialStake - slashAmount);
        assertEq(registry.getTotalStake(), initialStake - slashAmount);

        assertTrue(registry.isActiveValidator(validator1));
    }

    function test_SlashValidator_BelowMinimum() public {
        uint256 initialStake = MINIMUM_STAKE;
        uint256 slashAmount = 1e18;
        string memory reason = "Minor infraction";

        vm.startPrank(validator1);
        gltToken.approve(address(registry), initialStake);
        registry.registerValidator(initialStake);
        vm.stopPrank();

        vm.startPrank(slasher);
        registry.slashValidator(validator1, slashAmount, reason);
        vm.stopPrank();

        IValidator.ValidatorInfo memory info = registry.getValidatorInfoWithMetadata(validator1);
        assertEq(uint8(info.status), uint8(IValidator.ValidatorStatus.Slashed));

        assertFalse(registry.isActiveValidator(validator1));
    }

    function test_RevertWhen_SlashValidator_NotSlasher() public {
        uint256 initialStake = 2000e18;

        vm.startPrank(validator1);
        gltToken.approve(address(registry), initialStake);
        registry.registerValidator(initialStake);
        vm.stopPrank();

        vm.startPrank(validator2);
        vm.expectRevert(IValidatorRegistry.CallerNotSlasher.selector);
        registry.slashValidator(validator1, 100e18, "reason");
        vm.stopPrank();
    }

    function test_ActiveValidatorSetUpdating() public {
        uint256[] memory stakes = new uint256[](3);
        stakes[0] = 3000e18;
        stakes[1] = 1500e18;
        stakes[2] = 1200e18;

        address[] memory validators = new address[](3);
        validators[0] = validator1;
        validators[1] = validator2;
        validators[2] = validator3;

        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(validators[i]);
            gltToken.approve(address(registry), stakes[i]);
            registry.registerValidator(stakes[i]);
            vm.stopPrank();
        }

        // Validators should be sorted by stake (descending)
        address[] memory activeValidators = registry.getActiveValidators();
        assertEq(activeValidators.length, 3);
        assertEq(activeValidators[0], validator1);
        assertEq(activeValidators[1], validator2);
        assertEq(activeValidators[2], validator3);
    }

    function test_UpgradeValidatorImplementation() public {
        Validator newImplementation = new Validator();

        vm.expectRevert();
        vm.startPrank(validator1);
        registry.upgradeValidatorImplementation(address(newImplementation));
        vm.stopPrank();

        registry.upgradeValidatorImplementation(address(newImplementation));

        ValidatorBeacon beacon = ValidatorBeacon(registry.getValidatorBeacon());
        assertEq(beacon.getImplementation(), address(newImplementation));
    }

    function test_SetSlasher() public {
        address newSlasher = makeAddr("newSlasher");

        vm.expectRevert();
        vm.startPrank(validator1);
        registry.setSlasher(newSlasher);
        vm.stopPrank();

        registry.setSlasher(newSlasher);
        assertEq(registry.slasher(), newSlasher);
    }

    function test_RevertWhen_SetSlasher_ZeroAddress() public {
        vm.expectRevert(IValidatorRegistry.ZeroAddress.selector);
        registry.setSlasher(address(0));
    }

    function test_GettersReturnCorrectValues() public view {
        assertEq(registry.getMinimumStake(), MINIMUM_STAKE);
        assertEq(registry.getBondingPeriod(), BONDING_PERIOD);
        assertEq(registry.getMaxValidators(), MAX_VALIDATORS);
        assertEq(registry.getTotalValidators(), 0);
        assertEq(registry.getTotalStake(), 0);
        assertEq(registry.getActiveValidators().length, 0);
    }

    function test_ValidatorProxyInteraction() public {
        uint256 stakeAmount = 2000e18;
        string memory metadata = "test-metadata";

        vm.startPrank(validator1);
        gltToken.approve(address(registry), stakeAmount);
        registry.registerValidatorWithMetadata(stakeAmount, metadata);
        vm.stopPrank();

        address proxy = registry.getValidatorProxy(validator1);
        assertNotEq(proxy, address(0));

        IValidator validatorContract = IValidator(proxy);
        assertEq(validatorContract.getValidatorAddress(), validator1);
        assertEq(validatorContract.getStakedAmount(), stakeAmount);
        assertEq(validatorContract.getMetadata(), metadata);
        assertEq(uint8(validatorContract.getStatus()), uint8(IValidator.ValidatorStatus.Active));
    }

    function test_ValidatorMetadataUpdate() public {
        uint256 stakeAmount = 2000e18;
        string memory initialMetadata = "initial-metadata";
        string memory newMetadata = "updated-metadata";

        vm.startPrank(validator1);
        gltToken.approve(address(registry), stakeAmount);
        registry.registerValidatorWithMetadata(stakeAmount, initialMetadata);

        address proxy = registry.getValidatorProxy(validator1);
        IValidator(proxy).updateMetadata(newMetadata);
        vm.stopPrank();

        IValidator.ValidatorInfo memory info = registry.getValidatorInfoWithMetadata(validator1);
        assertEq(info.metadata, newMetadata);
    }

    function testFuzz_RegisterValidator(uint256 stakeAmount) public {
        stakeAmount = bound(stakeAmount, MINIMUM_STAKE, 10_000e18);

        vm.startPrank(validator1);
        gltToken.approve(address(registry), stakeAmount);
        registry.registerValidator(stakeAmount);
        vm.stopPrank();

        assertEq(registry.getTotalValidators(), 1);
        assertEq(registry.getTotalStake(), stakeAmount);
        assertTrue(registry.isActiveValidator(validator1));
    }

    function testFuzz_IncreaseStake(uint256 initialStake, uint256 additionalStake) public {
        initialStake = bound(initialStake, MINIMUM_STAKE, 5000e18);
        additionalStake = bound(additionalStake, 1, 10_000e18 - initialStake);

        vm.startPrank(validator1);
        gltToken.approve(address(registry), initialStake + additionalStake);
        registry.registerValidator(initialStake);
        registry.increaseStake(additionalStake);
        vm.stopPrank();

        IValidator.ValidatorInfo memory info = registry.getValidatorInfoWithMetadata(validator1);
        assertEq(info.stakedAmount, initialStake + additionalStake);
        assertEq(registry.getTotalStake(), initialStake + additionalStake);
    }

    function test_GetTopValidators() public {
        address[] memory validators = new address[](7);
        uint256[] memory stakes = new uint256[](7);

        for (uint256 i = 0; i < 7; i++) {
            validators[i] = makeAddr(string(abi.encodePacked("validator", i)));
            stakes[i] = MINIMUM_STAKE + (i * 100e18);
            gltToken.mint(validators[i], stakes[i]);

            vm.startPrank(validators[i]);
            gltToken.approve(address(registry), stakes[i]);
            registry.registerValidator(stakes[i]);
            vm.stopPrank();
        }

        address[] memory activeValidators = registry.getActiveValidators();
        assertEq(activeValidators.length, 5);

        address[] memory top5 = registry.getTopValidators(5);
        assertEq(top5.length, 5);

        for (uint256 i = 0; i < 4; i++) {
            IValidator.ValidatorInfo memory info1 = registry.getValidatorInfoWithMetadata(top5[i]);
            IValidator.ValidatorInfo memory info2 = registry.getValidatorInfoWithMetadata(top5[i + 1]);
            assertGe(info1.stakedAmount, info2.stakedAmount);
        }

        address[] memory top10 = registry.getTopValidators(10);
        assertLe(top10.length, 7);

        address[] memory top3 = registry.getTopValidators(3);
        assertEq(top3.length, 3);

        for (uint256 i = 0; i < top3.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < validators.length; j++) {
                if (top3[i] == validators[j]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found);
        }
    }

    function test_IsTopValidator() public {
        address[] memory validators = new address[](5);
        uint256[] memory stakes = new uint256[](5);
        stakes[0] = 5000e18;
        stakes[1] = 4000e18;
        stakes[2] = 3000e18;
        stakes[3] = 2000e18;
        stakes[4] = 1000e18;

        for (uint256 i = 0; i < 5; i++) {
            validators[i] = makeAddr(string(abi.encodePacked("validator", i)));
            gltToken.mint(validators[i], stakes[i]);

            vm.startPrank(validators[i]);
            gltToken.approve(address(registry), stakes[i]);
            registry.registerValidator(stakes[i]);
            vm.stopPrank();
        }

        assertTrue(registry.isTopValidator(validators[0], 3));
        assertTrue(registry.isTopValidator(validators[1], 3));
        assertTrue(registry.isTopValidator(validators[2], 3));
        assertFalse(registry.isTopValidator(validators[3], 3));
        assertFalse(registry.isTopValidator(validators[4], 3));

        for (uint256 i = 0; i < 5; i++) {
            assertTrue(registry.isTopValidator(validators[i], 5));
        }

        assertTrue(registry.isTopValidator(validators[0], 1));
        for (uint256 i = 1; i < 5; i++) {
            assertFalse(registry.isTopValidator(validators[i], 1));
        }
    }

    function test_RevertWhen_GetTopValidators_InvalidCount() public {
        vm.expectRevert(IValidatorRegistry.InvalidCount.selector);
        registry.getTopValidators(0);
    }

    function test_RevertWhen_IsTopValidator_InvalidCount() public {
        vm.expectRevert(IValidatorRegistry.InvalidCount.selector);
        registry.isTopValidator(validator1, 0);
    }

    function test_TopValidators_UpdateOnStakeChanges() public {
        uint256 stake1 = 3000e18;
        uint256 stake2 = 2000e18;
        uint256 stake3 = 1000e18;

        vm.prank(validator1);
        gltToken.approve(address(registry), stake1);
        vm.prank(validator1);
        registry.registerValidator(stake1);

        vm.prank(validator2);
        gltToken.approve(address(registry), stake2);
        vm.prank(validator2);
        registry.registerValidator(stake2);

        vm.prank(validator3);
        gltToken.approve(address(registry), stake3);
        vm.prank(validator3);
        registry.registerValidator(stake3);

        address[] memory top1 = registry.getTopValidators(1);
        assertEq(top1[0], validator1);

        gltToken.mint(validator3, 3000e18);
        vm.prank(validator3);
        gltToken.approve(address(registry), 3000e18);
        vm.prank(validator3);
        registry.increaseStake(3000e18);

        top1 = registry.getTopValidators(1);
        assertEq(top1[0], validator3);

        address[] memory top2 = registry.getTopValidators(2);
        assertEq(top2[0], validator3);
        assertEq(top2[1], validator1);
    }
}
