// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IGLTToken } from "./interfaces/IGLTToken.sol";

/**
 * @title GLTToken
 * @dev GenLayer Token (GLT) implementation used for validator staking in the consensus system.
 * This token has a fixed maximum supply of 1 billion tokens and supports minting and burning.
 * Only the designated minter address can mint new tokens.
 */
contract GLTToken is ERC20, Ownable, IGLTToken {
    uint256 public constant override MAX_SUPPLY = 1_000_000_000e18;

    address public override minter;

    modifier onlyMinter() {
        require(msg.sender == minter, CallerNotMinter());
        _;
    }

    /**
     * @dev Initializes the GLT token with name and symbol.
     * Sets the deployer as the initial owner.
     * @param initialMinter The address that will have minting privileges.
     */
    constructor(address initialMinter) ERC20("GenLayer Token", "GLT") Ownable(msg.sender) {
        require(initialMinter != address(0), MintToZeroAddress());
        minter = initialMinter;
    }

    /**
     * @dev Sets a new minter address. Only callable by owner.
     * @param newMinter The address to grant minting privileges to.
     */
    function setMinter(address newMinter) external onlyOwner {
        require(newMinter != address(0), MintToZeroAddress());
        minter = newMinter;
    }

    /**
     * @inheritdoc IGLTToken
     */
    function mint(address to, uint256 amount) external override onlyMinter {
        require(to != address(0), MintToZeroAddress());
        require(amount > 0, MintZeroAmount());
        require(totalSupply() + amount <= MAX_SUPPLY, ExceedsMaxSupply());

        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    /**
     * @inheritdoc IGLTToken
     */
    function burn(address from, uint256 amount) external override {
        require(from != address(0), BurnFromZeroAddress());
        require(amount > 0, BurnZeroAmount());
        require(balanceOf(from) >= amount, BurnExceedsBalance());

        // Check and update allowance if caller is not the token owner
        if (from != msg.sender) {
            _spendAllowance(from, msg.sender, amount);
        }

        _burn(from, amount);
        emit TokensBurned(from, amount);
    }
}
