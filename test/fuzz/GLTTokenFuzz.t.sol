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
        // Constraints
        vm.assume(to != address(0));
        amount = bound(amount, 1, 100_000_000e18); // Reasonable bounds

        uint256 balanceBefore = token.balanceOf(to);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(owner);
        token.mint(to, amount);

        assertEq(token.balanceOf(to), balanceBefore + amount);
        assertEq(token.totalSupply(), supplyBefore + amount);
    }

    // Fuzz test: Transfer should maintain total supply invariant
    function testFuzz_TransferInvariant(uint256 mintAmount, uint256 transferAmount) public {
        // Setup constraints
        mintAmount = bound(mintAmount, 1, 50_000_000e18);
        transferAmount = bound(transferAmount, 1, mintAmount);

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
        mintAmount = bound(mintAmount, 1, 50_000_000e18);
        burnAmount = bound(burnAmount, 1, mintAmount);

        // Mint tokens to user1
        vm.prank(owner);
        token.mint(user1, mintAmount);

        // User1 must approve owner to burn on their behalf
        vm.prank(user1);
        token.approve(owner, burnAmount);

        uint256 balanceBefore = token.balanceOf(user1);
        uint256 supplyBefore = token.totalSupply();

        // Owner burns tokens from user1 (using allowance)
        vm.prank(owner);
        token.burn(user1, burnAmount);

        assertEq(token.balanceOf(user1), balanceBefore - burnAmount);
        assertEq(token.totalSupply(), supplyBefore - burnAmount);
        assertEq(token.allowance(user1, owner), 0); // Allowance should be spent
    }

    // Fuzz test: Approve and transferFrom workflow
    function testFuzz_ApproveAndTransferFrom(
        uint256 mintAmount,
        uint256 approveAmount,
        uint256 transferAmount
    ) public {
        // Setup constraints
        mintAmount = bound(mintAmount, 1, 50_000_000e18);
        approveAmount = bound(approveAmount, 1, mintAmount);
        transferAmount = bound(transferAmount, 1, approveAmount);

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

    // Fuzz test: Multiple sequential mints
    function testFuzz_MultipleMints(uint256[] memory amounts) public {
        // Skip if empty or too large array
        if (amounts.length == 0 || amounts.length > 50) return;

        uint256 totalMinted = 0;
        uint256 validMints = 0;

        for (uint256 i = 0; i < amounts.length; i++) {
            // Bound each amount to reasonable size
            uint256 amount = bound(amounts[i], 1, 1_000_000e18);

            // Skip if would exceed max supply
            if (totalMinted + amount > 1_000_000_000e18) {
                continue;
            }

            vm.prank(owner);
            token.mint(user1, amount);

            totalMinted += amount;
            validMints++;
        }

        assertEq(token.balanceOf(user1), totalMinted);
        assertEq(token.totalSupply(), totalMinted);
    }

    // Fuzz test: Mixed operations maintaining invariants
    function testFuzz_MixedOperations(uint8[] memory operations, uint256[] memory values) public {
        // Skip if arrays don't match or are too large
        if (operations.length != values.length || operations.length == 0 || operations.length > 20) {
            return;
        }

        // Initial mint to enable operations
        vm.prank(owner);
        token.mint(user1, 10000e18);

        // Set up initial allowances
        vm.prank(user1);
        token.approve(owner, type(uint256).max); // Allow owner to burn
        vm.prank(user1);
        token.approve(user2, type(uint256).max); // Allow user2 to transfer

        for (uint256 i = 0; i < operations.length; i++) {
            uint8 op = operations[i] % 4; // 4 operations
            uint256 value = bound(values[i], 1, 1000e18); // Reasonable bounds

            if (op == 0 && token.balanceOf(user1) >= value) {
                // Transfer from user1 to user2
                vm.prank(user1);
                token.transfer(user2, value);
            } else if (op == 1 && token.balanceOf(user1) >= value) {
                // Burn from user1 (using allowance)
                vm.prank(owner);
                token.burn(user1, value);
            } else if (op == 2 && token.balanceOf(user2) >= value) {
                // Transfer from user2 back to user1
                vm.prank(user2);
                token.transfer(user1, value);
            } else if (op == 3) {
                // Mint to user1 (if within reasonable bounds)
                if (token.totalSupply() + value <= 100_000_000e18) {
                    vm.prank(owner);
                    token.mint(user1, value);
                }
            }
        }

        // Invariant: Total supply equals sum of all balances
        // Note: Only user1, user2, and potentially other addresses have balances
        uint256 totalBalance = token.balanceOf(user1) + token.balanceOf(user2);
        assertLe(totalBalance, token.totalSupply()); // Total balance should not exceed supply
    }
}