// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title IGLTToken
 * @dev Interface for the GenLayer Token (GLT) used for validator staking in the consensus system.
 * This token extends standard ERC20 functionality with minting and burning capabilities.
 */
interface IGLTToken is IERC20, IERC20Metadata {
    /**
     * @dev Emitted when new tokens are minted.
     * @param to The address receiving the minted tokens.
     * @param amount The amount of tokens minted.
     */
    event TokensMinted(address indexed to, uint256 amount);

    /**
     * @dev Emitted when tokens are burned.
     * @param from The address burning the tokens.
     * @param amount The amount of tokens burned.
     */
    event TokensBurned(address indexed from, uint256 amount);

    /**
     * @dev Error thrown when attempting to mint to zero address.
     */
    error MintToZeroAddress();

    /**
     * @dev Error thrown when attempting to burn from zero address.
     */
    error BurnFromZeroAddress();

    /**
     * @dev Error thrown when attempting to mint zero amount.
     */
    error MintZeroAmount();

    /**
     * @dev Error thrown when attempting to burn zero amount.
     */
    error BurnZeroAmount();

    /**
     * @dev Error thrown when attempting to burn more than balance.
     */
    error BurnExceedsBalance();

    /**
     * @dev Error thrown when minting would exceed max supply.
     */
    error ExceedsMaxSupply();

    /**
     * @dev Mints new tokens to the specified address.
     * @param to The address to mint tokens to.
     * @param amount The amount of tokens to mint.
     */
    function mint(address to, uint256 amount) external;

    /**
     * @dev Burns tokens from the specified address.
     * @param from The address to burn tokens from.
     * @param amount The amount of tokens to burn.
     */
    function burn(address from, uint256 amount) external;

    /**
     * @dev Returns the maximum supply cap for the token.
     * @return The maximum supply in wei.
     */
    function MAX_SUPPLY() external view returns (uint256);

    /**
     * @dev Returns the address that has minting privileges.
     * @return The minter address.
     */
    function minter() external view returns (address);
}