// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IRichterOracle
/// @notice Settlement for a market on the size of a price move.
///
/// @dev SCALE
///      The fraction is 0 to 1e6 inclusive, matching IPositionOracle so the same
///      number can price a live position and settle a finished one. 1e6 means the
///      move reached or passed the cap, 0 means the price did not move at all.
///
/// @dev VOIDING
///      A market the oracle cannot settle honestly returns 500000, half to each
///      side. That is the same payout the existing core gives an Invalid market
///      and it leaves every collateral position solvent, because BIG plus CALM is
///      still exactly one unit.
interface IRichterOracle {
    /// @notice True when this id was created by the factory and has a window.
    function isKnownMarket(bytes32 id) external view returns (bool);

    /// @notice The settled fraction, 0 to 1e6. Reverts while the window is open.
    function settlementFraction(bytes32 id) external view returns (uint256);
}
