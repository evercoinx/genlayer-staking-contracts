// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IValidatorRegistry } from "./interfaces/IValidatorRegistry.sol";
import { IValidator } from "./interfaces/IValidator.sol";
import { ValidatorBeacon } from "./ValidatorBeacon.sol";
import { Validator } from "./Validator.sol";

/**
 * @title ValidatorRegistry
 * @dev Manages validator registration using beacon proxy pattern where each validator
 * gets their own beacon proxy contract to hold stake and metadata.
 */
contract ValidatorRegistry is IValidatorRegistry, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    /**
     * @dev The GLT token used for staking.
     */
    IERC20 public immutable gltToken;

    /**
     * @dev The beacon contract that manages validator implementation.
     */
    ValidatorBeacon public immutable validatorBeacon;

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
     * @dev Number of top validators to select for consensus (configurable).
     */
    uint256 public activeValidatorLimit = 5;

    /**
     * @dev Slash percentage (10%).
     */
    uint256 public constant SLASH_PERCENTAGE = 10;

    /**
     * @dev Mapping from validator address to their beacon proxy contract.
     */
    mapping(address => address) public validatorProxies;

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
        require(msg.sender == slasher, "ValidatorRegistryBeacon: caller is not the slasher");
        _;
    }

    /**
     * @dev Modifier to ensure validator has a proxy.
     */
    modifier validatorExists(address validator) {
        if (validatorProxies[validator] == address(0)) {
            revert ValidatorNotFound();
        }
        _;
    }

    /**
     * @dev Initializes the ValidatorRegistryBeacon.
     * @param _gltToken The address of the GLT token contract.
     * @param _slasher The address authorized to slash validators.
     */
    constructor(address _gltToken, address _slasher) Ownable(msg.sender) {
        if (_gltToken == address(0) || _slasher == address(0)) {
            revert ZeroAddress();
        }
        gltToken = IERC20(_gltToken);
        slasher = _slasher;

        // Deploy validator implementation
        Validator validatorImplementation = new Validator();

        // Deploy beacon
        validatorBeacon = new ValidatorBeacon(address(validatorImplementation), address(this));
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
     * @dev Sets the number of active validators. Only callable by owner.
     * @param newLimit The new active validator limit (must be between 1 and MAX_VALIDATORS).
     */
    function setActiveValidatorLimit(uint256 newLimit) external onlyOwner {
        require(newLimit > 0 && newLimit <= MAX_VALIDATORS, "Invalid validator limit");
        activeValidatorLimit = newLimit;
        _updateActiveValidatorSet();
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function registerValidator(uint256 stakeAmount) external {
        return registerValidatorWithMetadata(stakeAmount, "");
    }

    /**
     * @dev Registers a new validator with metadata using beacon proxy pattern.
     * @param stakeAmount The amount of GLT tokens to stake.
     * @param metadata The validator metadata.
     */
    function registerValidatorWithMetadata(uint256 stakeAmount, string memory metadata) public nonReentrant {
        if (stakeAmount < MINIMUM_STAKE) {
            revert InsufficientStake();
        }
        if (validatorProxies[msg.sender] != address(0)) {
            revert ValidatorAlreadyRegistered();
        }

        // Transfer GLT tokens to registry first
        gltToken.safeTransferFrom(msg.sender, address(this), stakeAmount);

        // Create beacon proxy for the validator
        BeaconProxy validatorProxy = new BeaconProxy(
            address(validatorBeacon),
            abi.encodeWithSelector(
                IValidator.initialize.selector,
                msg.sender,
                stakeAmount,
                metadata,
                address(gltToken),
                address(this)
            )
        );

        // Transfer tokens to the validator proxy
        gltToken.safeTransfer(address(validatorProxy), stakeAmount);

        // Store the mapping
        validatorProxies[msg.sender] = address(validatorProxy);
        validatorList.push(msg.sender);
        totalStaked += stakeAmount;

        emit ValidatorRegistered(msg.sender, stakeAmount);
        emit ValidatorProxyCreated(msg.sender, address(validatorProxy), stakeAmount);

        // Update active validator set
        _updateActiveValidatorSet();
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function increaseStake(uint256 additionalStake) external validatorExists(msg.sender) nonReentrant {
        if (additionalStake == 0) {
            revert ZeroAmount();
        }

        IValidator validator = IValidator(validatorProxies[msg.sender]);
        
        // Check if validator is active
        if (validator.getStatus() != IValidator.ValidatorStatus.Active) {
            revert InvalidValidatorStatus();
        }

        // Transfer tokens from validator to registry first
        gltToken.safeTransferFrom(msg.sender, address(this), additionalStake);
        
        // Call the validator proxy to increase stake
        validator.increaseStake(additionalStake);
        
        // Transfer tokens from registry to validator proxy
        gltToken.safeTransfer(address(validator), additionalStake);
        
        totalStaked += additionalStake;

        emit StakeIncreased(msg.sender, additionalStake, validator.getStakedAmount());

        // Update active validator set
        _updateActiveValidatorSet();
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function requestUnstake(uint256 unstakeAmount) external validatorExists(msg.sender) nonReentrant {
        IValidator validator = IValidator(validatorProxies[msg.sender]);
        
        uint256 currentStake = validator.getStakedAmount();
        uint256 remainingStake = currentStake - unstakeAmount;

        // Call the validator proxy to request unstake
        validator.requestUnstake(unstakeAmount);

        emit UnstakeRequested(msg.sender, unstakeAmount, block.timestamp);

        // Update active validator set if fully unstaking
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
        
        // Call the validator proxy to complete unstake
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
    ) external onlySlasher nonReentrant validatorExists(validatorAddress) {
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

        // Call the validator proxy to slash
        validator.slash(actualSlashAmount, reason);
        
        totalStaked -= actualSlashAmount;

        emit ValidatorSlashed(validatorAddress, actualSlashAmount, reason);

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
        // Create arrays for eligible validators
        address[] memory eligibleValidators = new address[](validatorList.length);
        uint256[] memory stakes = new uint256[](validatorList.length);
        uint256 eligibleCount = 0;

        // Collect eligible validators
        for (uint256 i = 0; i < validatorList.length; i++) {
            address validatorAddr = validatorList[i];
            IValidator validator = IValidator(validatorProxies[validatorAddr]);
            
            if (validator.getStatus() == IValidator.ValidatorStatus.Active && 
                validator.getStakedAmount() >= MINIMUM_STAKE) {
                eligibleValidators[eligibleCount] = validatorAddr;
                stakes[eligibleCount] = validator.getStakedAmount();
                eligibleCount++;
            }
        }

        // Sort validators by stake amount (descending)
        if (eligibleCount > 1) {
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
        }

        // Select top validators up to activeValidatorLimit
        uint256 activeCount = eligibleCount < activeValidatorLimit ? eligibleCount : activeValidatorLimit;
        delete activeValidators;
        for (uint256 i = 0; i < activeCount; i++) {
            activeValidators.push(eligibleValidators[i]);
        }

        emit ActiveValidatorSetUpdated(activeValidators, block.number);
    }

    /**
     * @inheritdoc IValidatorRegistry
     */
    function getValidatorInfo(address validator) external view validatorExists(validator) returns (ValidatorInfo memory) {
        IValidator validatorContract = IValidator(validatorProxies[validator]);
        IValidator.ValidatorInfo memory info = validatorContract.getValidatorInfo();
        
        // Convert to IValidatorRegistry.ValidatorInfo format
        return ValidatorInfo({
            validatorAddress: info.validatorAddress,
            stakedAmount: info.stakedAmount,
            status: ValidatorStatus(uint8(info.status)),
            unstakeRequestTime: info.unstakeRequestTime,
            activationTime: info.activationTime
        });
    }

    /**
     * @dev Returns the validator info with metadata.
     * @param validator The validator address.
     * @return info The validator info including metadata.
     */
    function getValidatorInfoWithMetadata(address validator) external view validatorExists(validator) returns (IValidator.ValidatorInfo memory info) {
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
     * @dev Upgrades the validator implementation for all beacon proxies.
     * @param newImplementation The new validator implementation address.
     */
    function upgradeValidatorImplementation(address newImplementation) external onlyOwner {
        validatorBeacon.upgradeImplementation(newImplementation);
    }

    /**
     * @dev Returns the top N validators based on stake amount.
     * @param n The number of top validators to return.
     * @return topValidators The addresses of the top N validators.
     */
    function getTopValidators(uint256 n) external view returns (address[] memory topValidators) {
        require(n > 0, "ValidatorRegistry: invalid count");
        
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
        require(n > 0, "ValidatorRegistry: invalid count");
        
        uint256 count = n < activeValidators.length ? n : activeValidators.length;
        
        for (uint256 i = 0; i < count; i++) {
            if (activeValidators[i] == validator) {
                return true;
            }
        }
        return false;
    }
}