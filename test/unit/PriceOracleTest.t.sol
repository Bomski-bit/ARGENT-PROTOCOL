// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {RevertingMockFeed} from "../mocks/RevertingMockFeed.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract PriceOracleTest is StdCheats, Test {
    PriceOracle oracle;
    MockV3Aggregator feed;

    address internal owner;
    address internal user;
    address internal asset;

    uint256 internal constant HEARTBEAT = 1 hours;

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");
        asset = makeAddr("asset");

        oracle = new PriceOracle(owner);
    }

    /*//////////////////////////////////////////////////////////////
                            setPriceFeed
    //////////////////////////////////////////////////////////////*/

    function testOwnerCanSetPriceFeed() public {
        feed = new MockV3Aggregator(8, 2_000e8);

        vm.prank(owner);
        oracle.setPriceFeed(asset, address(feed), HEARTBEAT);

        assertEq(oracle.priceFeeds(asset), address(feed));
        assertEq(oracle.heartbeats(asset), HEARTBEAT);
    }

    function testNonOwnerCannotSetPriceFeed() public {
        feed = new MockV3Aggregator(8, 2_000e8);

        vm.prank(user);
        vm.expectRevert();
        oracle.setPriceFeed(asset, address(feed), HEARTBEAT);
    }

    function testSetPriceFeedRevertsIfFeedIsZero() public {
        vm.prank(owner);
        vm.expectRevert(PriceOracle.ArgentOracle__InvalidAddress.selector);
        oracle.setPriceFeed(asset, address(0), HEARTBEAT);
    }

    function testSetPriceFeedRevertsIfHeartbeatIsZero() public {
        feed = new MockV3Aggregator(8, 2_000e8);

        vm.prank(owner);
        vm.expectRevert(PriceOracle.ArgentOracle__InvalidHeartbeat.selector);
        oracle.setPriceFeed(asset, address(feed), 0);
    }

    function testSetPriceFeedRevertsIfAssetAddressIsZero() public {
        feed = new MockV3Aggregator(8, 2_000e8);

        vm.prank(owner);
        vm.expectRevert(PriceOracle.ArgentOracle__InvalidAddress.selector);
        oracle.setPriceFeed(address(0), address(feed), HEARTBEAT);
    }

    /*//////////////////////////////////////////////////////////////
                                getPrice
    //////////////////////////////////////////////////////////////*/

    function testGetPriceRevertsIfNoFeedIsSet() public {
        vm.expectRevert(PriceOracle.ArgentOracle__InvalidAddress.selector);
        oracle.getPrice(asset);
    }

    function testGetPriceRevertsIfPriceIsZeroOrNegative() public {
        feed = new MockV3Aggregator(8, 0);

        vm.prank(owner);
        oracle.setPriceFeed(asset, address(feed), HEARTBEAT);

        vm.expectRevert(PriceOracle.ArgentOracle__InvalidPrice.selector);
        oracle.getPrice(asset);
    }

    function testGetPriceRevertsIfPriceIsStale() public {
        feed = new MockV3Aggregator(8, 2_000e8);

        vm.prank(owner);
        oracle.setPriceFeed(asset, address(feed), HEARTBEAT);

        // Move time forward so the price becomes stale
        vm.warp(block.timestamp + HEARTBEAT + 1);

        vm.expectRevert(PriceOracle.ArgentOracle__StalePrice.selector);
        oracle.getPrice(asset);
    }

    function testGetPriceReturnsValidPrice() public {
        uint256 price = 2_000e8;
        feed = new MockV3Aggregator(8, int256(price));

        vm.prank(owner);
        oracle.setPriceFeed(asset, address(feed), HEARTBEAT);

        uint256 returnedPrice = oracle.getPrice(asset);
        assertEq(returnedPrice, price);
    }

    function testGetPriceSucceedsWhenTimestampIsValid() public {
        // Mock feed with a normal price
        feed = new MockV3Aggregator(8, 2_000e8);

        vm.prank(owner);
        oracle.setPriceFeed(asset, address(feed), HEARTBEAT);

        // Ensure updatedAt <= block.timestamp
        // (MockV3Aggregator sets updatedAt = block.timestamp)
        vm.warp(block.timestamp + 10);

        uint256 price = oracle.getPrice(asset);

        assertEq(price, 2_000e8);
    }

    function testGetPriceRevertsIfChainlinkFeedReverts() public {
        // Create a mock feed that reverts when latestRoundData is called
        address badFeed = address(new RevertingMockFeed());

        vm.prank(owner);
        oracle.setPriceFeed(asset, badFeed, HEARTBEAT);

        vm.expectRevert(PriceOracle.ArgentOracle__FeedUnavailable.selector);
        oracle.getPrice(asset);
    }
}
