// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev A mock Chainlink feed that always reverts on latestRoundData.
 *      Used to test oracle failure handling in PriceOracle.
 */
contract RevertingMockFeed {
    function latestRoundData()
        external
        pure
        returns (
            uint80, // roundId
            int256, // answer
            uint256, // startedAt
            uint256, // updatedAt
            uint80 // answeredInRound
        )
    {
        revert("feed unavailable");
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}
