// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Argentum
 * @author Ogolo Boma
 * @notice The currency token for the SENATE
 */
contract Argentum is ERC20, ERC20Burnable, Ownable, ERC20Permit, ERC20Votes {
    //////////////////////////////////////////////////////////////////////////////////////////
    //                              STATE VARIABLES
    //////////////////////////////////////////////////////////////////////////////////////////
    uint256 public constant MAX_SUPPLY = 50_000_000e18;
    uint256 public constant INITIAL_SUPPLY = 25_000_000e18;

    //////////////////////////////////////////////////////////////////////////////////////////
    //                              ERRORS
    //////////////////////////////////////////////////////////////////////////////////////////
    error SupplyCapExceeded();

    //////////////////////////////////////////////////////////////////////////////////////////
    //                              FUNCTIONS
    //////////////////////////////////////////////////////////////////////////////////////////

    // ========================================
    // CONSTRUCTOR
    // ========================================

    /**
     * @notice Initializes the Argentum token
     * @param recipient The address that will receive the initial supply of tokens
     * @param initialOwner The address that will be set as the owner of the contract
     * @dev The constructor mints the initial supply of tokens to the specified recipient and sets the initial owner of the contract. The token is initialized with the name "Argentum" and the symbol "ARG". The ERC20Permit extension is also initialized to allow for gasless approvals.
     */
    constructor(address recipient, address initialOwner)
        ERC20("Argentum", "ARG")
        Ownable(initialOwner)
        ERC20Permit("Argentum")
    {
        _mint(recipient, INITIAL_SUPPLY);
    }

    // ========================================
    // MINTING
    // ========================================

    /**
     * @notice Mints new tokens to the specified address
     * @param to The address to receive the minted tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        if (totalSupply() + amount > MAX_SUPPLY) revert SupplyCapExceeded();
        _mint(to, amount);
    }

    /**
     * @notice Overrides the _update function to ensure compatibility with ERC20Votes
     * @param from The address tokens are being transferred from
     * @param to The address tokens are being transferred to
     * @param value The amount of tokens being transferred
     */
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    /**
     * @notice Overrides the nonces function to ensure compatibility with ERC20Permit and Nonces
     * @param owner The address of the token owner
     * @return The current nonce for the specified owner
     */
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
