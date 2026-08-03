// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {AlphaMarketCore} from "../src/AlphaMarketCore.sol";
import {OrderBook} from "../src/OrderBook.sol";
import {MarginVault} from "../src/MarginVault.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {MarketTypes} from "../src/types/MarketTypes.sol";

/// @notice A collateral token that hands control to an attacker mid transfer.
/// @dev Real ERC-777 and callback tokens do exactly this. Every contract here
///      carries nonReentrant, but until something actually tries to re-enter,
///      that is an assertion rather than a fact.
contract HostileToken is ERC20 {
    address public target;
    bytes public payload;
    bool public armed;
    bool public fired;
    bool public reentryReverted;

    constructor() ERC20("Hostile", "EVIL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
        fired = false;
        reentryReverted = false;
    }

    function disarm() external {
        armed = false;
    }

    /// @dev The hook fires once, on the way out of a transfer, which is exactly
    ///      when a vulnerable contract has sent funds but not yet updated state.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && target != address(0) && !fired) {
            fired = true;
            (bool ok, ) = target.call(payload);
            reentryReverted = !ok;
        }
    }
}

/// @notice Drives the hostile token against every entry point that moves money.
contract ReentrancyTest is Test {
    HostileToken evil;
    MarketRegistry registry;
    AlphaMarketCore core;
    OrderBook book;
    MarginVault vault;

    address relayer = makeAddr("relayer");
    address arbiter = makeAddr("arbiter");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address proposer = makeAddr("proposer");

    bytes32 constant MID = keccak256("reentrancy-market");
    uint64 constant WINDOW = 2 hours;
    uint64 expiry;
    OutcomeToken yes;
    OutcomeToken no;

    function setUp() public {
        evil = new HostileToken();
        registry = new MarketRegistry(address(evil), 100e6, WINDOW, 0, arbiter, 1 hours, 7 days);
        core = new AlphaMarketCore(address(evil), address(registry));
        book = new OrderBook(address(core), 20);
        vault = new MarginVault(address(core), 500, 1500, 10_000_000e6);

        registry.setRelayer(relayer, true);
        vm.prank(relayer);
        registry.registerMarket(MID, uint64(block.timestamp + 90 days), 0);
        core.initializeMarket(MID);
        (address y, address n) = core.tokensOf(MID);
        yes = OutcomeToken(y);
        no = OutcomeToken(n);
        expiry = uint64(block.timestamp + 30 days);

        address[4] memory who = [alice, bob, proposer, address(this)];
        for (uint256 i = 0; i < who.length; i++) {
            evil.mint(who[i], 1_000_000e6);
            vm.startPrank(who[i]);
            evil.approve(address(core), type(uint256).max);
            evil.approve(address(book), type(uint256).max);
            evil.approve(address(vault), type(uint256).max);
            evil.approve(address(registry), type(uint256).max);
            yes.approve(address(book), type(uint256).max);
            no.approve(address(book), type(uint256).max);
            yes.approve(address(vault), type(uint256).max);
            no.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
        vault.fund(500_000e6);
    }

    // ---------------------------------------------------------------- core

    function test_Split_RepelsReentry() public {
        evil.arm(address(core), abi.encodeCall(AlphaMarketCore.split, (MID, 1_000e6)));
        vm.prank(alice);
        core.split(MID, 1_000e6);

        assertTrue(evil.fired(), "the hook must have run, or this proves nothing");
        assertTrue(evil.reentryReverted(), "re-entry into split was not blocked");
        assertEq(yes.balanceOf(alice), 1_000e6, "exactly one split took effect");
        assertEq(evil.balanceOf(address(core)), 1_000e6, "backing matches supply");
    }

    function test_Merge_RepelsReentry() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);

        evil.arm(address(core), abi.encodeCall(AlphaMarketCore.merge, (MID, 500e6)));
        vm.prank(alice);
        core.merge(MID, 500e6);

        assertTrue(evil.fired());
        assertTrue(evil.reentryReverted(), "re-entry into merge was not blocked");
        assertEq(yes.balanceOf(alice), 500e6);
        assertEq(evil.balanceOf(address(core)), 500e6, "core drained exactly once");
    }

    function test_Redeem_RepelsReentry() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);
        _resolve(MarketTypes.Outcome.Yes);

        evil.arm(address(core), abi.encodeCall(AlphaMarketCore.redeem, (MID, 200e6, 0)));
        vm.prank(alice);
        core.redeem(MID, 1_000e6, 0);

        assertTrue(evil.fired());
        assertTrue(evil.reentryReverted(), "re-entry into redeem was not blocked");
        assertEq(evil.balanceOf(address(core)), 0, "paid out exactly once");
    }

    // ---------------------------------------------------------------- book

    function test_PlaceOrder_RepelsReentry() public {
        evil.arm(
            address(book),
            abi.encodeCall(OrderBook.placeOrder, (MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, expiry))
        );
        vm.prank(alice);
        uint256 id = book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, expiry);

        assertTrue(evil.fired());
        assertTrue(evil.reentryReverted(), "re-entry into placeOrder was not blocked");
        assertEq(book.marketOrderCount(MID), 1, "only one order exists");
        assertEq(evil.balanceOf(address(book)), 600e6, "escrow taken exactly once");
        assertEq(book.getOrder(id).escrow, 600e6);
    }

    function test_Cancel_RepelsReentry() public {
        vm.prank(alice);
        uint256 id = book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, expiry);

        evil.arm(address(book), abi.encodeCall(OrderBook.cancelOrder, (id)));
        uint256 before = evil.balanceOf(alice);
        vm.prank(alice);
        book.cancelOrder(id);

        assertTrue(evil.fired());
        assertTrue(evil.reentryReverted(), "double refund was not blocked");
        assertEq(evil.balanceOf(alice) - before, 600e6, "refunded exactly once");
        assertEq(evil.balanceOf(address(book)), 0);
    }

    function test_Fill_RepelsReentry() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);
        vm.prank(alice);
        uint256 id = book.placeOrder(MID, OrderBook.Side.SellYes, 600_000, 1_000e6, expiry);

        evil.arm(address(book), abi.encodeCall(OrderBook.fill, (id, 100e6)));
        vm.prank(bob);
        book.fill(id, 400e6);

        assertTrue(evil.fired());
        assertTrue(evil.reentryReverted(), "re-entry into fill was not blocked");
        assertEq(yes.balanceOf(bob), 400e6, "taker received exactly what was filled");
        assertEq(book.remainingOf(id), 600e6);
    }

    function test_MatchMint_RepelsReentry() public {
        vm.prank(alice);
        uint256 a = book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, expiry);
        vm.prank(bob);
        uint256 b = book.placeOrder(MID, OrderBook.Side.BuyNo, 450_000, 1_000e6, expiry);

        evil.arm(address(book), abi.encodeCall(OrderBook.matchMint, (a, b, 500e6)));
        book.matchMint(a, b, 1_000e6);

        assertTrue(evil.fired());
        assertTrue(evil.reentryReverted(), "re-entry into matchMint was not blocked");
        assertEq(yes.totalSupply(), 1_000e6, "minted exactly once");
        assertEq(evil.balanceOf(address(core)), 1_000e6, "one unit backs the pair");
    }

    // --------------------------------------------------------------- vault

    function test_Borrow_RepelsReentry() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);
        vm.prank(alice);
        vault.pledge(MID, 1_000e6, 1_000e6);

        evil.arm(address(vault), abi.encodeCall(MarginVault.borrow, (MID, 100e6)));
        uint256 before = evil.balanceOf(alice);
        vm.prank(alice);
        vault.borrow(MID, 500e6);

        assertTrue(evil.fired());
        assertTrue(evil.reentryReverted(), "re-entry into borrow was not blocked");
        assertEq(evil.balanceOf(alice) - before, 500e6, "borrowed exactly once");
        assertEq(vault.debtOf(MID, alice), 500e6, "debt recorded exactly once");
    }

    function test_Settle_RepelsReentry() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);
        vm.startPrank(alice);
        vault.pledge(MID, 1_000e6, 1_000e6);
        vault.borrow(MID, 500e6);
        vm.stopPrank();
        _resolve(MarketTypes.Outcome.Yes);

        evil.arm(address(vault), abi.encodeCall(MarginVault.settle, (MID, alice)));
        vault.settle(MID, alice);

        assertTrue(evil.fired());
        assertTrue(evil.reentryReverted(), "double settle was not blocked");
        assertEq(vault.debtOf(MID, alice), 0);
    }

    /// @notice The hook itself must be proven to work, or every test above is
    ///         vacuously true.
    function test_TheHookActuallyFires() public {
        evil.arm(address(core), abi.encodeCall(AlphaMarketCore.split, (MID, 1e6)));
        assertFalse(evil.fired(), "not fired before any transfer");
        vm.prank(alice);
        evil.transfer(bob, 1e6);
        assertTrue(evil.fired(), "a plain transfer must trigger the hook");
    }

    /// @notice And it must be able to succeed when nothing guards the call,
    ///         otherwise reentryReverted would be true for the wrong reason.
    function test_HookCanSucceedAgainstAnUnguardedTarget() public {
        evil.arm(address(evil), abi.encodeCall(HostileToken.disarm, ()));
        vm.prank(alice);
        evil.transfer(bob, 1e6);
        assertTrue(evil.fired());
        assertFalse(evil.reentryReverted(), "an unguarded call must succeed");
    }

    function _resolve(MarketTypes.Outcome o) internal {
        evil.disarm();
        vm.prank(proposer);
        registry.proposeOutcome(MID, o);
        vm.warp(block.timestamp + WINDOW + 1);
        registry.finalize(MID);
    }
}
