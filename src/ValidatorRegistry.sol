// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IValidator } from "./interfaces/IValidator.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";
import { Validator } from "./Validator.sol";
import { ValidatorBeacon } from "./ValidatorBeacon.sol";

/**
 * @title ValidatorRegistry
 * @dev Manages validator registration using beacon proxy pattern where each validator
 * gets their own beacon proxy contract to hold stake and metadata.
 */
contract ValidatorRegistry is IValidatorRegistry, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable gltToken;
    ValidatorBeacon public immutable validatorBeacon;

    uint256 public constant MINIMUM_STAKE = 1000e18;
    uint256 public constant BONDING_PERIOD = 1;
    uint256 public constant MAX_VALIDATORS = 100;
    uint256 public constant SLASH_PERCENTAGE = 10;

    uint256 public activeValidatorLimit = 5;
    mapping(address => address) public validatorProxies;
    address[] private validatorList;
    address[] private activeValidators;
    uint256 private totalStaked;
    address public slasher;

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
     */
    constructor(address _gltToken, address _slasher) Ownable(msg.sender) {
        require(_gltToken != address(0) && _slasher != address(0), ZeroAddress());
        gltToken = IERC20(_gltToken);
        slasher = _slasher;

        Validator validatorImplementation = new Validator();
        validatorBeacon = new ValidatorBeacon(address(validatorImplementation), address(this));
    }

    /**
     * @dev Sets a new slasher address. Only callable by owner.
     * @param newSlasher The address to grant slashing privileges to.
     */
    function setSlasher(address newSlasher) external onlyOwner {
        require(newSlasher != address(0), ZeroAddress());
        slasher = newSlasher;
    }

    /**
     * @dev Sets the number of active validators. Only callable by owner.
     * @param newLimit The new active validator limit (must be between 1 and MAX_VALIDATORS).
     */
    function setActiveValidatorLimit(uint256 newLimit) external onlyOwner {
        require(newLimit != 0 && newLimit <= MAX_VALIDATORS, InvalidValidatorLimit());
        uint256 oldLimit = activeValidatorLimit;
        activeValidatorLimit = newLimit;
        emit ActiveValidatorLimitChanged(oldLimit, newLimit);
        _updateActiveValidatorSet();
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function registerValidator(uint256 stakeAmount) external {
        registerValidatorWithMetadata(stakeAmount, "");
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function increaseStake(uint256 additionalStake) external validatorExists(msg.sender) nonReentrant {
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
    function requestUnstake(uint256 unstakeAmount) external validatorExists(msg.sender) nonReentrant {
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
    function completeUnstake() external validatorExists(msg.sender) nonReentrant {
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
    function updateActiveValidatorSet() external {
        _updateActiveValidatorSet();
    }

    /**
     * @dev Upgrades the validator implementation for all beacon proxies.
     * @param newImplementation The new validator implementation address.
     */
    function upgradeValidatorImplementation(address newImplementation) external onlyOwner {
        validatorBeacon.upgradeImplementation(newImplementation);
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function getValidatorInfo(address validator)
        external
        view
        validatorExists(validator)
        returns (ValidatorInfo memory)
    {
        IValidator validatorContract = IValidator(validatorProxies[validator]);
        IValidator.ValidatorInfo memory info = validatorContract.getValidatorInfo();

        return ValidatorInfo({
            validatorAddress: info.validatorAddress,
            stakedAmount: info.stakedAmount,
            status: ValidatorStatus(uint8(info.status)),
            unstakeRequestBlock: info.unstakeRequestTime, // Now stores block number
            activationTime: info.activationTime
        });
    }

    /**
     * @dev Returns the validator info with metadata.
     * @param validator The validator address.
     * @return info The validator info including metadata.
     */
    function getValidatorInfoWithMetadata(address validator)
        external
        view
        validatorExists(validator)
        returns (IValidator.ValidatorInfo memory info)
    {
        IValidator validatorContract = IValidator(validatorProxies[validator]);
        return validatorContract.getValidatorInfo();
    }

    /**
     * @dev Returns the beacon proxy address for a validator.
     * @param validator The validator address.
     * @return proxy The beacon proxy address.
     */
    function getValidatorProxy(address validator) external view returns (address proxy) {
        return validatorProxies[validator];
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
     * @dev Returns the current active validator limit.
     * @return The active validator limit.
     */
    function getActiveValidatorLimit() external view returns (uint256) {
        return activeValidatorLimit;
    }

    /**
     * @dev Returns the validator beacon address.
     * @return The beacon address.
     */
    function getValidatorBeacon() external view returns (address) {
        return address(validatorBeacon);
    }

    /**
     * @dev Returns the top N validators based on stake amount.
     * @param n The number of top validators to return.
     * @return topValidators The addresses of the top N validators.
     */
    function getTopValidators(uint256 n) external view returns (address[] memory topValidators) {
        require(n != 0, InvalidCount());

        uint256 count = n < activeValidators.length ? n : activeValidators.length;
        topValidators = new address[](count);

        for (uint256 i = 0; i < count; i++) {
            topValidators[i] = activeValidators[i];
        }
    }

    /**
     * @dev Checks if an address is in the top N validators.
     * @param validator The validator address to check.
     * @param n The size of the top validator set.
     * @return isTop True if the validator is in the top N.
     */
    function isTopValidator(address validator, uint256 n) external view returns (bool isTop) {
        require(n != 0, InvalidCount());

        uint256 count = n < activeValidators.length ? n : activeValidators.length;

        for (uint256 i = 0; i < count; i++) {
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

    /**
     * @dev Registers a new validator with metadata using beacon proxy pattern.
     * @param stakeAmount The amount of GLT tokens to stake.
     * @param metadata The validator metadata.
     */
    function registerValidatorWithMetadata(uint256 stakeAmount, string memory metadata) public nonReentrant {
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
        validatorList.push(msg.sender);
        totalStaked += stakeAmount;

        emit ValidatorRegistered(msg.sender, stakeAmount);
        emit ValidatorProxyCreated(msg.sender, address(validatorProxy), stakeAmount);

        _updateActiveValidatorSet();
    }

    /**
     * @dev Internal function to update the active validator set based on stake amounts.
     */
    function _updateActiveValidatorSet() private {
        address[] memory eligibleValidators = new address[](validatorList.length);
        uint256[] memory stakes = new uint256[](validatorList.length);
        uint256 eligibleCount = 0;

        for (uint256 i = 0; i < validatorList.length; i++) {
            address validatorAddr = validatorList[i];
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

        // Sort validators by stake amount (descending) using insertion sort
        // Insertion sort is more gas efficient for small arrays
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

        uint256 activeCount = eligibleCount < activeValidatorLimit ? eligibleCount : activeValidatorLimit;
        delete activeValidators;
        for (uint256 i = 0; i < activeCount; i++) {
            activeValidators.push(eligibleValidators[i]);
        }

        emit ActiveValidatorSetUpdated(activeValidators, block.number);
    }
}
