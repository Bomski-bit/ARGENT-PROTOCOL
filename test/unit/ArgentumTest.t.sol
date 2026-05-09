// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Argentum} from "../../src/Argentum.sol";

contract ArgentumTest is StdCheats, Test {
    Argentum token;

    address internal owner;
    address internal recipient;
    address internal user;

    uint256 internal constant MAX_SUPPLY = 50_000_000e18;
    uint256 public constant INITIAL_SUPPLY = 25_000_000e18;

    function setUp() public {
        owner = makeAddr("owner");
        recipient = makeAddr("recipient");
        user = makeAddr("user");

        token = new Argentum(recipient, owner);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function testInitialSupplyMintedToRecipient() public view {
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(recipient), INITIAL_SUPPLY);
    }

    function testOwnerIsCorrect() public view {
        assertEq(token.owner(), owner);
    }

    /*//////////////////////////////////////////////////////////////
                                MINT
    //////////////////////////////////////////////////////////////*/

    function testOwnerCanMint() public {
        vm.prank(owner);
        token.mint(user, 1e18);

        assertEq(token.balanceOf(user), 1e18);
        assertEq(token.totalSupply(), INITIAL_SUPPLY + 1e18);
    }

    function testNonOwnerCannotMint() public {
        vm.prank(user);
        vm.expectRevert();
        token.mint(user, 1e18);
    }

    function testMintingAboveMaxSupplyReverts() public {
        vm.prank(owner);
        vm.expectRevert(Argentum.SupplyCapExceeded.selector);
        token.mint(user, MAX_SUPPLY); // would exceed max supply
    }

    /*//////////////////////////////////////////////////////////////
                                BURN
    //////////////////////////////////////////////////////////////*/

    function testBurnReducesSupply() public {
        vm.prank(recipient);
        token.burn(1e18);

        assertEq(token.balanceOf(recipient), INITIAL_SUPPLY - 1e18);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 1e18);
    }

    function testBurnFromWithApproval() public {
        vm.prank(recipient);
        token.approve(user, 2e18);

        vm.prank(user);
        token.burnFrom(recipient, 2e18);

        assertEq(token.balanceOf(recipient), INITIAL_SUPPLY - 2e18);
    }

    /*//////////////////////////////////////////////////////////////
                            TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function testTransferMovesBalance() public {
        vm.prank(recipient);
        token.transfer(user, 5e18);

        assertEq(token.balanceOf(user), 5e18);
        assertEq(token.balanceOf(recipient), INITIAL_SUPPLY - 5e18);
    }

    /*//////////////////////////////////////////////////////////////
                            PERMIT
    //////////////////////////////////////////////////////////////*/

    function testPermitSetsAllowanceAndIncrementsNonce() public {
        uint256 privateKey = 0xBEEF;
        address signer = vm.addr(privateKey);

        // fund signer
        vm.prank(recipient);
        token.transfer(signer, 10e18);

        uint256 nonce = token.nonces(signer);
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        signer,
                        user,
                        5e18,
                        nonce,
                        deadline
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        token.permit(signer, user, 5e18, deadline, v, r, s);

        assertEq(token.allowance(signer, user), 5e18);
        assertEq(token.nonces(signer), nonce + 1);
    }

    /*//////////////////////////////////////////////////////////////
                            VOTES
    //////////////////////////////////////////////////////////////*/

    function testDelegateGivesVotingPower() public {
        vm.prank(recipient);
        token.delegate(recipient);

        assertEq(token.getVotes(recipient), INITIAL_SUPPLY);
    }

    function testVotesDecreaseOnTransfer() public {
        vm.startPrank(recipient);
        token.delegate(recipient);
        token.transfer(user, 10e18);
        vm.stopPrank();

        assertEq(token.getVotes(recipient), INITIAL_SUPPLY - 10e18);
        assertEq(token.getVotes(user), 0);
    }

    function testDelegateToAnotherAddress() public {
        vm.prank(recipient);
        token.delegate(user);

        assertEq(token.getVotes(user), INITIAL_SUPPLY);
    }
}
