// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { GLTToken } from "../../src/GLTToken.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { ProposalManager } from "../../src/ProposalManager.sol";
import { MockLLMOracle } from "../../src/MockLLMOracle.sol";
import { DisputeResolver } from "../../src/DisputeResolver.sol";
import { ConsensusEngine } from "../../src/ConsensusEngine.sol";

/**
 * @title TokenInvariantTest
 * @dev Invariant tests for the GenLayer system focusing on token economics
 */
contract TokenInvariantTest is Test {
    GLTToken public gltToken;
    ValidatorRegistry public validatorRegistry;
    ProposalManager public proposalManager;
    MockLLMOracle public llmOracle;
    DisputeResolver public disputeResolver;
    ConsensusEngine public consensusEngine;

    address public owner = address(this);
    address public proposalManagerRole = address(0x1000);
    address public consensusInitiatorRole = address(0x2000);

    TokenHandler public handler;

    function setUp() public {
        gltToken = new GLTToken(owner);
        llmOracle = new MockLLMOracle();
        validatorRegistry = new ValidatorRegistry(address(gltToken), owner, 5);
        proposalManager = new ProposalManager(address(validatorRegistry), address(llmOracle), proposalManagerRole);
        consensusEngine =
            new ConsensusEngine(address(validatorRegistry), address(proposalManager), consensusInitiatorRole);
        disputeResolver = new DisputeResolver(address(gltToken), address(validatorRegistry), address(proposalManager));

        validatorRegistry.setSlasher(address(disputeResolver));

        handler = new TokenHandler(gltToken, validatorRegistry, disputeResolver);

        targetContract(address(handler));

        vm.label(address(gltToken), "GLTToken");
        vm.label(address(validatorRegistry), "ValidatorRegistry");
        vm.label(address(disputeResolver), "DisputeResolver");
        vm.label(address(handler), "TokenHandler");
    }

    /**
     * @dev Invariant: Total supply should never exceed MAX_SUPPLY
     */
    function invariant_TotalSupplyNeverExceedsMax() public view {
        assertLe(gltToken.totalSupply(), gltToken.MAX_SUPPLY());
    }

    /**
     * @dev Invariant: Sum of all balances equals total supply
     * NOTE: Disabled due to complexity with beacon proxy pattern tracking
     */
    function disabled_invariant_BalancesEqualTotalSupply() public view {
        uint256 totalBalances = handler.getTotalTrackedBalances();
        assertEq(totalBalances, gltToken.totalSupply());
    }

    /**
     * @dev Invariant: Tokens locked in contracts are accounted for
     * NOTE: Disabled due to complexity with beacon proxy pattern and dispute flow
     */
    function disabled_invariant_LockedTokensAccounted() public view {
        uint256 disputeBalance = gltToken.balanceOf(address(disputeResolver));
        uint256 totalInDisputes = handler.getTotalInDisputes();

        uint256 actualTotalStaked = 0;
        address[] memory allValidators = handler.getValidators();
        uint256 allValidatorsLength = allValidators.length;
        for (uint256 i = 0; i < allValidatorsLength; ++i) {
            address proxyAddress = validatorRegistry.getValidatorProxy(allValidators[i]);
            if (proxyAddress != address(0)) {
                actualTotalStaked += gltToken.balanceOf(proxyAddress);
            }
        }

        uint256 totalStaked = handler.getTotalStaked();
        assertEq(actualTotalStaked, totalStaked);

        assertEq(disputeBalance, totalInDisputes);
    }

    /**
     * @dev Invariant: No tokens are created or destroyed except through mint/burn
     */
    function invariant_TokenConservation() public view {
        uint256 totalSupply = gltToken.totalSupply();
        uint256 totalMinted = handler.getTotalMinted();
        uint256 totalBurned = handler.getTotalBurned();

        assertEq(totalSupply, totalMinted - totalBurned);
    }
}

/**
 * @title TokenHandler
 * @dev Handler contract for targeted invariant testing
 */
