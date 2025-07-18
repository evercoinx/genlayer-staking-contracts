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
    
    // Handler contract for targeted invariant testing
    TokenHandler public handler;
    
    function setUp() public {
        // Deploy contracts
        gltToken = new GLTToken(owner);
        llmOracle = new MockLLMOracle();
        validatorRegistry = new ValidatorRegistry(address(gltToken), owner);
        proposalManager = new ProposalManager(
            address(validatorRegistry),
            address(llmOracle),
            proposalManagerRole
        );
        consensusEngine = new ConsensusEngine(
            address(validatorRegistry),
            address(proposalManager),
            consensusInitiatorRole
        );
        disputeResolver = new DisputeResolver(
            address(gltToken),
            address(validatorRegistry),
            address(proposalManager)
        );
        
        // Set up roles
        validatorRegistry.setSlasher(address(disputeResolver));
        
        // Deploy handler
        handler = new TokenHandler(
            gltToken,
            validatorRegistry,
            disputeResolver
        );
        
        // Target handler for invariant testing
        targetContract(address(handler));
        
        // Label contracts for better trace output
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
     */
    function invariant_BalancesEqualTotalSupply() public view {
        uint256 totalBalances = handler.getTotalTrackedBalances();
        assertEq(totalBalances, gltToken.totalSupply());
    }
    
    /**
     * @dev Invariant: Tokens locked in contracts are accounted for
     */
    function invariant_LockedTokensAccounted() public view {
        uint256 registryBalance = gltToken.balanceOf(address(validatorRegistry));
        uint256 disputeBalance = gltToken.balanceOf(address(disputeResolver));
        uint256 totalStaked = handler.getTotalStaked();
        uint256 totalInDisputes = handler.getTotalInDisputes();
        
        // Registry balance should equal total staked
        assertEq(registryBalance, totalStaked);
        
        // Dispute resolver balance should equal total in disputes
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
    
    // Track all addresses that have received tokens
    address[] public tokenHolders;
    mapping(address => bool) public isTokenHolder;
    
    // Track metrics
    uint256 public totalMinted;
    uint256 public totalBurned;
    uint256 public totalStaked;
    uint256 public totalInDisputes;
    
    // Test actors
    address[] public validators;
    uint256 public nextValidatorId = 1;
    
    constructor(
        GLTToken _gltToken,
        ValidatorRegistry _validatorRegistry,
        DisputeResolver _disputeResolver
    ) {
        gltToken = _gltToken;
        validatorRegistry = _validatorRegistry;
        disputeResolver = _disputeResolver;
    }
    
    /**
     * @dev Mint tokens to a random address
     */
    function mintTokens(uint256 amount) public {
        // Bound amount to prevent overflow
        amount = bound(amount, 1, 100_000_000e18);
        
        // Check if minting would exceed max supply
        if (gltToken.totalSupply() + amount > gltToken.MAX_SUPPLY()) {
            return;
        }
        
        address recipient = address(uint160(nextValidatorId++));
        
        vm.prank(gltToken.owner());
        gltToken.mint(recipient, amount);
        
        // Track holder
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
        // Bound stake amount
        stakeAmount = bound(stakeAmount, 1000e18, 10_000e18);
        
        address validator = address(uint160(nextValidatorId++));
        
        // Mint tokens for validator
        vm.prank(gltToken.owner());
        gltToken.mint(validator, stakeAmount);
        totalMinted += stakeAmount;
        
        // Track holder
        if (!isTokenHolder[validator]) {
            tokenHolders.push(validator);
            isTokenHolder[validator] = true;
        }
        
        // Approve and register
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
        if (tokenHolders.length < 2) return;
        
        fromIndex = fromIndex % tokenHolders.length;
        toIndex = toIndex % tokenHolders.length;
        
        if (fromIndex == toIndex) return;
        
        address from = tokenHolders[fromIndex];
        address to = tokenHolders[toIndex];
        
        uint256 balance = gltToken.balanceOf(from);
        if (balance == 0) return;
        
        amount = bound(amount, 0, balance);
        if (amount == 0) return;
        
        vm.prank(from);
        gltToken.transfer(to, amount);
    }
    
    /**
     * @dev Create a dispute (transfers tokens to DisputeResolver)
     */
    function createDispute(uint256 validatorIndex, uint256 challengeStake) public {
        if (validators.length == 0) return;
        
        validatorIndex = validatorIndex % validators.length;
        address challenger = validators[validatorIndex];
        
        challengeStake = bound(challengeStake, 100e18, 500e18);
        
        uint256 balance = gltToken.balanceOf(challenger);
        if (balance < challengeStake) {
            // Mint more tokens if needed
            vm.prank(gltToken.owner());
            gltToken.mint(challenger, challengeStake);
            totalMinted += challengeStake;
        }
        
        // Approve dispute resolver
        vm.prank(challenger);
        gltToken.approve(address(disputeResolver), challengeStake);
        
        // For this invariant test, we'll track the amount that would go to disputes
        totalInDisputes += challengeStake;
    }
    
    /**
     * @dev Get total balances of all tracked holders
     */
    function getTotalTrackedBalances() public view returns (uint256 total) {
        for (uint256 i = 0; i < tokenHolders.length; i++) {
            total += gltToken.balanceOf(tokenHolders[i]);
        }
        
        // Add contract balances
        total += gltToken.balanceOf(address(validatorRegistry));
        total += gltToken.balanceOf(address(disputeResolver));
        total += gltToken.balanceOf(gltToken.owner());
    }
    
    // Getter functions for invariants
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