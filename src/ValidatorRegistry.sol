// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { IValidator } from "./interfaces/IValidator.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";
import { Validator } from "./Validator.sol";
import { ValidatorBeacon } from "./ValidatorBeacon.sol";

/**
 * @title ValidatorRegistry
 * @dev Manages validator registration using beacon proxy pattern with optimized data structures
 * for O(1) lookups and efficient validator set management.
 */
contract ValidatorRegistry is IValidatorRegistry, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant MINIMUM_STAKE = 1000e18;
    uint256 public constant BONDING_PERIOD = 1;
    uint256 public constant MAX_VALIDATORS = 100;
    uint256 public constant SLASH_PERCENTAGE = 10;

    IERC20 public immutable gltToken;
    ValidatorBeacon public immutable validatorBeacon;

    address public slasher;
    uint256 public activeValidatorLimit;
    mapping(address validator => address proxy) public validatorProxies;
    uint256 public totalStaked;
    EnumerableSet.AddressSet private _allValidators;
    address[] private _sortedActiveValidators;
    mapping(address validator => bool isActive) private _isActiveValidator;

    modifier onlySlasher() {
        require(msg.sender == slasher, CallerNotSlasher());
        _;
    }

    modifier validatorExists(address validator) {
        require(validatorProxies[validator] != address(0), ValidatorNotFound());
        _;
    }

    /**
     * @dev Initializes the ValidatorRegistryBeacon.
     * @param _gltToken The address of the GLT token contract.
     * @param _slasher The address authorized to slash validators.
     * @param _activeValidatorLimit The initial active validator limit.
     */
    constructor(address _gltToken, address _slasher, uint256 _activeValidatorLimit) Ownable(msg.sender) {
        require(_gltToken != address(0), ZeroGLTToken());
        gltToken = IERC20(_gltToken);

        require(_slasher != address(0), ZeroSlasher());
        slasher = _slasher;

        require(_activeValidatorLimit != 0, ZeroActiveValidatorLimit());
        activeValidatorLimit = _activeValidatorLimit;

        Validator validatorImplementation = new Validator();
        validatorBeacon = new ValidatorBeacon(address(validatorImplementation), address(this));
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function setSlasher(address newSlasher) external override onlyOwner {
        require(newSlasher != address(0), ZeroSlasher());
        address oldSlasher = slasher;
        slasher = newSlasher;
        emit SlasherUpdated(oldSlasher, newSlasher);
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function setActiveValidatorLimit(uint256 newLimit) external override onlyOwner {
        require(newLimit != 0 && newLimit <= MAX_VALIDATORS, InvalidValidatorLimit());
        uint256 oldLimit = activeValidatorLimit;
        activeValidatorLimit = newLimit;
        emit ActiveValidatorLimitChanged(oldLimit, newLimit);
        _updateActiveValidatorSet();
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function registerValidator(uint256 stakeAmount) external override {
        registerValidatorWithMetadata(stakeAmount, "");
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function increaseStake(uint256 additionalStake) external override validatorExists(msg.sender) nonReentrant {
        require(additionalStake != 0, ZeroAmount());

        IValidator validator = IValidator(validatorProxies[msg.sender]);

        require(validator.getStatus() == IValidator.ValidatorStatus.Active, InvalidValidatorStatus());

        gltToken.safeTransferFrom(msg.sender, address(this), additionalStake);
        validator.increaseStake(additionalStake);
        gltToken.safeTransfer(address(validator), additionalStake);

        totalStaked += additionalStake;

        emit StakeIncreased(msg.sender, additionalStake, validator.getStakedAmount());
        _updateActiveValidatorSet();
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function requestUnstake(uint256 unstakeAmount) external override validatorExists(msg.sender) nonReentrant {
        IValidator validator = IValidator(validatorProxies[msg.sender]);

        uint256 currentStake = validator.getStakedAmount();
        uint256 remainingStake = currentStake - unstakeAmount;

        validator.requestUnstake(unstakeAmount);

        emit UnstakeRequested(msg.sender, unstakeAmount, block.number);

        // Update active validator set only if fully unstaking
        if (remainingStake == 0) {
            _updateActiveValidatorSet();
        }
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function completeUnstake() external override validatorExists(msg.sender) nonReentrant {
        IValidator validator = IValidator(validatorProxies[msg.sender]);

        uint256 stakeBefore = validator.getStakedAmount();

        validator.completeUnstake();

        uint256 stakeAfter = validator.getStakedAmount();
        uint256 unstakedAmount = stakeBefore - stakeAfter;

        totalStaked -= unstakedAmount;

        emit UnstakeCompleted(msg.sender, unstakedAmount);
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function slashValidator(
        address validatorAddress,
        uint256 slashAmount,
        string calldata reason
    )
        external
        override
        onlySlasher
        nonReentrant
        validatorExists(validatorAddress)
    {
        IValidator validator = IValidator(validatorProxies[validatorAddress]);

        uint256 stakeBefore = validator.getStakedAmount();

        // Calculate actual slash amount (max 10% or total stake)
        uint256 actualSlashAmount = (stakeBefore * SLASH_PERCENTAGE) / 100;
        if (slashAmount < actualSlashAmount) {
            actualSlashAmount = slashAmount;
        }
        if (actualSlashAmount > stakeBefore) {
            actualSlashAmount = stakeBefore;
        }

        validator.slash(actualSlashAmount, reason);
        totalStaked -= actualSlashAmount;

        emit ValidatorSlashed(validatorAddress, actualSlashAmount, reason);
        _updateActiveValidatorSet();
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function updateActiveValidatorSet() external override onlyOwner {
        _updateActiveValidatorSet();
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function upgradeValidatorImplementation(address newImplementation) external override onlyOwner {
        validatorBeacon.upgradeImplementation(newImplementation);
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function getValidatorInfo(address validator)
        external
        view
        override
        validatorExists(validator)
        returns (ValidatorInfo memory)
    {
        IValidator validatorContract = IValidator(validatorProxies[validator]);
        IValidator.ValidatorInfo memory info = validatorContract.getValidatorInfo();

        return ValidatorInfo({
            validatorAddress: info.validatorAddress,
            stakedAmount: info.stakedAmount,
            status: ValidatorStatus(uint8(info.status)),
            unstakeRequestBlock: info.unstakeRequestTime,
            activationTime: info.activationTime
        });
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function getValidatorInfoWithMetadata(address validator)
        external
        view
        override
        validatorExists(validator)
        returns (IValidator.ValidatorInfo memory info)
    {
        IValidator validatorContract = IValidator(validatorProxies[validator]);
        return validatorContract.getValidatorInfo();
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function getValidatorProxy(address validator) external view override returns (address proxy) {
        return validatorProxies[validator];
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function getTotalValidators() external view override returns (uint256) {
        return _allValidators.length();
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function isActiveValidator(address validator) external view override returns (bool) {
        return _isActiveValidator[validator];
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function getActiveValidators() external view override returns (address[] memory) {
        return _sortedActiveValidators;
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function getValidatorBeacon() external view override returns (address) {
        return address(validatorBeacon);
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function getTopValidators(uint256 n) external view override returns (address[] memory topValidators) {
        require(n != 0, InvalidCount());

        uint256 count = n < _sortedActiveValidators.length ? n : _sortedActiveValidators.length;
        topValidators = new address[](count);

        for (uint256 i = 0; i < count; ++i) {
            topValidators[i] = _sortedActiveValidators[i];
        }
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function isTopValidator(address validator, uint256 n) external view override returns (bool isTop) {
        require(n != 0, InvalidCount());

        if (!_isActiveValidator[validator]) {
            return false;
        }

        uint256 count = n < _sortedActiveValidators.length ? n : _sortedActiveValidators.length;

        for (uint256 i = 0; i < count; ++i) {
            if (_sortedActiveValidators[i] == validator) {
                return true;
            }
        }
        return false;
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function registerValidatorWithMetadata(uint256 stakeAmount, string memory metadata) public override nonReentrant {
        require(stakeAmount >= MINIMUM_STAKE, InsufficientStake());
        require(validatorProxies[msg.sender] == address(0), ValidatorAlreadyRegistered());

        gltToken.safeTransferFrom(msg.sender, address(this), stakeAmount);

        BeaconProxy validatorProxy = new BeaconProxy(
            address(validatorBeacon),
            abi.encodeWithSelector(
                IValidator.initialize.selector, msg.sender, stakeAmount, metadata, address(gltToken), address(this)
            )
        );

        gltToken.safeTransfer(address(validatorProxy), stakeAmount);

        validatorProxies[msg.sender] = address(validatorProxy);
        _allValidators.add(msg.sender);
        totalStaked += stakeAmount;

        emit ValidatorRegistered(msg.sender, stakeAmount);
        emit ValidatorProxyCreated(msg.sender, address(validatorProxy), stakeAmount);

        _updateActiveValidatorSet();
    }

    /**
     * @dev Updates the active validator set based on stake amounts.
     */
    function _updateActiveValidatorSet() private {
        uint256 validatorsLength = _allValidators.length();
        address[] memory eligibleValidators = new address[](validatorsLength);
        uint256[] memory stakes = new uint256[](validatorsLength);
        uint256 eligibleCount = 0;

        for (uint256 i = 0; i < validatorsLength; ++i) {
            address validatorAddr = _allValidators.at(i);
            IValidator validator = IValidator(validatorProxies[validatorAddr]);

            if (
                validator.getStatus() == IValidator.ValidatorStatus.Active
                    && validator.getStakedAmount() >= MINIMUM_STAKE
            ) {
                eligibleValidators[eligibleCount] = validatorAddr;
                stakes[eligibleCount] = validator.getStakedAmount();
                eligibleCount++;
            }
        }

        if (eligibleCount > 1) {
            for (uint256 i = 1; i < eligibleCount; i++) {
                uint256 keyStake = stakes[i];
                address keyAddr = eligibleValidators[i];
                uint256 j = i;

                while (j > 0 && stakes[j - 1] < keyStake) {
                    stakes[j] = stakes[j - 1];
                    eligibleValidators[j] = eligibleValidators[j - 1];
                    j--;
                }

                stakes[j] = keyStake;
                eligibleValidators[j] = keyAddr;
            }
        }

        uint256 currentLength = _sortedActiveValidators.length;
        for (uint256 i = 0; i < currentLength; ++i) {
            _isActiveValidator[_sortedActiveValidators[i]] = false;
        }

        uint256 activeCount = eligibleCount < activeValidatorLimit ? eligibleCount : activeValidatorLimit;
        delete _sortedActiveValidators;

        for (uint256 i = 0; i < activeCount; ++i) {
            address validator = eligibleValidators[i];
            _sortedActiveValidators.push(validator);
            _isActiveValidator[validator] = true;
        }

        emit ActiveValidatorSetUpdated(_sortedActiveValidators, block.number);
    }
}
