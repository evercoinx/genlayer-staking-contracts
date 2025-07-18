// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { GLTToken } from "../../src/GLTToken.sol";
import { IGLTToken } from "../../src/interfaces/IGLTToken.sol";

/**
 * @title GLTTokenFuzzTest
 * @dev Fuzz tests for GLTToken contract
 */
contract GLTTokenFuzzTest is Test {
    GLTToken public token;
    address public owner = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);

    function setUp() public {
        token = new GLTToken(owner);
    }

    // Fuzz test: Minting should correctly update balances and total supply
    function testFuzz_Mint(address to, uint256 amount) public {
        // Assume valid inputs
        vm.assume(to != address(0));
        vm.assume(amount > 0);
        vm.assume(amount <= 1_000_000_000e18 - token.totalSupply()); // Stay within MAX_SUPPLY
        
        uint256 balanceBefore = token.balanceOf(to);
        uint256 supplyBefore = token.totalSupply();
        
        // Check for overflow
        vm.assume(balanceBefore <= type(uint256).max - amount);
        
        vm.prank(owner);
        token.mint(to, amount);
        
        assertEq(token.balanceOf(to), balanceBefore + amount);
        assertEq(token.totalSupply(), supplyBefore + amount);
    }

    // Fuzz test: Transfer should maintain total supply invariant
    function testFuzz_TransferInvariant(uint256 mintAmount, uint256 transferAmount) public {
        // Setup constraints
        vm.assume(mintAmount > 0 && mintAmount <= 100_000_000e18); // 100M tokens max
        vm.assume(transferAmount > 0 && transferAmount <= mintAmount);
        
        // Mint tokens to user1
        vm.prank(owner);
        token.mint(user1, mintAmount);
        
        uint256 totalSupplyBefore = token.totalSupply();
        
        // Transfer from user1 to user2
        vm.prank(user1);
        token.transfer(user2, transferAmount);
        
        // Invariant: Total supply should remain constant
        assertEq(token.totalSupply(), totalSupplyBefore);
        assertEq(token.balanceOf(user1) + token.balanceOf(user2), mintAmount);
    }

    // Fuzz test: Burn should correctly reduce balance and total supply
    function testFuzz_Burn(uint256 mintAmount, uint256 burnAmount) public {
        // Setup constraints
        vm.assume(mintAmount > 0 && mintAmount <= 100_000_000e18); // 100M tokens max
        vm.assume(burnAmount > 0 && burnAmount <= mintAmount);
        
        // Mint tokens
        vm.prank(owner);
        token.mint(user1, mintAmount);
        
        uint256 balanceBefore = token.balanceOf(user1);
        uint256 supplyBefore = token.totalSupply();
        
        // Burn tokens
        vm.prank(owner);
        token.burn(user1, burnAmount);
        
        assertEq(token.balanceOf(user1), balanceBefore - burnAmount);
        assertEq(token.totalSupply(), supplyBefore - burnAmount);
    }

    // Fuzz test: Approve and transferFrom workflow
    function testFuzz_ApproveAndTransferFrom(
        uint256 mintAmount,
        uint256 approveAmount,
        uint256 transferAmount
    ) public {
        // Setup constraints
        vm.assume(mintAmount > 0 && mintAmount <= 100_000_000e18); // 100M tokens max
        vm.assume(approveAmount > 0 && approveAmount <= type(uint256).max);
        vm.assume(transferAmount > 0 && transferAmount <= mintAmount && transferAmount <= approveAmount);
        
        // Mint tokens to user1
        vm.prank(owner);
        token.mint(user1, mintAmount);
        
        // User1 approves user2
        vm.prank(user1);
        token.approve(user2, approveAmount);
        
        assertEq(token.allowance(user1, user2), approveAmount);
        
        // User2 transfers from user1
        vm.prank(user2);
        token.transferFrom(user1, address(0x3), transferAmount);
        
        assertEq(token.balanceOf(user1), mintAmount - transferAmount);
        assertEq(token.balanceOf(address(0x3)), transferAmount);
        assertEq(token.allowance(user1, user2), approveAmount - transferAmount);
    }

    // Fuzz test: Multiple mints should not overflow
    function testFuzz_MultipleMints(uint256[] memory amounts) public {
        vm.assume(amounts.length > 0 && amounts.length <= 100);
        
        uint256 totalMinted = 0;
        
        for (uint256 i = 0; i < amounts.length; i++) {
            // Prevent individual overflows and stay within max supply
            vm.assume(amounts[i] <= 10_000_000e18); // 10M per mint max
            
            // Prevent exceeding max supply
            if (totalMinted > 1_000_000_000e18 - amounts[i]) {
                break;
            }
            
            vm.prank(owner);
            token.mint(user1, amounts[i]);
            
            totalMinted += amounts[i];
        }
        
        assertEq(token.balanceOf(user1), totalMinted);
        assertEq(token.totalSupply(), totalMinted);
    }

    // Fuzz test: Random sequence of operations should maintain invariants
    function testFuzz_RandomOperations(uint8[] memory operations, uint256[] memory values) public {
        vm.assume(operations.length == values.length);
        vm.assume(operations.length > 0 && operations.length <= 50);
        
        // Initial mint (smaller amount to leave room for operations)
        vm.prank(owner);
        token.mint(user1, 10000e18);
        
        for (uint256 i = 0; i < operations.length; i++) {
            uint8 op = operations[i] % 4; // 4 operations
            uint256 value = values[i] % 1000e18; // Cap values
            
            if (value == 0) continue;
            
            if (op == 0 && token.balanceOf(user1) >= value) {
                // Transfer
                vm.prank(user1);
                token.transfer(user2, value);
            } else if (op == 1 && token.balanceOf(user1) >= value) {
                // Burn
                vm.prank(owner);
                token.burn(user1, value);
            } else if (op == 2) {
                // Approve
                vm.prank(user1);
                token.approve(user2, value);
            } else if (op == 3 && token.balanceOf(user2) >= value) {
                // Transfer back
                vm.prank(user2);
                token.transfer(user1, value);
            }
        }
        
        // Invariant: Total supply equals sum of all balances
        // Note: Only user1 and user2 have balances in this test
        assertEq(
            token.totalSupply(),
            token.balanceOf(user1) + token.balanceOf(user2)
        );
    }
}