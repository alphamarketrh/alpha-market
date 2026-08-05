// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OutcomeToken} from "./OutcomeToken.sol";
import {IRichterOracle} from "./interfaces/IRichterOracle.sol";

/**
 * A core for markets that settle to a fraction rather than to a side.
 *
 * WHY THIS IS A SEPARATE CORE
 * AlphaMarketCore.redeem reads MarketTypes.Outcome and pays the whole unit to one
 * side, or exactly half to each when the outcome is Invalid. That enum has four
 * values and nowhere to carry a number, so a settlement at 0.37 cannot be
 * expressed through it. AlphaMarketCore is also Ownable with immutables and no
 * proxy, and seven contracts hold its address as an immutable, so it cannot be
 * changed in place. A second core is therefore the only way to add graded
 * settlement without redeploying the system.
 *
 * WHAT IS IDENTICAL TO THE EXISTING CORE
 * The pair invariant. One BIG plus one CALM is always worth exactly one unit of
 * collateral, before settlement and after it, because payouts are s and 1 - s.
 * split and merge therefore behave exactly as they do for a binary market, and
 * the min(BIG, CALM) floor that LendingVault lends against holds unchanged.
 *
 * WHAT IS DIFFERENT
 * Resolution comes from IRichterOracle rather than from a registry outcome. There
 * is no proposer, no bond, no dispute and no arbiter, because two Chainlink
 * rounds decide the result and there is nothing for a human to rule on. A market
 * the oracle voids settles at one half to each side, which is the same payout the
 * existing core gives an Invalid market.
 *
 * ROUNDING
 * Payout is floor(yes * s / ONE) + floor(no * (ONE - s) / ONE). Both terms round
 * down, so the contract can never pay out more collateral than it holds. The dust
 * left behind is at most one base unit per redeem and stays in the contract.
 */
