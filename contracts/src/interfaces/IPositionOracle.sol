// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPositionOracle
/// @notice Price of one outcome token, in collateral units scaled to 1e6.
///
/// @dev WHY THIS IS AN INTERFACE AND NOT A CONCRETE CONTRACT
///      A one-sided prediction position has no provable floor, so lending
///      against it needs a price. Today the only usable price comes from
///      Polymarket, mirrored on chain by the relayer. Once Alpha Market forms
///      its own order flow, the price should come from that book instead.
///      DirectionalVault therefore reads through this interface and never needs
///      to change when the source does.
///
/// @dev SCALE
///      An outcome token always settles between 0 and 1 unit of collateral, so
///      a price is a fraction of one unit. With 6-decimal collateral, 1e6 means
///      one whole unit and 600000 means 0.60.
interface IPositionOracle {
    /// @param marketId  registry market id
    /// @param isYes     true for the YES side, false for NO
    /// @return price    0 to 1e6, where 1e6 is one whole collateral unit
    /// @return updatedAt timestamp the price was written
    function priceOf(bytes32 marketId, bool isYes)
        external
        view
        returns (uint256 price, uint256 updatedAt);

    /// @notice True when a usable, non-stale price exists for both sides.
    function isPriced(bytes32 marketId) external view returns (bool);
}
