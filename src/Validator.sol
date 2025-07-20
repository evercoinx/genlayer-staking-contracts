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

    uint256 public constant MINIMUM_STAKE = 1000e18;
    uint256 public constant BONDING_PERIOD = 1;

    IERC20 public gltToken;
    address public registry;
    address public validatorAddress;
    uint256 public stakedAmount;
    ValidatorStatus public status;

    /**
     * @dev Packed storage for unstaking data.
     * Bits 0-127: unstakeAmount (uint128)
     * Bits 128-191: unstakeRequestBlock (uint64)
     * Bits 192-255: unused
     */
    uint256 private _unstakeData;

    string public metadata;

    modifier bondingPeriodMet() {
        uint256 requestBlock = uint64(_unstakeData >> 128);
        if (block.number < requestBlock + BONDING_PERIOD) {
            revert BondingPeriodNotMet();
        }
        _;
    }

    modifier onlyValidator() {
        if (msg.sender != validatorAddress) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyRegistry() {
        if (msg.sender != registry) {
            revert Unauthorized();
        }
        _;
    }

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

        // Pack unstake data: amount in lower 128 bits, block number in upper bits
        _unstakeData = uint256(uint128(amount)) | (uint256(uint64(block.number)) << 128);

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

        if (stakedAmount == 0) {
            status = ValidatorStatus.Inactive;
        } else {
            status = ValidatorStatus.Active;
        }

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

        uint256 actualSlashAmount = amount > stakedAmount ? stakedAmount : amount;
        stakedAmount -= actualSlashAmount;

        _updateStatusAfterSlash();

        // Slashed tokens remain in this contract
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
            activationTime: 0,
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
