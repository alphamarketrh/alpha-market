// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MarketTypes
/// @notice Shared enums for the Alpha Market mirror + resolution lifecycle.
library MarketTypes {
    /// @notice Lifecycle of a mirrored market.
    /// @dev Trading (split) is only permitted in `Active`. `merge` stays open in
    ///      every pre-resolution state because one YES + one NO is always worth
    ///      exactly one unit of collateral, so it can never be unsafe.
    enum Status {
        None,      // not registered
        Active,    // split + merge open
        Halted,    // source proposal observed on Polygon; split frozen
        Proposed,  // outcome posted on-chain, challenge window running
        Disputed,  // challenged, awaiting arbiter
        Resolved   // final, redeem open
    }

    /// @notice Terminal outcome. `Invalid` pays 0.5 to each side, matching the
    ///         50/50 resolution that UMA can return upstream.
    enum Outcome {
        Unresolved,
        Yes,
        No,
        Invalid
    }
}
