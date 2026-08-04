// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title InterestModel
/// @notice The borrow rate as a function of how much of a facility is drawn.
///
/// @dev WHY A RATE THAT MOVES
///      A fixed rate has no way to defend the last of the liquidity. When a
///      facility is nearly drawn, a lender who wants their money back has to
///      wait for a borrower who has no reason to hurry. Letting the rate climb
///      steeply past a chosen point makes staying borrowed expensive exactly
///      when repayment matters, and makes depositing attractive exactly when
///      deposits are scarce. This is the two-slope shape Aave and Compound
///      have both used for years.
///
/// @dev THE SHAPE
///                        rate
///                          |                                    /
///                          |                                   /
///                          |                                  /  slope2
///                          |                                 /
///                     base + slope1 . . . . . . . . . . . ./
///                          |                     ______/
///                          |          ______/     slope1
///                       base |___/
///                          +--------------------|-----------+ utilisation
///                          0                   kink        100%
///
/// @dev THESE NUMBERS ARE CHOSEN, NOT MEASURED
///      An 80% kink and a 60% ceiling follow common practice rather than any
///      measurement of this venue, which has no history to measure yet. They
///      are owner-adjustable for that reason, and every bound is checked so a
///      mistake cannot produce a rate that traps a borrower.
contract InterestModel {
    error BadParams();
    error NotOwner();
    error ZeroAddress();

    uint256 private constant BPS = 10_000;

    /// @notice Hard ceiling on the rate this model can ever return.
    /// @dev Fixed in code, not a parameter. An owner who could raise the rate
    ///      without limit could make any loan unrepayable, which is the same
    ///      as seizing the collateral.
    uint256 public constant MAX_RATE_BPS = 20_000;

    address public owner;

    /// @notice Rate at zero utilisation.
    uint256 public baseBps;
    /// @notice Added by the time utilisation reaches the kink.
    uint256 public slope1Bps;
    /// @notice Added between the kink and full utilisation.
    uint256 public slope2Bps;
    /// @notice Utilisation, in bps, where the second slope begins.
    uint256 public kinkBps;

    event ParamsSet(uint256 baseBps, uint256 slope1Bps, uint256 slope2Bps, uint256 kinkBps);
    event OwnerSet(address owner);

    constructor(uint256 base_, uint256 slope1_, uint256 slope2_, uint256 kink_) {
        owner = msg.sender;
        _set(base_, slope1_, slope2_, kink_);
        emit OwnerSet(msg.sender);
    }

    function setOwner(address o) external {
        if (msg.sender != owner) revert NotOwner();
        if (o == address(0)) revert ZeroAddress();
        owner = o;
        emit OwnerSet(o);
    }

    function setParams(uint256 base_, uint256 slope1_, uint256 slope2_, uint256 kink_)
        external
    {
        if (msg.sender != owner) revert NotOwner();
        _set(base_, slope1_, slope2_, kink_);
    }

    function _set(uint256 base_, uint256 slope1_, uint256 slope2_, uint256 kink_) internal {
        // A kink at zero or at full utilisation collapses one slope entirely.
        if (kink_ == 0 || kink_ >= BPS) revert BadParams();
        if (base_ + slope1_ + slope2_ > MAX_RATE_BPS) revert BadParams();
        baseBps = base_;
        slope1Bps = slope1_;
        slope2Bps = slope2_;
        kinkBps = kink_;
        emit ParamsSet(base_, slope1_, slope2_, kink_);
    }

    /// @notice Utilisation in bps: what share of the supply is lent out.
    function utilisation(uint256 borrowed, uint256 supplied)
        public
        pure
        returns (uint256)
    {
        if (supplied == 0) return 0;
        uint256 u = (borrowed * BPS) / supplied;
        // Accrued interest can push debt past the principal ever supplied.
        // Reporting more than full utilisation would run the second slope off
        // the end of its range.
        return u > BPS ? BPS : u;
    }

    /// @notice The highest rate this curve can return, at full utilisation.
    /// @dev Distinct from MAX_RATE_BPS, which is the hard bound on what any
    ///      curve may be set to. A caller that must reserve against the worst
    ///      case wants this one.
    function maxRate() external view returns (uint256) {
        return baseBps + slope1Bps + slope2Bps;
    }

    /// @notice Annual borrow rate in bps for a given utilisation.
    function rateAt(uint256 u) public view returns (uint256) {
        if (u <= kinkBps) {
            return baseBps + (slope1Bps * u) / kinkBps;
        }
        uint256 over = ((u - kinkBps) * BPS) / (BPS - kinkBps);
        return baseBps + slope1Bps + (slope2Bps * over) / BPS;
    }

    /// @notice Annual borrow rate in bps for a facility.
    function borrowRate(uint256 borrowed, uint256 supplied)
        external
        view
        returns (uint256)
    {
        return rateAt(utilisation(borrowed, supplied));
    }

    /// @notice What a depositor earns, in bps.
    /// @dev Borrowers pay on the borrowed amount; depositors earn on
    ///      everything they supplied, including the part sitting idle. So the
    ///      supply rate is the borrow rate scaled by utilisation, less the
    ///      share kept as reserve. It is always below the borrow rate, which
    ///      is what keeps the facility solvent.
    function supplyRate(uint256 borrowed, uint256 supplied, uint256 reserveBps)
        external
        view
        returns (uint256)
    {
        if (reserveBps >= BPS) return 0;
        uint256 u = utilisation(borrowed, supplied);
        uint256 gross = (rateAt(u) * u) / BPS;
        return (gross * (BPS - reserveBps)) / BPS;
    }
}
