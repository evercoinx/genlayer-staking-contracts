// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IValidator } from "./interfaces/IValidator.sol";

/**
 * @title Validator
 * @dev Individual validator implementation contract that holds validator stake and metadata.
 * This contract is deployed behind BeaconProxy instances for each validator.
 */
contract Validator is IValidator, Initializable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    /**
     * @dev Minimum stake required to become a validator (1000 GLT).
     */
    uint256 public constant MINIMUM_STAKE = 1000e18;

    /**
     * @dev Bonding period for unstaking (1 block for simplicity per PRD).
     */
    uint256 public constant BONDING_PERIOD = 1;

    /**
     * @dev The GLT token used for staking.
     */
    IERC20 public gltToken;

    /**
     * @dev The validator registry contract address.
     */
    address public registry;

    /**
     * @dev The validator's address (owner of this validator instance).
     */
    address public validatorAddress;

    /**
     * @dev Amount of GLT tokens staked by this validator.
     */
    uint256 public stakedAmount;

    /**
     * @dev Current status of the validator.
     */
    ValidatorStatus public status;

    /**
     * @dev Packed storage for unstaking data.
     * Bits 0-127: unstakeAmount (uint128)
     * Bits 128-191: unstakeRequestBlock (uint64)
     * Bits 192-255: unused
     */
    uint256 private _unstakeData;

    /**
     * @dev Validator metadata (can include node info, contact details, etc.).
     */
    string public metadata;

    /**
     * @dev Checks if the bonding period has passed for unstaking.
     */
    modifier bondingPeriodMet() {
        uint256 requestBlock = uint64(_unstakeData >> 128);
        if (block.number < requestBlock + BONDING_PERIOD) {
            revert BondingPeriodNotMet();
        }
        _;
    }

    /**
     * @dev Modifier to restrict functions to only the validator owner.
     */
    modifier onlyValidator() {
        if (msg.sender != validatorAddress) {
            revert Unauthorized();
        }
        _;
    }

    /**
     * @dev Modifier to restrict functions to only the registry.
     */
    modifier onlyRegistry() {
        if (msg.sender != registry) {
            revert Unauthorized();
        }
        _;
    }

    /**
     * @dev Disables initializers to prevent direct implementation calls.
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @inheritdoc IValidator
     */
    function initialize(
        address _validatorAddress,
        uint256 _initialStake,
        string calldata _metadata,
        address _gltToken,
        address _registry
    )
        external
        initializer
    {
        __ReentrancyGuard_init();

        if (_validatorAddress == address(0) || _gltToken == address(0) || _registry == address(0)) {
            revert Unauthorized();
        }
        if (_initialStake < MINIMUM_STAKE) {
            revert InsufficientStake();
        }

        validatorAddress = _validatorAddress;
        stakedAmount = _initialStake;
        metadata = _metadata;
        gltToken = IERC20(_gltToken);
        registry = _registry;
        status = ValidatorStatus.Active;

        // Tokens are transferred by the registry during initialization
        emit StakeIncreased(_initialStake, _initialStake);
        if (bytes(_metadata).length > 0) {
            emit MetadataUpdated(_metadata);
        }
    }

    /**
     * @inheritdoc IValidator
     */
    function increaseStake(uint256 amount) external onlyRegistry {
        if (amount == 0) {
            revert ZeroAmount();
        }
        if (status != ValidatorStatus.Active) {
            revert InvalidValidatorStatus();
        }

        // Registry handles token transfers, we just update the stake amount
        stakedAmount += amount;

        emit StakeIncreased(amount, stakedAmount);
    }

    /**
     * @inheritdoc IValidator
     */
    function requestUnstake(uint256 amount) external onlyRegistry {
        if (amount == 0) {
            revert ZeroAmount();
        }
        if (amount > stakedAmount) {
            revert UnstakeExceedsStake();
        }
        if (status != ValidatorStatus.Active) {
            revert InvalidValidatorStatus();
        }

        // Check if remaining stake would be below minimum
        uint256 remainingStake = stakedAmount - amount;
        if (remainingStake > 0 && remainingStake < MINIMUM_STAKE) {
            revert InsufficientStake();
        }

        // Pack unstake data
        _unstakeData = uint256(uint128(amount)) | (uint256(uint64(block.number)) << 128);

        // If unstaking everything, mark as unstaking
        if (remainingStake == 0) {
            status = ValidatorStatus.Unstaking;
        }

        emit UnstakeRequested(amount, block.number);
    }

    /**
     * @inheritdoc IValidator
     */
    function completeUnstake() external onlyRegistry bondingPeriodMet {
        uint256 amountToUnstake = uint128(_unstakeData);
        if (amountToUnstake == 0) {
            revert ZeroAmount();
        }

        stakedAmount -= amountToUnstake;
        _unstakeData = 0; // Clear both amount and block number

        // Update status based on remaining stake
        if (stakedAmount == 0) {
            status = ValidatorStatus.Inactive;
        } else {
            status = ValidatorStatus.Active;
        }

        // Transfer GLT tokens back to the validator
        gltToken.safeTransfer(validatorAddress, amountToUnstake);

        emit UnstakeCompleted(amountToUnstake);
    }

    /**
     * @inheritdoc IValidator
     */
    function slash(uint256 amount, string calldata reason) external onlyRegistry {
        if (status == ValidatorStatus.Slashed || status == ValidatorStatus.Inactive) {
            revert InvalidValidatorStatus();
        }

        // Cap the slash amount to current stake
        uint256 actualSlashAmount = amount > stakedAmount ? stakedAmount : amount;
        stakedAmount -= actualSlashAmount;

        // Update status based on remaining stake
        _updateStatusAfterSlash();

        // Slashed tokens remain in this contract (could be transferred to treasury in future)
        emit ValidatorSlashed(actualSlashAmount, reason);
    }

    /**
     * @dev Updates validator status after slashing based on remaining stake.
     */
    function _updateStatusAfterSlash() private {
        if (stakedAmount == 0) {
            status = ValidatorStatus.Inactive;
        } else if (stakedAmount < MINIMUM_STAKE) {
            status = ValidatorStatus.Slashed;
        }
        // Otherwise status remains Active
    }

    /**
     * @inheritdoc IValidator
     */
    function updateMetadata(string calldata _metadata) external onlyValidator {
        metadata = _metadata;
        emit MetadataUpdated(_metadata);
    }

    /**
     * @inheritdoc IValidator
     */
    function getValidatorInfo() external view returns (ValidatorInfo memory info) {
        return ValidatorInfo({
            validatorAddress: validatorAddress,
            stakedAmount: stakedAmount,
            status: status,
            unstakeRequestTime: uint64(_unstakeData >> 128),
            activationTime: 0, // Removed as not needed
            metadata: metadata
        });
    }

    /**
     * @inheritdoc IValidator
     */
    function getValidatorAddress() external view returns (address) {
        return validatorAddress;
    }

    /**
     * @inheritdoc IValidator
     */
    function getStakedAmount() external view returns (uint256) {
        return stakedAmount;
    }

    /**
     * @inheritdoc IValidator
     */
    function getStatus() external view returns (ValidatorStatus) {
        return status;
    }

    /**
     * @inheritdoc IValidator
     */
    function getMetadata() external view returns (string memory) {
        return metadata;
    }

    /**
     * @inheritdoc IValidator
     */
    function canCompleteUnstake() external view returns (bool) {
        uint256 amount = uint128(_unstakeData);
        uint256 requestBlock = uint64(_unstakeData >> 128);
        return amount > 0 && block.number >= requestBlock + BONDING_PERIOD;
    }

    /**
     * @dev Returns the unstake amount.
     */
    function unstakeAmount() external view returns (uint256) {
        return uint128(_unstakeData);
    }

    /**
     * @dev Returns the unstake request block.
     */
    function unstakeRequestBlock() external view returns (uint256) {
        return uint64(_unstakeData >> 128);
    }
}
