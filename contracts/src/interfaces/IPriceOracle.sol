// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal Chainlink AggregatorV3 surface.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Price source for equity collateral, denominated in the vault's
///         collateral asset with 8 decimals.
/// @dev Unlike prediction positions, equities have no provable floor: the price
///      can go anywhere. Every consumer of this interface therefore needs a
///      liquidation engine, and inherits an oracle attack surface that the
///      prediction-position vault deliberately avoids.
interface IPriceOracle {
    /// @return price 8-decimal price of one whole token
    /// @return updatedAt timestamp of the underlying round
    function getPrice(address token) external view returns (uint256 price, uint256 updatedAt);

    /// @notice True when a usable, non-stale price exists.
    function isSupported(address token) external view returns (bool);
}
