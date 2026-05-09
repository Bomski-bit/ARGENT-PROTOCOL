// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPriceOracle {
    function getPrice(address asset) external view returns (uint256);
    function setPriceFeed(address asset, address feed, uint256 heartbeat) external;
}
