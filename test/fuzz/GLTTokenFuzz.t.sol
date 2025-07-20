// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { IGLTToken } from "../../src/interfaces/IGLTToken.sol";
import { GLTToken } from "../../src/GLTToken.sol";

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

    function testFuzz_Mint(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 1, 100_000_000e18);

        uint256 balanceBefore = token.balanceOf(to);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(owner);
        token.mint(to, amount);

        assertEq(token.balanceOf(to), balanceBefore + amount);
        assertEq(token.totalSupply(), supplyBefore + amount);
    }

    function testFuzz_TransferInvariant(uint256 mintAmount, uint256 transferAmount) public {
        mintAmount = bound(mintAmount, 1, 50_000_000e18);
        transferAmount = bound(transferAmount, 1, mintAmount);

        vm.prank(owner);
        token.mint(user1, mintAmount);

        uint256 totalSupplyBefore = token.totalSupply();
        vm.prank(user1);
        token.transfer(user2, transferAmount);

        assertEq(token.totalSupply(), totalSupplyBefore);
        assertEq(token.balanceOf(user1) + token.balanceOf(user2), mintAmount);
    }

    function testFuzz_Burn(uint256 mintAmount, uint256 burnAmount) public {
        mintAmount = bound(mintAmount, 1, 50_000_000e18);
        burnAmount = bound(burnAmount, 1, mintAmount);

        vm.prank(owner);
        token.mint(user1, mintAmount);

        vm.prank(user1);
        token.approve(owner, burnAmount);

        uint256 balanceBefore = token.balanceOf(user1);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(owner);
        token.burn(user1, burnAmount);

        assertEq(token.balanceOf(user1), balanceBefore - burnAmount);
        assertEq(token.totalSupply(), supplyBefore - burnAmount);
        assertEq(token.allowance(user1, owner), 0);
    }

    function testFuzz_ApproveAndTransferFrom(
        uint256 mintAmount,
        uint256 approveAmount,
        uint256 transferAmount
    )
        public
    {
        mintAmount = bound(mintAmount, 1, 50_000_000e18);
        approveAmount = bound(approveAmount, 1, mintAmount);
        transferAmount = bound(transferAmount, 1, approveAmount);

        vm.prank(owner);
        token.mint(user1, mintAmount);

        vm.prank(user1);
        token.approve(user2, approveAmount);

        assertEq(token.allowance(user1, user2), approveAmount);

        vm.prank(user2);
        token.transferFrom(user1, address(0x3), transferAmount);

        assertEq(token.balanceOf(user1), mintAmount - transferAmount);
        assertEq(token.balanceOf(address(0x3)), transferAmount);
        assertEq(token.allowance(user1, user2), approveAmount - transferAmount);
    }

    function testFuzz_MultipleMints(uint256[] memory amounts) public {
        if (amounts.length == 0 || amounts.length > 50) return;

        uint256 totalMinted = 0;
        uint256 validMints = 0;

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = bound(amounts[i], 1, 1_000_000e18);

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

    function testFuzz_MixedOperations(uint8[] memory operations, uint256[] memory values) public {
        if (operations.length != values.length || operations.length == 0 || operations.length > 20) {
            return;
        }

        vm.prank(owner);
        token.mint(user1, 10_000e18);

        vm.prank(user1);
        token.approve(owner, type(uint256).max);
        vm.prank(user1);
        token.approve(user2, type(uint256).max);

        for (uint256 i = 0; i < operations.length; i++) {
            uint8 op = operations[i] % 4;
            uint256 value = bound(values[i], 1, 1000e18);

            if (op == 0 && token.balanceOf(user1) >= value) {
                vm.prank(user1);
                token.transfer(user2, value);
            } else if (op == 1 && token.balanceOf(user1) >= value) {
                vm.prank(owner);
                token.burn(user1, value);
            } else if (op == 2 && token.balanceOf(user2) >= value) {
                vm.prank(user2);
                token.transfer(user1, value);
            } else if (op == 3) {
                if (token.totalSupply() + value <= 100_000_000e18) {
                    vm.prank(owner);
                    token.mint(user1, value);
                }
            }
        }

        uint256 totalBalance = token.balanceOf(user1) + token.balanceOf(user2);
        assertLe(totalBalance, token.totalSupply());
    }
}
