// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/**
 * @title Treasury
 * @author Argent Protocol
 * @notice Custodian of protocol-owned funds.
 * @dev Owned by the TimelockController. Has no autonomous power.
 */
contract Treasury is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error Treasury__InvalidRecipient();
    error Treasury__InsufficientETH();
    error Treasury__ETHTransferFailed();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when ERC20 tokens are transferred from the treasury.
     * @param token The address of the ERC20 token transferred.
     * @param to The address receiving the tokens.
     * @param amount The amount of tokens transferred.
     */
    event ERC20Transferred(address indexed token, address indexed to, uint256 indexed amount);

    /**
     * @notice Emitted when ETH is transferred from the treasury.
     * @param to The address receiving the ETH.
     * @param amount The amount of ETH transferred.
     */
    event ETHTransferred(address indexed to, uint256 indexed amount);

    /*//////////////////////////////////////////////////////////////
                              FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // ========================================
    // CONSTRUCTOR
    // ========================================

    /**
     * @notice Initializes the Treasury contract.
     * @param timelock The address of the TimelockController that will own the treasury.
     */
    constructor(address timelock) Ownable(timelock) {}

    // ========================================
    // RECEIVE
    // ========================================

    /**
     * @notice Receives ETH sent to the treasury.
     */
    receive() external payable {}

    // ========================================
    // TRANSFER FUNCTIONS
    // ========================================

    /**
     * @notice Transfer ERC20 tokens held by the treasury.
     * @param token The address of the ERC20 token to transfer.
     * @param to The address receiving the tokens.
     * @param amount The amount of tokens to transfer.
     * @dev Callable only via governance through the timelock.
     */
    function transferERC20(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert Treasury__InvalidRecipient();

        emit ERC20Transferred(token, to, amount);

        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Transfer ETH held by the treasury.
     * @param to The address receiving the ETH.
     * @param amount The amount of ETH to transfer.
     * @dev Callable only via governance through the timelock.
     */
    function transferETH(address payable to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert Treasury__InvalidRecipient();
        if (address(this).balance < amount) revert Treasury__InsufficientETH();

        emit ETHTransferred(to, amount);
        (bool success,) = to.call{value: amount}("");
        if (!success) revert Treasury__ETHTransferFailed();
    }

    /**
     * @notice Delegate voting power of a token held by the treasury.
     * @param token The address of the ERC20 token to delegate.
     * @param delegatee The address receiving the delegated votes.
     * @dev Callable only via governance through the timelock.
     */
    function delegateToken(address token, address delegatee) external onlyOwner {
        IVotes(token).delegate(delegatee);
    }
}
