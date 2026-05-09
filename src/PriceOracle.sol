// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

contract PriceOracle is Ownable, IPriceOracle {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ArgentOracle__InvalidPrice();
    error ArgentOracle__StalePrice();
    error ArgentOracle__InvalidHeartbeat();
    error ArgentOracle__InvalidAddress();
    error ArgentOracle__FeedUnavailable();

    /*//////////////////////////////////////////////////////////////
                                STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // ========================================
    // MAPPINGS
    // ========================================

    /// @notice Mapping of asset address to Chainlink Feed address
    /// @dev For example, WETH => Chainlink ETH/USD feed address
    mapping(address => address) public priceFeeds;

    /// @notice Heartbeat: Maximum time allowed between price updates (e.g., 3600 for 1 hour)
    /// @dev The maximum time (in seconds) that can pass between price updates for a given feed before the price is considered stale.
    /// @dev This is set per asset.
    mapping(address => uint256) public heartbeats;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a price feed is set or updated for an asset.
     * @param asset The address of the asset (e.g., WETH).
     * @param feed The address of the Chainlink Aggregator feed.
     * @param heartbeat The maximum allowed time between price updates for this feed.
     */
    event PriceFeedSet(address indexed asset, address indexed feed, uint256 heartbeat);

    /*//////////////////////////////////////////////////////////////
                              FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // ========================================
    // CONSTRUCTOR
    // ========================================

    /**
     * @notice Initializes the PriceOracle contract
     * @param _initialOwner The address that will be set as the owner of the contract
     */
    constructor(address _initialOwner) Ownable(_initialOwner) {}

    // ========================================
    // ORACLE MANAGEMENT
    // ========================================

    /**
     * @notice Set or update the feed for an asset
     * @param asset The token address (e.g., WETH)
     * @param feed The Chainlink Aggregator address
     * @param heartbeat The max delay for this specific feed (check Chainlink docs for each asset)
     */
    function setPriceFeed(address asset, address feed, uint256 heartbeat) external override onlyOwner {
        if (feed == address(0)) revert ArgentOracle__InvalidAddress();
        if (heartbeat == 0) revert ArgentOracle__InvalidHeartbeat();
        if (asset == address(0)) revert ArgentOracle__InvalidAddress();

        priceFeeds[asset] = feed;
        heartbeats[asset] = heartbeat;

        emit PriceFeedSet(asset, feed, heartbeat);
    }

    /**
     * @notice Fetch the price with safety checks
     * @param asset The token address to query
     * @return price The price in USD with 8 decimals
     */
    function getPrice(address asset) external view override returns (uint256) {
        address feedAddress = priceFeeds[asset];
        // Feed existence check
        if (feedAddress == address(0)) revert ArgentOracle__InvalidAddress();

        // Fetch price data from Chainlink feed
        AggregatorV3Interface feed = AggregatorV3Interface(feedAddress);

        // Variables to hold the price and timestamp from the feed
        int256 answer;
        uint256 updatedAt;

        // Using try/catch to handle potential issues with the feed call
        try feed.latestRoundData() returns (uint80, int256 _answer, uint256, uint256 _updatedAt, uint80) {
            answer = _answer;
            updatedAt = _updatedAt;
        } catch {
            revert ArgentOracle__FeedUnavailable();
        }

        // Positive price check
        if (answer <= 0) revert ArgentOracle__InvalidPrice();
        // Timestamp sanity check
        if (updatedAt > block.timestamp) revert ArgentOracle__StalePrice();
        // Heartbeat check
        if (block.timestamp - updatedAt > heartbeats[asset]) {
            revert ArgentOracle__StalePrice();
        }

        return uint256(answer);
    }
}
