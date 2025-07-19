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
     * @dev Block number when unstaking was requested.
     */
    uint256 public unstakeRequestBlock;

    /**
     * @dev Timestamp when the validator was activated.
     */
    uint256 public activationTime;

    /**
     * @dev Validator metadata (can include node info, contact details, etc.).
     */
    string public metadata;

    /**
     * @dev Amount requested for unstaking.
     */
    uint256 public unstakeAmount;

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
    ) external initializer {
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
        activationTime = block.timestamp;

        // Tokens are transferred by the registry during initialization
        emit StakeIncreased(_initialStake, _initialStake);
        emit MetadataUpdated(_metadata);
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

        unstakeAmount = amount;
        unstakeRequestBlock = block.number;

        // If unstaking everything, mark as unstaking
        if (remainingStake == 0) {
            status = ValidatorStatus.Unstaking;
        }

        emit UnstakeRequested(amount, block.number);
    }

    /**
     * @inheritdoc IValidator
     */
    function completeUnstake() external onlyRegistry {
        if (unstakeAmount == 0) {
            revert ZeroAmount();
        }
        if (block.number < unstakeRequestBlock + BONDING_PERIOD) {
            revert BondingPeriodNotMet();
        }

        uint256 amountToUnstake = unstakeAmount;
        stakedAmount -= amountToUnstake;
        unstakeAmount = 0;

        // If fully unstaked, mark as inactive
        if (stakedAmount == 0) {
            status = ValidatorStatus.Inactive;
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
        if (amount > stakedAmount) {
            amount = stakedAmount;
        }

        stakedAmount -= amount;

        // If stake falls below minimum, mark as slashed
        if (stakedAmount < MINIMUM_STAKE && stakedAmount > 0) {
            status = ValidatorStatus.Slashed;
        } else if (stakedAmount == 0) {
            status = ValidatorStatus.Inactive;
        }

        // Slashed tokens remain in this contract (could be transferred to treasury in future)

        emit ValidatorSlashed(amount, reason);
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
            unstakeRequestTime: unstakeRequestBlock,
            activationTime: activationTime,
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
        return unstakeAmount > 0 && block.number >= unstakeRequestBlock + BONDING_PERIOD;
    }
}