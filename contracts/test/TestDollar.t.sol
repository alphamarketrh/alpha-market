// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TestDollar} from "../src/TestDollar.sol";

contract TestDollarTest is Test {
    TestDollar usd;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant CLAIM = 10_000e6;
    uint256 constant COOLDOWN = 12 hours;
    uint256 constant CAP = 100_000_000e6;

    function setUp() public {
        usd = new TestDollar(CLAIM, COOLDOWN, CAP);
    }

    function test_Decimals_MatchUSDG() public view {
        assertEq(usd.decimals(), 6, "must mirror USDG so amounts carry to mainnet");
    }

    function test_Claim_MintsAndStartsCooldown() public {
        vm.prank(alice);
        usd.claim();
        assertEq(usd.balanceOf(alice), CLAIM);
        assertFalse(usd.canClaim(alice));
        assertEq(usd.claimableAt(alice), block.timestamp + COOLDOWN);
    }

    function test_Claim_BlockedDuringCooldown() public {
        vm.startPrank(alice);
        usd.claim();
        vm.expectRevert();
        usd.claim();
        vm.stopPrank();
    }

    function test_Claim_AllowedAfterCooldown() public {
        vm.prank(alice);
        usd.claim();
        vm.warp(block.timestamp + COOLDOWN);
        assertTrue(usd.canClaim(alice));
        vm.prank(alice);
        usd.claim();
        assertEq(usd.balanceOf(alice), CLAIM * 2);
    }

    /// @notice Minting to msg.sender is what stops one address farming the
    ///         faucet by naming a fresh recipient on every call.
    function test_Claim_CannotBeFarmedByNamingRecipients() public {
        vm.startPrank(alice);
        usd.claim();
        vm.expectRevert();
        usd.claim();
        vm.stopPrank();
        assertEq(usd.balanceOf(alice), CLAIM, "one claim per address per window");
    }

    function test_Claim_IndependentPerAddress() public {
        vm.prank(alice);
        usd.claim();
        vm.prank(bob);
        usd.claim();
        assertEq(usd.balanceOf(alice), CLAIM);
        assertEq(usd.balanceOf(bob), CLAIM);
    }

    function test_SupplyCap_StopsTheFaucet() public {
        usd.configure(CLAIM, COOLDOWN, CLAIM);      // room for exactly one claim
        vm.prank(alice);
        usd.claim();
        assertFalse(usd.canClaim(bob));
        vm.prank(bob);
        vm.expectRevert(TestDollar.FaucetEmpty.selector);
        usd.claim();
    }

    function test_Configure_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        usd.configure(1e6, 1 hours, CAP);
        usd.configure(1e6, 1 hours, CAP);
        assertEq(usd.claimAmount(), 1e6);
    }

    function test_Configure_RejectsCapBelowSupply() public {
        vm.prank(alice);
        usd.claim();
        vm.expectRevert(TestDollar.BadParams.selector);
        usd.configure(CLAIM, COOLDOWN, CLAIM - 1);
    }

    function test_Constructor_RejectsBadParams() public {
        vm.expectRevert(TestDollar.BadParams.selector);
        new TestDollar(0, COOLDOWN, CAP);
        vm.expectRevert(TestDollar.BadParams.selector);
        new TestDollar(CLAIM, COOLDOWN, CLAIM - 1);
    }

    /// @notice Supply must never exceed the cap under any claim sequence.
    function testFuzz_SupplyNeverExceedsCap(uint8 claimers, uint32 gap) public {
        uint256 n = uint256(claimers) % 40 + 1;
        for (uint256 i = 0; i < n; i++) {
            address who = address(uint160(0x1000 + i));
            if (usd.canClaim(who)) {
                vm.prank(who);
                usd.claim();
            }
            vm.warp(block.timestamp + (uint256(gap) % 2 days));
        }
        assertLe(usd.totalSupply(), usd.supplyCap(), "cap is absolute");
    }
}
