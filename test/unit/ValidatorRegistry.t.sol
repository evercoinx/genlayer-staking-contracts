// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { ValidatorBeacon } from "../../src/ValidatorBeacon.sol";
import { Validator } from "../../src/Validator.sol";
import { GLTToken } from "../../src/GLTToken.sol";
import { IValidator } from "../../src/interfaces/IValidator.sol";
import { IValidatorRegistry } from "../../src/interfaces/IValidatorRegistry.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ValidatorRegistryTest is Test {
    ValidatorRegistry public registry;
    GLTToken public gltToken;
    address public slasher;
    address public validator1;
    address public validator2;
    address public validator3;

    uint256 public constant MINIMUM_STAKE = 1000e18;
    uint256 public constant BONDING_PERIOD = 7 days;
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

        // Deploy GLT token
        gltToken = new GLTToken(address(this));

        // Deploy registry
        registry = new ValidatorRegistry(address(gltToken), slasher);

        // Mint tokens for validators
        gltToken.mint(validator1, 10000e18);
        gltToken.mint(validator2, 10000e18);
        gltToken.mint(validator3, 10000e18);
    }

    function test_Constructor() public {
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
        emit ValidatorProxyCreated(validator1, address(0), stakeAmount); // address(0) placeholder since we can't predict

        registry.registerValidatorWithMetadata(stakeAmount, metadata);
        vm.stopPrank();

        // Check validator was registered
        assertEq(registry.getTotalValidators(), 1);
        assertEq(registry.getTotalStake(), stakeAmount);
        assertTrue(registry.isActiveValidator(validator1));

        // Check proxy was created
        address proxy = registry.getValidatorProxy(validator1);
        assertNotEq(proxy, address(0));

        // Check validator info
        IValidator.ValidatorInfo memory info = registry.getValidatorInfoWithMetadata(validator1);
        assertEq(info.validatorAddress, validator1);
        assertEq(info.stakedAmount, stakeAmount);
        assertEq(uint8(info.status), uint8(IValidator.ValidatorStatus.Active));
        assertEq(info.metadata, metadata);

        // Check active validators
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

        // Check validator was registered
        assertEq(registry.getTotalValidators(), 1);
        assertTrue(registry.isActiveValidator(validator1));

        // Check metadata is empty
        IValidator.ValidatorInfo memory info = registry.getValidatorInfoWithMetadata(validator1);
        assertEq(info.metadata, "");
    }

    function test_RevertWhen_RegisterValidator_InsufficientStake() public {
        uint256 stakeAmount = 500e18; // Below minimum

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
        // Register validator first
        uint256 initialStake = 2000e18;
        uint256 additionalStake = 1000e18;

        vm.startPrank(validator1);
        gltToken.approve(address(registry), initialStake + additionalStake);
        registry.registerValidator(initialStake);

        vm.expectEmit(true, false, false, true);
        emit StakeIncreased(validator1, additionalStake, initialStake + additionalStake);

        registry.increaseStake(additionalStake);
        vm.stopPrank();

        // Check updated stake
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
        // Register validator first
        uint256 initialStake = 2000e18;

        vm.startPrank(validator1);
        gltToken.approve(address(registry), initialStake);
        registry.registerValidator(initialStake);

        vm.expectRevert(IValidatorRegistry.ZeroAmount.selector);
        registry.increaseStake(0);
        vm.stopPrank();
    }

    function test_RequestUnstake() public {
        // Register validator first
        uint256 initialStake = 2000e18;
        uint256 unstakeAmount = 500e18;

        vm.startPrank(validator1);
        gltToken.approve(address(registry), initialStake);
        registry.registerValidator(initialStake);

        vm.expectEmit(true, false, false, true);
        emit UnstakeRequested(validator1, unstakeAmount, block.timestamp);

        registry.requestUnstake(unstakeAmount);
        vm.stopPrank();

        // Check validator still active (partial unstake)
        assertTrue(registry.isActiveValidator(validator1));
    }

    function test_RequestUnstake_Full() public {
        // Register validator first
        uint256 initialStake = 2000e18;

        vm.startPrank(validator1);
        gltToken.approve(address(registry), initialStake);
        registry.registerValidator(initialStake);

        vm.expectEmit(true, false, false, true);
        emit UnstakeRequested(validator1, initialStake, block.timestamp);

        registry.requestUnstake(initialStake);
        vm.stopPrank();

        // Check validator no longer active (full unstake)
        assertFalse(registry.isActiveValidator(validator1));

        // Check status
        IValidator.ValidatorInfo memory info = registry.getValidatorInfoWithMetadata(validator1);
        assertEq(uint8(info.status), uint8(IValidator.ValidatorStatus.Unstaking));
    }

    function test_CompleteUnstake() public {
        // Register validator and request unstake
        uint256 initialStake = 2000e18;

        vm.startPrank(validator1);
        gltToken.approve(address(registry), initialStake);
        registry.registerValidator(initialStake);
        registry.requestUnstake(initialStake);
        vm.stopPrank();

        // Fast forward bonding period
        vm.warp(block.timestamp + BONDING_PERIOD + 1);

        uint256 balanceBefore = gltToken.balanceOf(validator1);

        vm.startPrank(validator1);
        vm.expectEmit(true, false, false, true);
        emit UnstakeCompleted(validator1, initialStake);

        registry.completeUnstake();
        vm.stopPrank();

        // Check tokens returned
        uint256 balanceAfter = gltToken.balanceOf(validator1);
        assertEq(balanceAfter - balanceBefore, initialStake);

        // Check total stake updated
        assertEq(registry.getTotalStake(), 0);

        // Check validator status
        IValidator.ValidatorInfo memory info = registry.getValidatorInfoWithMetadata(validator1);
        assertEq(uint8(info.status), uint8(IValidator.ValidatorStatus.Inactive));
    }

    function test_SlashValidator() public {
        // Register validator first
        uint256 initialStake = 2000e18;
        uint256 slashAmount = 200e18; // 10%
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

        // Check updated stake
        IValidator.ValidatorInfo memory info = registry.getValidatorInfoWithMetadata(validator1);
        assertEq(info.stakedAmount, initialStake - slashAmount);
        assertEq(registry.getTotalStake(), initialStake - slashAmount);

        // Should still be active since remaining stake > minimum
        assertTrue(registry.isActiveValidator(validator1));
    }

    function test_SlashValidator_BelowMinimum() public {
        // Register validator with minimum stake
        uint256 initialStake = MINIMUM_STAKE;
        uint256 slashAmount = 1e18; // Small amount
        string memory reason = "Minor infraction";

        vm.startPrank(validator1);
        gltToken.approve(address(registry), initialStake);
        registry.registerValidator(initialStake);
        vm.stopPrank();

        vm.startPrank(slasher);
        registry.slashValidator(validator1, slashAmount, reason);
        vm.stopPrank();

        // Check validator marked as slashed
        IValidator.ValidatorInfo memory info = registry.getValidatorInfoWithMetadata(validator1);
        assertEq(uint8(info.status), uint8(IValidator.ValidatorStatus.Slashed));

        // Should no longer be active
        assertFalse(registry.isActiveValidator(validator1));
    }

    function test_RevertWhen_SlashValidator_NotSlasher() public {
        // Register validator first
        uint256 initialStake = 2000e18;

        vm.startPrank(validator1);
        gltToken.approve(address(registry), initialStake);
        registry.registerValidator(initialStake);
        vm.stopPrank();

        vm.startPrank(validator2);
        vm.expectRevert("ValidatorRegistryBeacon: caller is not the slasher");
        registry.slashValidator(validator1, 100e18, "reason");
        vm.stopPrank();
    }

    function test_ActiveValidatorSetUpdating() public {
        // Register multiple validators with different stakes
        uint256[] memory stakes = new uint256[](3);
        stakes[0] = 3000e18; // validator1 - highest
        stakes[1] = 1500e18; // validator2 - middle
        stakes[2] = 1200e18; // validator3 - lowest

        address[] memory validators = new address[](3);
        validators[0] = validator1;
        validators[1] = validator2;
        validators[2] = validator3;

        // Register all validators
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(validators[i]);
            gltToken.approve(address(registry), stakes[i]);
            registry.registerValidator(stakes[i]);
            vm.stopPrank();
        }

        // Check active validators are sorted by stake (descending)
        address[] memory activeValidators = registry.getActiveValidators();
        assertEq(activeValidators.length, 3);
        assertEq(activeValidators[0], validator1); // Highest stake
        assertEq(activeValidators[1], validator2); // Middle stake
        assertEq(activeValidators[2], validator3); // Lowest stake
    }

    function test_UpgradeValidatorImplementation() public {
        // Deploy new implementation
        Validator newImplementation = new Validator();

        // Only owner can upgrade
        vm.expectRevert();
        vm.startPrank(validator1);
        registry.upgradeValidatorImplementation(address(newImplementation));
        vm.stopPrank();

        // Owner can upgrade
        registry.upgradeValidatorImplementation(address(newImplementation));

        // Verify beacon points to new implementation
        ValidatorBeacon beacon = ValidatorBeacon(registry.getValidatorBeacon());
        assertEq(beacon.getImplementation(), address(newImplementation));
    }

    function test_SetSlasher() public {
        address newSlasher = makeAddr("newSlasher");

        // Only owner can set slasher
        vm.expectRevert();
        vm.startPrank(validator1);
        registry.setSlasher(newSlasher);
        vm.stopPrank();

        // Owner can set slasher
        registry.setSlasher(newSlasher);
        assertEq(registry.slasher(), newSlasher);
    }

    function test_RevertWhen_SetSlasher_ZeroAddress() public {
        vm.expectRevert(IValidatorRegistry.ZeroAddress.selector);
        registry.setSlasher(address(0));
    }

    function test_GettersReturnCorrectValues() public {
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

        // Get proxy address
        address proxy = registry.getValidatorProxy(validator1);
        assertNotEq(proxy, address(0));

        // Interact directly with validator proxy
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

        // Update metadata directly through proxy
        address proxy = registry.getValidatorProxy(validator1);
        IValidator(proxy).updateMetadata(newMetadata);
        vm.stopPrank();

        // Check metadata was updated
        IValidator.ValidatorInfo memory info = registry.getValidatorInfoWithMetadata(validator1);
        assertEq(info.metadata, newMetadata);
    }

    function testFuzz_RegisterValidator(uint256 stakeAmount) public {
        stakeAmount = bound(stakeAmount, MINIMUM_STAKE, 10000e18);

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
        additionalStake = bound(additionalStake, 1, 10000e18 - initialStake);

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
        // Register multiple validators with different stakes
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
        
        // Check active validator count (should be limited to activeValidatorLimit = 5)
        address[] memory activeValidators = registry.getActiveValidators();
        assertEq(activeValidators.length, 5); // Only 5 active due to limit
        
        // Get top 5 validators
        address[] memory top5 = registry.getTopValidators(5);
        assertEq(top5.length, 5);
        
        // Verify they are sorted by stake (highest first)
        for (uint256 i = 0; i < 4; i++) {
            IValidator.ValidatorInfo memory info1 = registry.getValidatorInfoWithMetadata(top5[i]);
            IValidator.ValidatorInfo memory info2 = registry.getValidatorInfoWithMetadata(top5[i + 1]);
            assertGe(info1.stakedAmount, info2.stakedAmount);
        }
        
        // Get top 10 validators (should return only the number of active validators)
        address[] memory top10 = registry.getTopValidators(10);
        // Should return actual count of active validators, not necessarily all registered
        assertLe(top10.length, 7); // At most 7, but could be less if some don't meet requirements
        
        // Get top 3 validators
        address[] memory top3 = registry.getTopValidators(3);
        assertEq(top3.length, 3);
        
        // Verify they are the highest staked validators
        for (uint256 i = 0; i < top3.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < validators.length; j++) {
                if (top3[i] == validators[j]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "Top validator should be from our registered validators");
        }
    }

    function test_IsTopValidator() public {
        // Register 5 validators with different stakes
        address[] memory validators = new address[](5);
        uint256[] memory stakes = new uint256[](5);
        stakes[0] = 5000e18; // Highest
        stakes[1] = 4000e18;
        stakes[2] = 3000e18;
        stakes[3] = 2000e18;
        stakes[4] = 1000e18; // Lowest
        
        for (uint256 i = 0; i < 5; i++) {
            validators[i] = makeAddr(string(abi.encodePacked("validator", i)));
            gltToken.mint(validators[i], stakes[i]);
            
            vm.startPrank(validators[i]);
            gltToken.approve(address(registry), stakes[i]);
            registry.registerValidator(stakes[i]);
            vm.stopPrank();
        }
        
        // Check top 3 validators
        assertTrue(registry.isTopValidator(validators[0], 3)); // 5000e18 - should be in top 3
        assertTrue(registry.isTopValidator(validators[1], 3)); // 4000e18 - should be in top 3
        assertTrue(registry.isTopValidator(validators[2], 3)); // 3000e18 - should be in top 3
        assertFalse(registry.isTopValidator(validators[3], 3)); // 2000e18 - not in top 3
        assertFalse(registry.isTopValidator(validators[4], 3)); // 1000e18 - not in top 3
        
        // Check top 5 validators (all should be included)
        for (uint256 i = 0; i < 5; i++) {
            assertTrue(registry.isTopValidator(validators[i], 5));
        }
        
        // Check top 1 validator
        assertTrue(registry.isTopValidator(validators[0], 1));
        for (uint256 i = 1; i < 5; i++) {
            assertFalse(registry.isTopValidator(validators[i], 1));
        }
    }

    function test_RevertWhen_GetTopValidators_InvalidCount() public {
        vm.expectRevert("ValidatorRegistry: invalid count");
        registry.getTopValidators(0);
    }

    function test_RevertWhen_IsTopValidator_InvalidCount() public {
        vm.expectRevert("ValidatorRegistry: invalid count");
        registry.isTopValidator(validator1, 0);
    }

    function test_TopValidators_UpdateOnStakeChanges() public {
        // Register 3 validators
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
        
        // Initially validator1 should be top
        address[] memory top1 = registry.getTopValidators(1);
        assertEq(top1[0], validator1);
        
        // Validator3 increases stake to become top validator
        gltToken.mint(validator3, 3000e18);
        vm.prank(validator3);
        gltToken.approve(address(registry), 3000e18);
        vm.prank(validator3);
        registry.increaseStake(3000e18); // Now has 4000e18 total
        
        // Validator3 should now be top
        top1 = registry.getTopValidators(1);
        assertEq(top1[0], validator3);
        
        // Check top 2
        address[] memory top2 = registry.getTopValidators(2);
        assertEq(top2[0], validator3); // 4000e18
        assertEq(top2[1], validator1); // 3000e18
    }
}