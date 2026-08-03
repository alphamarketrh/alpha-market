// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle, IAggregatorV3} from "./interfaces/IPriceOracle.sol";

/// @title PriceOracle
/// @notice Equity prices for CrossVault, from a Chainlink aggregator where one
///         exists and from a bonded pusher where one does not.
///
/// @dev WHY TWO MODES
///      The tokenized equities on Robinhood Chain testnet are plain ERC-20s with
///      no on-chain feed (verified 2026-07-28: no priceFeed(), oracle() or
///      aggregator() selector on any of the five faucet tokens). Push mode makes
///      the vault testable today; on mainnet each token is switched to Aggregator
///      mode by an owner call, with no change to CrossVault.
///
/// @dev THIS IS A TRUST DOWNGRADE, STATED PLAINLY
///      MarginVault needs no oracle at all: min(YES, NO) is a proven floor.
///      Equities have no floor, so this contract becomes a live attack surface.
///      In push mode the pusher can set any price and therefore can cause
///      liquidations. Push mode must never be used on mainnet for a token that
///      has a real feed.
contract PriceOracle is IPriceOracle, Ownable {
    error ZeroAddress();
    error NotPusher();
    error NotConfigured(address token);
    error StalePrice(address token, uint256 updatedAt, uint256 maxAge);
    error BadPrice(int256 answer);
    error PushDisabled(address token);
    error BadParams();

    enum Mode { None, Aggregator, Push }

    struct Feed {
        Mode mode;
        address aggregator;    // Chainlink AggregatorV3
        uint8 aggDecimals;
        uint256 pushPrice;     // 8 decimals
        uint256 pushedAt;
    }

    uint8 public constant PRICE_DECIMALS = 8;

    /// @notice Maximum age of a price before it is refused.
    /// @dev Equities do not trade 24/7 while this chain does, so the window must
    ///      cover a weekend plus a holiday. A stale price is refused rather than
    ///      extrapolated, which freezes borrowing and liquidation together.
    uint256 public maxAge;

    mapping(address => Feed) private _feeds;
    mapping(address => bool) public isPusher;
    address[] public tokens;

    event FeedSet(address indexed token, Mode mode, address aggregator);
    event PricePushed(address indexed token, uint256 price, uint256 at);
    event PusherSet(address indexed pusher, bool allowed);
    event MaxAgeSet(uint256 maxAge);

    modifier onlyPusher() {
        if (!isPusher[msg.sender]) revert NotPusher();
        _;
    }

    constructor(uint256 maxAge_) Ownable(msg.sender) {
        if (maxAge_ == 0) revert BadParams();
        maxAge = maxAge_;
        emit MaxAgeSet(maxAge_);
    }

    // ----------------------------------------------------------------- admin

    function setMaxAge(uint256 maxAge_) external onlyOwner {
        if (maxAge_ == 0) revert BadParams();
        maxAge = maxAge_;
        emit MaxAgeSet(maxAge_);
    }

    function setPusher(address pusher, bool allowed) external onlyOwner {
        if (pusher == address(0)) revert ZeroAddress();
        isPusher[pusher] = allowed;
        emit PusherSet(pusher, allowed);
    }

    /// @notice Point a token at a Chainlink aggregator. Preferred mode.
    function setAggregator(address token, address aggregator) external onlyOwner {
        if (token == address(0) || aggregator == address(0)) revert ZeroAddress();
        Feed storage f = _feeds[token];
        if (f.mode == Mode.None) tokens.push(token);
        f.mode = Mode.Aggregator;
        f.aggregator = aggregator;
        f.aggDecimals = IAggregatorV3(aggregator).decimals();
        emit FeedSet(token, Mode.Aggregator, aggregator);
    }

    /// @notice Enable push mode for a token with no aggregator.
    function enablePush(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        Feed storage f = _feeds[token];
        if (f.mode == Mode.None) tokens.push(token);
        f.mode = Mode.Push;
        f.aggregator = address(0);
        emit FeedSet(token, Mode.Push, address(0));
    }

    // ------------------------------------------------------------------ push

    function pushPrice(address token, uint256 price8) external onlyPusher {
        Feed storage f = _feeds[token];
        if (f.mode != Mode.Push) revert PushDisabled(token);
        if (price8 == 0) revert BadPrice(0);
        f.pushPrice = price8;
        f.pushedAt = block.timestamp;
        emit PricePushed(token, price8, block.timestamp);
    }

    function pushPrices(address[] calldata tokens_, uint256[] calldata prices8)
        external
        onlyPusher
    {
        if (tokens_.length != prices8.length) revert BadParams();
        for (uint256 i = 0; i < tokens_.length; i++) {
            Feed storage f = _feeds[tokens_[i]];
            if (f.mode != Mode.Push) revert PushDisabled(tokens_[i]);
            if (prices8[i] == 0) revert BadPrice(0);
            f.pushPrice = prices8[i];
            f.pushedAt = block.timestamp;
            emit PricePushed(tokens_[i], prices8[i], block.timestamp);
        }
    }

    // ----------------------------------------------------------------- reads

    /// @inheritdoc IPriceOracle
    function getPrice(address token) public view returns (uint256 price, uint256 updatedAt) {
        Feed storage f = _feeds[token];
        if (f.mode == Mode.None) revert NotConfigured(token);

        if (f.mode == Mode.Push) {
            price = f.pushPrice;
            updatedAt = f.pushedAt;
        } else {
            (, int256 answer,, uint256 ts, uint80 answeredIn) =
                IAggregatorV3(f.aggregator).latestRoundData();
            if (answer <= 0) revert BadPrice(answer);
            if (answeredIn == 0) revert BadPrice(answer);
            updatedAt = ts;
            uint8 d = f.aggDecimals;
            price = d == PRICE_DECIMALS
                ? uint256(answer)
                : (d > PRICE_DECIMALS
                    ? uint256(answer) / (10 ** (d - PRICE_DECIMALS))
                    : uint256(answer) * (10 ** (PRICE_DECIMALS - d)));
        }

        if (price == 0) revert BadPrice(0);
        if (block.timestamp > updatedAt + maxAge) {
            revert StalePrice(token, updatedAt, maxAge);
        }
    }

    /// @inheritdoc IPriceOracle
    function isSupported(address token) external view returns (bool) {
        Feed storage f = _feeds[token];
        if (f.mode == Mode.None) return false;
        (bool ok,) = address(this).staticcall(
            abi.encodeWithSelector(this.getPrice.selector, token)
        );
        return ok;
    }

    function feedOf(address token) external view returns (Feed memory) {
        return _feeds[token];
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }
}
