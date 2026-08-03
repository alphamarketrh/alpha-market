// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OutcomeToken} from "./OutcomeToken.sol";
import {MarketRegistry} from "./MarketRegistry.sol";
import {MarketTypes} from "./types/MarketTypes.sol";
import {Pausable} from "./Pausable.sol";

/// @title AlphaMarketCore
/// @notice Mints, burns and redeems binary outcome tokens against collateral.
/// @dev Collateral invariant: one unit in produces one YES plus one NO, and one
///      YES plus one NO always redeems for one unit. Outcome tokens share the
///      collateral's decimals so the relationship is exactly 1:1 with no scaling.
///
///      `merge` is deliberately available in every pre-resolution state,
///      including `Halted`. A hedged pair is worth exactly one unit regardless of
///      outcome, so allowing exit can never make the contract insolvent, and it
///      guarantees users a way out when no market maker is quoting.
contract AlphaMarketCore is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error AlreadyInitialized();
    error NotInitialized();
    error MarketNotTradeable();
    error MarketNotResolved();
    error MarketAlreadyResolved();
    error NothingToRedeem();

    struct Pair {
        OutcomeToken yes;
        OutcomeToken no;
    }

    IERC20 public immutable collateral;
    uint8 public immutable collateralDecimals;
    MarketRegistry public immutable registry;

    mapping(bytes32 => Pair) public pairs;
    uint256 public initializedCount;

    event MarketInitialized(bytes32 indexed id, address yes, address no, uint256 index);
    event Split(bytes32 indexed id, address indexed account, uint256 amount);
    event Merge(bytes32 indexed id, address indexed account, uint256 amount);
    event Redeem(
        bytes32 indexed id, address indexed account, uint256 yesAmount, uint256 noAmount, uint256 payout
    );

    constructor(address collateral_, address registry_) {
        if (collateral_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        collateral = IERC20(collateral_);
        collateralDecimals = IERC20Metadata(collateral_).decimals();
        registry = MarketRegistry(registry_);
    }

    /// @notice Deploy the YES/NO pair for a registered market. Permissionless.
    function initializeMarket(bytes32 id) external returns (address yes, address no) {
        if (registry.statusOf(id) == MarketTypes.Status.None) revert MarketNotTradeable();
        if (address(pairs[id].yes) != address(0)) revert AlreadyInitialized();

        uint256 idx = initializedCount++;
        string memory suffix = _toString(idx);

        OutcomeToken y = new OutcomeToken(
            string.concat("Alpha Market YES #", suffix),
            string.concat("aYES", suffix),
            collateralDecimals,
            address(this)
        );
        OutcomeToken n = new OutcomeToken(
            string.concat("Alpha Market NO #", suffix),
            string.concat("aNO", suffix),
            collateralDecimals,
            address(this)
        );

        pairs[id] = Pair({yes: y, no: n});
        emit MarketInitialized(id, address(y), address(n), idx);
        return (address(y), address(n));
    }

    /// @notice Deposit collateral, receive an equal amount of YES and NO.
    function split(bytes32 id, uint256 amount) external nonReentrant whenEntryOpen {
        if (amount == 0) revert ZeroAmount();
        Pair memory p = _pair(id);
        if (!registry.isTradeable(id)) revert MarketNotTradeable();

        collateral.safeTransferFrom(msg.sender, address(this), amount);
        p.yes.mint(msg.sender, amount);
        p.no.mint(msg.sender, amount);
        emit Split(id, msg.sender, amount);
    }

    /// @notice Burn matched YES and NO, receive collateral. Open pre-resolution.
    function merge(bytes32 id, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Pair memory p = _pair(id);
        if (registry.isResolved(id)) revert MarketAlreadyResolved();

        p.yes.burn(msg.sender, amount);
        p.no.burn(msg.sender, amount);
        collateral.safeTransfer(msg.sender, amount);
        emit Merge(id, msg.sender, amount);
    }

    /// @notice Redeem after resolution.
    /// @dev Yes pays the YES side in full, No pays the NO side in full, and
    ///      Invalid pays half to each. Amounts are summed before halving so the
    ///      rounding loss on an Invalid redemption is at most one wei.
    function redeem(bytes32 id, uint256 yesAmount, uint256 noAmount) external nonReentrant {
        if (yesAmount == 0 && noAmount == 0) revert ZeroAmount();
        Pair memory p = _pair(id);
        if (!registry.isResolved(id)) revert MarketNotResolved();

        MarketTypes.Outcome o = registry.outcomeOf(id);
        uint256 payout;

        if (o == MarketTypes.Outcome.Yes) {
            payout = yesAmount;
        } else if (o == MarketTypes.Outcome.No) {
            payout = noAmount;
        } else {
            payout = (yesAmount + noAmount) / 2;
        }

        if (yesAmount > 0) p.yes.burn(msg.sender, yesAmount);
        if (noAmount > 0) p.no.burn(msg.sender, noAmount);
        if (payout == 0) revert NothingToRedeem();

        collateral.safeTransfer(msg.sender, payout);
        emit Redeem(id, msg.sender, yesAmount, noAmount, payout);
    }


    /// @inheritdoc Pausable
    /// @dev This contract has no owner of its own. Rather than introduce one
    ///      solely to hold the pause, it defers to the registry owner, which is
    ///      the authority it already depends on for market state.
    function _pauseAdmin() internal view override returns (address) {
        return registry.owner();
    }

    // ----------------------------------------------------------------- views

    function tokensOf(bytes32 id) external view returns (address yes, address no) {
        Pair memory p = pairs[id];
        return (address(p.yes), address(p.no));
    }

    // -------------------------------------------------------------- internal

    function _pair(bytes32 id) internal view returns (Pair memory p) {
        p = pairs[id];
        if (address(p.yes) == address(0)) revert NotInitialized();
    }

    function _toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 d;
        uint256 t = v;
        while (t != 0) { d++; t /= 10; }
        bytes memory b = new bytes(d);
        while (v != 0) { b[--d] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }
}
