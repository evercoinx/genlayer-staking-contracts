// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";

/**
 * @title ValidatorRegistry
 * @dev Manages validator registration, staking, and selection for the GenLayer consensus system.
 * Validators must stake a minimum amount of GLT tokens to participate in consensus.
 */
contract ValidatorRegistry is IValidatorRegistry, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /**
     * @dev The GLT token used for staking.
     */
    IERC20 public immutable gltToken;

    /**
     * @dev Minimum stake required to become a validator (1000 GLT).
     */
    uint256 public constant MINIMUM_STAKE = 1000e18;

    /**
     * @dev Bonding period for unstaking (7 days).
     */
    uint256 public constant BONDING_PERIOD = 7 days;

    /**
     * @dev Maximum number of active validators.
     */
    uint256 public constant MAX_VALIDATORS = 100;

    /**
     * @dev Slash percentage (10%).
     */
    uint256 public constant SLASH_PERCENTAGE = 10;

    /**
     * @dev Mapping from validator address to their information.
     */
    mapping(address => ValidatorInfo) private validators;

    /**
     * @dev Array of all registered validator addresses.
     */
    address[] private validatorList;

    /**
     * @dev Array of currently active validators.
     */
    address[] private activeValidators;

    /**
     * @dev Total amount staked across all validators.
     */
    uint256 private totalStaked;

    /**
     * @dev Address authorized to slash validators.
     */
    address public slasher;

    /**
     * @dev Modifier to restrict functions to only the slasher.
     */
    modifier onlySlasher() {
        require(msg.sender == slasher, "ValidatorRegistry: caller is not the slasher");
        _;
    }

    /**
     * @dev Initializes the ValidatorRegistry with the GLT token address.
     * @param _gltToken The address of the GLT token contract.
     * @param _slasher The address authorized to slash validators.
     */
    constructor(address _gltToken, address _slasher) Ownable(msg.sender) {
        if (_gltToken == address(0) || _slasher == address(0)) {
            revert ZeroAddress();
        }
        gltToken = IERC20(_gltToken);
        slasher = _slasher;
    }

    /**
     * @dev Sets a new slasher address. Only callable by owner.
     * @param newSlasher The address to grant slashing privileges to.
     */
    function setSlasher(address newSlasher) external onlyOwner {
        if (newSlasher == address(0)) {
            revert ZeroAddress();
        }
        slasher = newSlasher;
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function registerValidator(uint256 stakeAmount) external nonReentrant {
        if (stakeAmount < MINIMUM_STAKE) {
            revert InsufficientStake();
        }
        if (validators[msg.sender].validatorAddress != address(0)) {
            revert ValidatorAlreadyRegistered();
        }

        // Transfer GLT tokens from the validator
        gltToken.safeTransferFrom(msg.sender, address(this), stakeAmount);

        // Create validator info
        validators[msg.sender] = ValidatorInfo({
            validatorAddress: msg.sender,
            stakedAmount: stakeAmount,
            status: ValidatorStatus.Active,
            unstakeRequestTime: 0,
            activationTime: block.timestamp
        });

        validatorList.push(msg.sender);
        totalStaked += stakeAmount;

        emit ValidatorRegistered(msg.sender, stakeAmount);

        // Update active validator set
        _updateActiveValidatorSet();
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function increaseStake(uint256 additionalStake) external nonReentrant {
        ValidatorInfo storage validator = validators[msg.sender];
        if (validator.validatorAddress == address(0)) {
            revert ValidatorNotFound();
        }
        if (additionalStake == 0) {
            revert ZeroAmount();
        }
        if (validator.status != ValidatorStatus.Active) {
            revert InvalidValidatorStatus();
        }

        // Transfer additional GLT tokens
        gltToken.safeTransferFrom(msg.sender, address(this), additionalStake);

        validator.stakedAmount += additionalStake;
        totalStaked += additionalStake;

        emit StakeIncreased(msg.sender, additionalStake, validator.stakedAmount);

        // Update active validator set
        _updateActiveValidatorSet();
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function requestUnstake(uint256 unstakeAmount) external nonReentrant {
        ValidatorInfo storage validator = validators[msg.sender];
        if (validator.validatorAddress == address(0)) {
            revert ValidatorNotFound();
        }
        if (unstakeAmount == 0) {
            revert ZeroAmount();
        }
        if (unstakeAmount > validator.stakedAmount) {
            revert UnstakeExceedsStake();
        }
        if (validator.status != ValidatorStatus.Active) {
            revert InvalidValidatorStatus();
        }

        // Check if remaining stake would be below minimum
        uint256 remainingStake = validator.stakedAmount - unstakeAmount;
        if (remainingStake > 0 && remainingStake < MINIMUM_STAKE) {
            revert InsufficientStake();
        }

        // If unstaking everything, mark as unstaking
        if (remainingStake == 0) {
            validator.status = ValidatorStatus.Unstaking;
        }

        validator.unstakeRequestTime = block.timestamp;

        emit UnstakeRequested(msg.sender, unstakeAmount, block.timestamp);

        // Update active validator set if fully unstaking
        if (remainingStake == 0) {
            _updateActiveValidatorSet();
        }
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function completeUnstake() external nonReentrant {
        ValidatorInfo storage validator = validators[msg.sender];
        if (validator.validatorAddress == address(0)) {
            revert ValidatorNotFound();
        }
        if (validator.status != ValidatorStatus.Unstaking) {
            revert InvalidValidatorStatus();
        }
        if (block.timestamp < validator.unstakeRequestTime + BONDING_PERIOD) {
            revert BondingPeriodNotMet();
        }

        uint256 unstakeAmount = validator.stakedAmount;
        validator.stakedAmount = 0;
        validator.status = ValidatorStatus.Inactive;
        totalStaked -= unstakeAmount;

        // Transfer GLT tokens back to the validator
        gltToken.safeTransfer(msg.sender, unstakeAmount);

        emit UnstakeCompleted(msg.sender, unstakeAmount);
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function slashValidator(
        address validatorAddress,
        uint256 slashAmount,
        string calldata reason
    ) external onlySlasher nonReentrant {
        ValidatorInfo storage validator = validators[validatorAddress];
        if (validator.validatorAddress == address(0)) {
            revert ValidatorNotFound();
        }
        if (validator.status == ValidatorStatus.Slashed || validator.status == ValidatorStatus.Inactive) {
            revert InvalidValidatorStatus();
        }
        if (slashAmount > validator.stakedAmount) {
            slashAmount = validator.stakedAmount;
        }

        validator.stakedAmount -= slashAmount;
        totalStaked -= slashAmount;

        // If stake falls below minimum, mark as slashed
        if (validator.stakedAmount < MINIMUM_STAKE) {
            validator.status = ValidatorStatus.Slashed;
        }

        emit ValidatorSlashed(validatorAddress, slashAmount, reason);

        // Update active validator set
        _updateActiveValidatorSet();
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function updateActiveValidatorSet() external {
        _updateActiveValidatorSet();
    }

    /**
     * @dev Internal function to update the active validator set based on stake amounts.
     */
    function _updateActiveValidatorSet() private {
        // Create array of eligible validators
        address[] memory eligibleValidators = new address[](validatorList.length);
        uint256[] memory stakes = new uint256[](validatorList.length);
        uint256 eligibleCount = 0;

        // Collect eligible validators
        for (uint256 i = 0; i < validatorList.length; i++) {
            ValidatorInfo memory validator = validators[validatorList[i]];
            if (validator.status == ValidatorStatus.Active && validator.stakedAmount >= MINIMUM_STAKE) {
                eligibleValidators[eligibleCount] = validator.validatorAddress;
                stakes[eligibleCount] = validator.stakedAmount;
                eligibleCount++;
            }
        }

        // Sort validators by stake amount (descending)
        for (uint256 i = 0; i < eligibleCount - 1; i++) {
            for (uint256 j = 0; j < eligibleCount - i - 1; j++) {
                if (stakes[j] < stakes[j + 1]) {
                    // Swap stakes
                    uint256 tempStake = stakes[j];
                    stakes[j] = stakes[j + 1];
                    stakes[j + 1] = tempStake;
                    // Swap addresses
                    address tempAddr = eligibleValidators[j];
                    eligibleValidators[j] = eligibleValidators[j + 1];
                    eligibleValidators[j + 1] = tempAddr;
                }
            }
        }

        // Select top validators up to MAX_VALIDATORS
        uint256 activeCount = eligibleCount < MAX_VALIDATORS ? eligibleCount : MAX_VALIDATORS;
        delete activeValidators;
        for (uint256 i = 0; i < activeCount; i++) {
            activeValidators.push(eligibleValidators[i]);
        }

        emit ActiveValidatorSetUpdated(activeValidators, block.number);
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function getValidatorInfo(address validator) external view returns (ValidatorInfo memory) {
        ValidatorInfo memory info = validators[validator];
        if (info.validatorAddress == address(0)) {
            revert ValidatorNotFound();
        }
        return info;
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function getActiveValidators() external view returns (address[] memory) {
        return activeValidators;
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function getTotalValidators() external view returns (uint256) {
        return validatorList.length;
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function getTotalStake() external view returns (uint256) {
        return totalStaked;
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function isActiveValidator(address validator) external view returns (bool) {
        for (uint256 i = 0; i < activeValidators.length; i++) {
            if (activeValidators[i] == validator) {
                return true;
            }
        }
        return false;
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function getMinimumStake() external pure returns (uint256) {
        return MINIMUM_STAKE;
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function getBondingPeriod() external pure returns (uint256) {
        return BONDING_PERIOD;
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function getMaxValidators() external pure returns (uint256) {
        return MAX_VALIDATORS;
    }
}