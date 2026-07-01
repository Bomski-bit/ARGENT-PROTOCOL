// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Treasury} from "../../src/Treasury.sol";
import {MockERC20Votes} from "../mocks/MockERC20Votes.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// Contract that rejects ETH to test ETHTransferFailed
contract Rejector {
    receive() external payable {
        revert("I refuse ETH");
    }
}

contract TreasuryTest is Test {
    Treasury public treasury;
    MockERC20Votes public token;

    address public timelock = address(0x123);
    address public user = address(0x456);

    event ERC20Transferred(address indexed token, address indexed to, uint256 indexed amount);

    event ETHTransferred(address indexed to, uint256 indexed amount);

    function setUp() public {
        vm.prank(timelock);
        treasury = new Treasury(timelock);

        token = new MockERC20Votes();

        token.mint(address(treasury), 100e18);

        vm.deal(address(treasury), 10 ether);
        vm.deal(address(this), 10 ether);
    }

    // --- Constructor ---

    function testConstructorRevertsIfTimelockIsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Treasury(address(0));
    }

    // --- Receive ETH ---

    function testTreasuryCanReceiveETH() public {
        uint256 startBalance = address(treasury).balance;
        (bool success,) = address(treasury).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(treasury).balance, startBalance + 1 ether);
    }

    // --- transferERC20 ---

    function testTreasuryCanTransferERC20() public {
        uint256 amount = 50e18;

        vm.expectEmit(true, true, true, true);
        emit ERC20Transferred(address(token), user, amount);

        vm.prank(timelock);
        treasury.transferERC20(address(token), user, amount);

        assertEq(token.balanceOf(user), amount);
    }

    function testTreasuryRevertsTransferERC20IfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        treasury.transferERC20(address(token), user, 10e18);
    }

    function testTreasuryRevertsTransferERC20IfRecipientIsZeroAddress() public {
        vm.prank(timelock);
        vm.expectRevert(Treasury.Treasury__InvalidRecipient.selector);
        treasury.transferERC20(address(token), address(0), 10e18);
    }

    // --- transferETH ---

    function testTreasuryCanTransferETH() public {
        uint256 amount = 1 ether;
        uint256 userInitialBalance = user.balance;

        vm.expectEmit(true, true, false, true);
        emit ETHTransferred(user, amount);

        vm.prank(timelock);
        treasury.transferETH(payable(user), amount);

        assertEq(user.balance, userInitialBalance + amount);
    }

    function testTreasuryRevertsTransferETHIfBalanceIsInsufficient() public {
        uint256 tooMuch = 100 ether;
        vm.prank(timelock);
        vm.expectRevert(Treasury.Treasury__InsufficientETH.selector);
        treasury.transferETH(payable(user), tooMuch);
    }

    function testTreasuryRevertsTransferETHIfRecipientIsZeroAddress() public {
        vm.prank(timelock);
        vm.expectRevert(Treasury.Treasury__InvalidRecipient.selector);
        treasury.transferETH(payable(address(0)), 1 ether);
    }

    function testTreasuryRevertsTransferETHIfTransferFails() public {
        Rejector rejector = new Rejector();
        vm.prank(timelock);
        vm.expectRevert(Treasury.Treasury__ETHTransferFailed.selector);
        treasury.transferETH(payable(address(rejector)), 1 ether);
    }

    function testDelegateTokenDelegatesVotingPower() public {
        address delegatee = makeAddr("delegatee");

        // Mint tokens to Treasury
        token.mint(address(treasury), 1_000e18);

        // No voting power before delegation
        assertEq(token.getVotes(delegatee), 0);

        vm.prank(address(timelock)); // treasury owner

        treasury.delegateToken(address(token), delegatee);

        assertEq(token.getVotes(delegatee), token.balanceOf(address(treasury)));
    }

    function testDelegateTokenRevertsIfCallerNotOwner() public {
        address attacker = makeAddr("attacker");
        address delegatee = makeAddr("delegatee");

        vm.prank(attacker);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));

        treasury.delegateToken(address(token), delegatee);
    }

    function testDelegateTokenChangesDelegatee() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint256 balance = token.balanceOf(address(treasury));

        vm.startPrank(address(timelock));

        treasury.delegateToken(address(token), alice);

        assertEq(token.getVotes(alice), balance);

        treasury.delegateToken(address(token), bob);

        assertEq(token.getVotes(alice), 0);
        assertEq(token.getVotes(bob), balance);

        vm.stopPrank();
    }
}
