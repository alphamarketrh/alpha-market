// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Pausable
/// @notice Emergency stop shared by every contract that moves user money.
///
/// @dev A PAUSE MUST NEVER TRAP FUNDS
///      The reason to pause is that something is wrong. If pausing also locks
///      every exit, a bug in one function becomes a hostage situation across
///      the whole protocol, and the operator is forced to choose between
///      leaving an exploit running and freezing everyone out. Neither is
///      acceptable, so the split is fixed in code rather than left to
///      judgement at the worst possible moment:
///
///        PAUSED   entering, opening, borrowing, increasing exposure
///        ALWAYS   exiting, closing, repaying, cancelling, withdrawing
///
///      Concretely: split, placeOrder, borrow and pledge stop. merge, redeem,
///      cancelOrder, repay, unpledge and settle keep working. A user can
///      always get out of a paused system, which also means a pause costs the
///      operator very little goodwill and can be used early rather than late.
///
/// @dev TWO ROLES, DELIBERATELY ASYMMETRIC
///      A guardian may pause but not unpause. Only the owner unpauses. Pausing
///      is the safe direction, so it should be fast and delegable to a monitor
///      or a bot. Unpausing asserts that the danger has passed, which is a
///      judgement the owner has to make.
abstract contract Pausable {
    error EnterPaused();
    error NotGuardian();
    error NotPauseAdmin();
    // ZeroAddress is deliberately not declared here. Every contract that
    // inherits this already declares it, and Solidity treats a redeclaration
    // in a base as a collision rather than a match.
    error ZeroGuardian();

    /// @notice When true, no new exposure may be opened. Exits stay open.
    bool public entryPaused;

    /// @notice Addresses permitted to trip the pause.
    mapping(address => bool) public isGuardian;

    event EntryPaused(address indexed by);
    event EntryUnpaused(address indexed by);
    event GuardianSet(address indexed guardian, bool allowed);

    /// @dev Implemented by the inheriting contract, normally as its owner.
    function _pauseAdmin() internal view virtual returns (address);

    /// @dev Guards anything that increases a position. Never applied to exits.
    modifier whenEntryOpen() {
        if (entryPaused) revert EnterPaused();
        _;
    }

    function setGuardian(address guardian, bool allowed) external {
        if (msg.sender != _pauseAdmin()) revert NotPauseAdmin();
        if (guardian == address(0)) revert ZeroGuardian();
        isGuardian[guardian] = allowed;
        emit GuardianSet(guardian, allowed);
    }

    /// @notice Stop new exposure. Callable by any guardian or the admin.
    function pauseEntry() external {
        if (msg.sender != _pauseAdmin() && !isGuardian[msg.sender]) revert NotGuardian();
        entryPaused = true;
        emit EntryPaused(msg.sender);
    }

    /// @notice Resume. Admin only: this asserts the danger has passed.
    function unpauseEntry() external {
        if (msg.sender != _pauseAdmin()) revert NotPauseAdmin();
        entryPaused = false;
        emit EntryUnpaused(msg.sender);
    }
}
