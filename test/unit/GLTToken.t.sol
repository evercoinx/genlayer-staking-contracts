// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IGLTToken } from "../../src/interfaces/IGLTToken.sol";
import { GLTToken } from "../../src/GLTToken.sol";

/**
 * @title GLTTokenTest
 * @dev Test suite for GLTToken contract.
 */
contract GLTTokenTest is Test {
    GLTToken public token;
    address public owner = makeAddr("owner");
    address public minter = makeAddr("minter");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    uint256 constant INITIAL_SUPPLY = 0;
    uint256 constant MAX_SUPPLY = 1_000_000_000e18;

    event TokensMinted(address indexed to, uint256 amount);
    event TokensBurned(address indexed from, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new GLTToken(minter);
    }

    // Constructor Tests
    function test_Constructor_InitializesCorrectly() public view {
        assertEq(token.name(), "GenLayer Token");
        assertEq(token.symbol(), "GLT");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.MAX_SUPPLY(), MAX_SUPPLY);
        assertEq(token.owner(), address(this));
        assertEq(token.minter(), minter);
    }

    function test_Constructor_RevertIfZeroMinter() public {
        vm.expectRevert(IGLTToken.MintToZeroAddress.selector);
        new GLTToken(address(0));
    }

    // Minter Management Tests
    function test_SetMinter_OnlyOwner() public {
        address newMinter = makeAddr("newMinter");
        
        token.setMinter(newMinter);
        
        assertEq(token.minter(), newMinter);
    }

    function test_SetMinter_RevertIfNotOwner() public {
        address newMinter = makeAddr("newMinter");
        
        vm.prank(alice);
        vm.expectRevert();
        token.setMinter(newMinter);
    }

    function test_SetMinter_RevertIfZeroAddress() public {
        vm.expectRevert(IGLTToken.MintToZeroAddress.selector);
        token.setMinter(address(0));
    }

    // Minting Tests
    function test_Mint_Success() public {
        uint256 amount = 1000e18;
        
        vm.expectEmit(true, false, false, true);
        emit Transfer(address(0), alice, amount);
        
        vm.expectEmit(true, false, false, true);
        emit TokensMinted(alice, amount);
        
        vm.prank(minter);
        token.mint(alice, amount);
        
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.totalSupply(), amount);
    }

    function test_Mint_MultipleRecipients() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        
        vm.startPrank(minter);
        token.mint(alice, amount1);
        token.mint(bob, amount2);
        vm.stopPrank();
        
        assertEq(token.balanceOf(alice), amount1);
        assertEq(token.balanceOf(bob), amount2);
        assertEq(token.totalSupply(), amount1 + amount2);
    }

    function test_Mint_RevertIfNotMinter() public {
        vm.prank(alice);
        vm.expectRevert("GLTToken: caller is not the minter");
        token.mint(bob, 1000e18);
    }

    function test_Mint_RevertIfZeroAddress() public {
        vm.prank(minter);
        vm.expectRevert(IGLTToken.MintToZeroAddress.selector);
        token.mint(address(0), 1000e18);
    }

    function test_Mint_RevertIfZeroAmount() public {
        vm.prank(minter);
        vm.expectRevert(IGLTToken.MintZeroAmount.selector);
        token.mint(alice, 0);
    }

    function test_Mint_RevertIfExceedsMaxSupply() public {
        vm.prank(minter);
        vm.expectRevert(IGLTToken.ExceedsMaxSupply.selector);
        token.mint(alice, MAX_SUPPLY + 1);
    }

    function test_Mint_RevertIfExceedsMaxSupplyWithExistingSupply() public {
        uint256 firstMint = MAX_SUPPLY / 2;
        uint256 secondMint = MAX_SUPPLY / 2 + 1;
        
        vm.startPrank(minter);
        token.mint(alice, firstMint);
        
        vm.expectRevert(IGLTToken.ExceedsMaxSupply.selector);
        token.mint(bob, secondMint);
        vm.stopPrank();
    }

    // Burning Tests
    function test_Burn_ByOwner() public {
        uint256 mintAmount = 1000e18;
        uint256 burnAmount = 400e18;
        
        vm.prank(minter);
        token.mint(alice, mintAmount);
        
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, address(0), burnAmount);
        
        vm.expectEmit(true, false, false, true);
        emit TokensBurned(alice, burnAmount);
        
        vm.prank(alice);
        token.burn(alice, burnAmount);
        
        assertEq(token.balanceOf(alice), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    function test_Burn_ByApprovedSpender() public {
        uint256 mintAmount = 1000e18;
        uint256 burnAmount = 400e18;
        
        vm.prank(minter);
        token.mint(alice, mintAmount);
        
        vm.prank(alice);
        token.approve(bob, burnAmount);
        
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, address(0), burnAmount);
        
        vm.expectEmit(true, false, false, true);
        emit TokensBurned(alice, burnAmount);
        
        vm.prank(bob);
        token.burn(alice, burnAmount);
        
        assertEq(token.balanceOf(alice), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_Burn_RevertIfZeroAddress() public {
        vm.expectRevert(IGLTToken.BurnFromZeroAddress.selector);
        token.burn(address(0), 1000e18);
    }

    function test_Burn_RevertIfZeroAmount() public {
        vm.prank(minter);
        token.mint(alice, 1000e18);
        
        vm.prank(alice);
        vm.expectRevert(IGLTToken.BurnZeroAmount.selector);
        token.burn(alice, 0);
    }

    function test_Burn_RevertIfExceedsBalance() public {
        uint256 mintAmount = 1000e18;
        
        vm.prank(minter);
        token.mint(alice, mintAmount);
        
        vm.prank(alice);
        vm.expectRevert(IGLTToken.BurnExceedsBalance.selector);
        token.burn(alice, mintAmount + 1);
    }

    function test_Burn_RevertIfInsufficientAllowance() public {
        uint256 mintAmount = 1000e18;
        uint256 approveAmount = 400e18;
        uint256 burnAmount = 500e18;
        
        vm.prank(minter);
        token.mint(alice, mintAmount);
        
        vm.prank(alice);
        token.approve(bob, approveAmount);
        
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                bob,
                approveAmount,
                burnAmount
            )
        );
        token.burn(alice, burnAmount);
    }

    // ERC20 Standard Tests
    function test_Transfer_Success() public {
        uint256 amount = 1000e18;
        uint256 transferAmount = 300e18;
        
        vm.prank(minter);
        token.mint(alice, amount);
        
        vm.prank(alice);
        assertTrue(token.transfer(bob, transferAmount));
        
        assertEq(token.balanceOf(alice), amount - transferAmount);
        assertEq(token.balanceOf(bob), transferAmount);
    }

    function test_TransferFrom_Success() public {
        uint256 amount = 1000e18;
        uint256 transferAmount = 300e18;
        
        vm.prank(minter);
        token.mint(alice, amount);
        
        vm.prank(alice);
        token.approve(bob, transferAmount);
        
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, charlie, transferAmount));
        
        assertEq(token.balanceOf(alice), amount - transferAmount);
        assertEq(token.balanceOf(charlie), transferAmount);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_Approve_Success() public {
        uint256 amount = 1000e18;
        
        vm.expectEmit(true, true, false, true);
        emit Approval(alice, bob, amount);
        
        vm.prank(alice);
        assertTrue(token.approve(bob, amount));
        
        assertEq(token.allowance(alice, bob), amount);
    }

    // Edge Cases
    function test_BurnEntireBalance() public {
        uint256 amount = 1000e18;
        
        vm.prank(minter);
        token.mint(alice, amount);
        
        vm.prank(alice);
        token.burn(alice, amount);
        
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
    }

    function test_MintMaxSupply() public {
        vm.prank(minter);
        token.mint(alice, MAX_SUPPLY);
        
        assertEq(token.balanceOf(alice), MAX_SUPPLY);
        assertEq(token.totalSupply(), MAX_SUPPLY);
    }

    function test_MultipleBurnsFromSameAddress() public {
        uint256 mintAmount = 1000e18;
        uint256 burn1 = 200e18;
        uint256 burn2 = 300e18;
        uint256 burn3 = 500e18;
        
        vm.prank(minter);
        token.mint(alice, mintAmount);
        
        vm.startPrank(alice);
        token.burn(alice, burn1);
        assertEq(token.balanceOf(alice), mintAmount - burn1);
        
        token.burn(alice, burn2);
        assertEq(token.balanceOf(alice), mintAmount - burn1 - burn2);
        
        token.burn(alice, burn3);
        assertEq(token.balanceOf(alice), 0);
        vm.stopPrank();
        
        assertEq(token.totalSupply(), 0);
    }

    // Fuzz Tests
    function testFuzz_Mint(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(amount > 0 && amount <= MAX_SUPPLY);
        
        vm.prank(minter);
        token.mint(to, amount);
        
        assertEq(token.balanceOf(to), amount);
        assertEq(token.totalSupply(), amount);
    }

    function testFuzz_Burn(uint256 mintAmount, uint256 burnAmount) public {
        vm.assume(mintAmount > 0 && mintAmount <= MAX_SUPPLY);
        vm.assume(burnAmount > 0 && burnAmount <= mintAmount);
        
        vm.prank(minter);
        token.mint(alice, mintAmount);
        
        vm.prank(alice);
        token.burn(alice, burnAmount);
        
        assertEq(token.balanceOf(alice), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    function testFuzz_MintBurnCycle(uint256 seed) public {
        uint256 cycles = seed % 10 + 1;
        uint256 totalMinted = 0;
        uint256 totalBurned = 0;
        
        for (uint256 i = 0; i < cycles; i++) {
            uint256 mintAmount = (uint256(keccak256(abi.encode(seed, i, "mint"))) % 1000e18) + 1;
            if (totalMinted + mintAmount > MAX_SUPPLY) {
                mintAmount = MAX_SUPPLY - totalMinted;
            }
            
            if (mintAmount > 0) {
                vm.prank(minter);
                token.mint(alice, mintAmount);
                totalMinted += mintAmount;
            }
            
            uint256 aliceBalance = token.balanceOf(alice);
            if (aliceBalance > 0) {
                uint256 burnAmount = (uint256(keccak256(abi.encode(seed, i, "burn"))) % aliceBalance) + 1;
                vm.prank(alice);
                token.burn(alice, burnAmount);
                totalBurned += burnAmount;
            }
        }
        
        assertEq(token.balanceOf(alice), totalMinted - totalBurned);
        assertEq(token.totalSupply(), totalMinted - totalBurned);
    }
}