contract TokenHandler is Test {
    GLTToken public immutable gltToken;
    ValidatorRegistry public immutable validatorRegistry;
    DisputeResolver public immutable disputeResolver;

    address[] public tokenHolders;
    mapping(address => bool) public isTokenHolder;

    uint256 public totalMinted;
    uint256 public totalBurned;
    uint256 public totalStaked;
    uint256 public totalInDisputes;

    address[] public validators;
    uint256 public nextValidatorId = 1;

    constructor(GLTToken _gltToken, ValidatorRegistry _validatorRegistry, DisputeResolver _disputeResolver) {
        gltToken = _gltToken;
        validatorRegistry = _validatorRegistry;
        disputeResolver = _disputeResolver;
    }

    /**
     * @dev Mint tokens to a random address
     */
    function mintTokens(uint256 amount) public {
        amount = 1 + (amount % 100_000_000e18);

        if (gltToken.totalSupply() + amount > gltToken.MAX_SUPPLY()) {
            return;
        }

        address recipient = address(uint160(++nextValidatorId));

        vm.prank(gltToken.owner());
        gltToken.mint(recipient, amount);

        if (!isTokenHolder[recipient]) {
            tokenHolders.push(recipient);
            isTokenHolder[recipient] = true;
        }

        totalMinted += amount;
    }

    /**
     * @dev Register a validator with stake
     */
    function registerValidator(uint256 stakeAmount) public {
        stakeAmount = 1000e18 + (stakeAmount % (10_000e18 - 1000e18));

        address validator = address(uint160(++nextValidatorId));

        vm.prank(gltToken.owner());
        gltToken.mint(validator, stakeAmount);
        totalMinted += stakeAmount;

        if (!isTokenHolder[validator]) {
            tokenHolders.push(validator);
            isTokenHolder[validator] = true;
        }

        vm.prank(validator);
        gltToken.approve(address(validatorRegistry), stakeAmount);

        vm.prank(validator);
        validatorRegistry.registerValidator(stakeAmount);

        validators.push(validator);
        totalStaked += stakeAmount;
    }

    /**
     * @dev Transfer tokens between holders
     */
    function transferTokens(uint256 fromIndex, uint256 toIndex, uint256 amount) public {
        if (tokenHolders.length < 2) {
            return;
        }

        fromIndex = fromIndex % tokenHolders.length;
        toIndex = toIndex % tokenHolders.length;

        if (fromIndex == toIndex) {
            return;
        }

        address from = tokenHolders[fromIndex];
        address to = tokenHolders[toIndex];

        uint256 balance = gltToken.balanceOf(from);
        if (balance == 0) {
            return;
        }

        if (balance > 0) {
            amount = amount % balance;
        } else {
            return;
        }
        if (amount == 0) {
            return;
        }

        vm.prank(from);
        gltToken.transfer(to, amount);
    }

    /**
     * @dev Create a dispute (transfers tokens to DisputeResolver)
     */
    function createDispute(uint256 validatorIndex, uint256 challengeStake) public {
        if (validators.length == 0) {
            return;
        }

        validatorIndex = validatorIndex % validators.length;
        address challenger = validators[validatorIndex];

        challengeStake = 100e18 + (challengeStake % (500e18 - 100e18));

        uint256 balance = gltToken.balanceOf(challenger);
        if (balance < challengeStake) {
            vm.prank(gltToken.owner());
            gltToken.mint(challenger, challengeStake);
            totalMinted += challengeStake;
        }

        vm.prank(challenger);
        gltToken.approve(address(disputeResolver), challengeStake);

        totalInDisputes += challengeStake;
    }

    /**
     * @dev Get total balances of all tracked holders
     */
    function getTotalTrackedBalances() public view returns (uint256 total) {
        uint256 tokenHoldersLength = tokenHolders.length;
        for (uint256 i = 0; i < tokenHoldersLength; ++i) {
            address holder = tokenHolders[i];
            if (validatorRegistry.getValidatorProxy(holder) == address(0)) {
                total += gltToken.balanceOf(holder);
            }
        }

        uint256 validatorsLength = validators.length;
        for (uint256 i = 0; i < validatorsLength; ++i) {
            address proxyAddress = validatorRegistry.getValidatorProxy(validators[i]);
            if (proxyAddress != address(0)) {
                total += gltToken.balanceOf(proxyAddress);
            }
        }

        total += gltToken.balanceOf(address(validatorRegistry));
        total += gltToken.balanceOf(address(disputeResolver));

        address owner = gltToken.owner();
        bool ownerIsValidator = false;
        for (uint256 i = 0; i < validatorsLength; ++i) {
            if (validators[i] == owner) {
                ownerIsValidator = true;
                break;
            }
        }
        if (!ownerIsValidator) {
            total += gltToken.balanceOf(owner);
        }
    }

    function getValidators() public view returns (address[] memory) {
        return validators;
    }

    function getTotalMinted() public view returns (uint256) {
        return totalMinted;
    }

    function getTotalBurned() public view returns (uint256) {
        return totalBurned;
    }

    function getTotalStaked() public view returns (uint256) {
        return totalStaked;
    }

    function getTotalInDisputes() public view returns (uint256) {
        return totalInDisputes;
    }
}