contract RichterCore is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error AlreadyInitialized();
    error MarketNotInitialized();
    error MarketNotSettled();
    error MarketAlreadySettled();
    error NothingToRedeem();
    error BadFraction(uint256 s);

    struct Pair {
        OutcomeToken big;
        OutcomeToken calm;
    }

    /// @notice One whole unit of a settlement fraction. s is 0 to ONE inclusive.
    uint256 public constant ONE = 1e6;

    IERC20 public immutable collateral;
    uint8 public immutable collateralDecimals;
    IRichterOracle public immutable oracle;

    mapping(bytes32 => Pair) public pairs;
    mapping(bytes32 => uint256) private _settledAt;
    mapping(bytes32 => uint256) private _fraction;

    uint256 public initializedCount;

    event MarketInitialized(bytes32 indexed id, address big, address calm, uint256 index);
    event Split(bytes32 indexed id, address indexed who, uint256 amount);
    event Merge(bytes32 indexed id, address indexed who, uint256 amount);
    event Settled(bytes32 indexed id, uint256 fraction, uint256 at);
    event Redeem(bytes32 indexed id, address indexed who, uint256 big, uint256 calm, uint256 payout);

    constructor(address collateral_, address oracle_) {
        if (collateral_ == address(0) || oracle_ == address(0)) revert ZeroAddress();
        collateral = IERC20(collateral_);
        oracle = IRichterOracle(oracle_);
        collateralDecimals = IERC20Metadata(collateral_).decimals();
    }

    // ------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------

    /// @notice Create the BIG and CALM pair for a market the oracle knows about.
    /// @dev Permissionless. The oracle decides which ids exist, so an unknown id
    ///      simply has no window and can never settle, and a pair created for one
    ///      is inert rather than dangerous.
    function initializeMarket(bytes32 id) external returns (address big, address calm) {
        if (address(pairs[id].big) != address(0)) revert AlreadyInitialized();
        if (!oracle.isKnownMarket(id)) revert MarketNotInitialized();

        uint256 idx = initializedCount++;
        string memory suffix = _toString(idx);

        OutcomeToken b = new OutcomeToken(
            string.concat("Richter BIG #", suffix),
            string.concat("rBIG", suffix),
            collateralDecimals,
            address(this)
        );
        OutcomeToken c = new OutcomeToken(
            string.concat("Richter CALM #", suffix),
            string.concat("rCALM", suffix),
            collateralDecimals,
            address(this)
        );

        pairs[id] = Pair({big: b, calm: c});
        emit MarketInitialized(id, address(b), address(c), idx);
        return (address(b), address(c));
    }

    /// @notice Lock one unit of collateral, receive one BIG and one CALM.
    function split(bytes32 id, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (_settledAt[id] != 0) revert MarketAlreadySettled();
        Pair memory p = _pair(id);

        collateral.safeTransferFrom(msg.sender, address(this), amount);
        p.big.mint(msg.sender, amount);
        p.calm.mint(msg.sender, amount);
        emit Split(id, msg.sender, amount);
    }

    /// @notice Burn one BIG and one CALM, receive one unit of collateral.
    /// @dev Open in every state including after settlement, because a matched
    ///      pair is worth exactly one unit whatever s turns out to be. This is
    ///      the same guarantee the existing core makes and it is what makes the
    ///      min(BIG, CALM) lending floor provable.
    function merge(bytes32 id, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Pair memory p = _pair(id);

        p.big.burn(msg.sender, amount);
        p.calm.burn(msg.sender, amount);
        collateral.safeTransfer(msg.sender, amount);
        emit Merge(id, msg.sender, amount);
    }

    /// @notice Read the settlement fraction from the oracle and freeze it.
    /// @dev Permissionless and idempotent by revert. Frozen on first call so a
    ///      later oracle change cannot alter a market that has already paid out.
    function settle(bytes32 id) external nonReentrant returns (uint256 s) {
        if (_settledAt[id] != 0) revert MarketAlreadySettled();
        _pair(id);

        s = oracle.settlementFraction(id);
        if (s > ONE) revert BadFraction(s);

        _fraction[id] = s;
        // The window this settles against is measured in hours and the oracle
        // refuses to answer before it closes, so a validator moving the clock by
        // seconds cannot change the outcome. The stamp is a record, not a gate.
        // forge-lint: disable-next-line(block-timestamp)
        _settledAt[id] = block.timestamp;
        emit Settled(id, s, block.timestamp);
    }

    /// @notice Burn BIG and CALM for their share of the locked collateral.
    function redeem(bytes32 id, uint256 bigAmount, uint256 calmAmount)
        external
        nonReentrant
    {
        if (bigAmount == 0 && calmAmount == 0) revert ZeroAmount();
        Pair memory p = _pair(id);
        if (_settledAt[id] == 0) revert MarketNotSettled();

        uint256 s = _fraction[id];
        // Both terms floor, so the sum can never exceed the collateral backing
        // the burned tokens. Dust of at most one base unit stays in the contract.
        uint256 payout = (bigAmount * s) / ONE + (calmAmount * (ONE - s)) / ONE;

        if (bigAmount > 0) p.big.burn(msg.sender, bigAmount);
        if (calmAmount > 0) p.calm.burn(msg.sender, calmAmount);
        if (payout == 0) revert NothingToRedeem();

        collateral.safeTransfer(msg.sender, payout);
        emit Redeem(id, msg.sender, bigAmount, calmAmount, payout);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function tokensOf(bytes32 id) external view returns (address big, address calm) {
        Pair memory p = pairs[id];
        return (address(p.big), address(p.calm));
    }

    function isSettled(bytes32 id) external view returns (bool) {
        return _settledAt[id] != 0;
    }

    function settlementOf(bytes32 id) external view returns (uint256 s, uint256 at) {
        return (_fraction[id], _settledAt[id]);
    }

    function _pair(bytes32 id) internal view returns (Pair memory p) {
        p = pairs[id];
        if (address(p.big) == address(0)) revert MarketNotInitialized();
    }

    function _toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 n = v;
        uint256 digits;
        while (n != 0) { digits++; n /= 10; }
        bytes memory buf = new bytes(digits);
        while (v != 0) {
            digits--;
            // casting to uint8 is safe because v % 10 is 0 through 9, so the sum
            // is 48 through 57, the ASCII digits. Same routine as AlphaMarketCore.
            // forge-lint: disable-next-line(unsafe-typecast)
            buf[digits] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(buf);
    }
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}
