// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainlinkRounds, IAggregatorV3} from "../src/ChainlinkRounds.sol";

/**
 * An external wrapper around the library.
 *
 * The library functions are internal, so a test that calls them directly has
 * them inlined and any revert happens inside the test contract itself, where
 * vm.expectRevert cannot see it. Routing through a real external call puts the
 * revert where the cheatcode expects it, and costs nothing in production because
 * this contract is never deployed outside of tests.
 */
contract RoundsHarness {
    function lastAtOrBefore(IAggregatorV3 feed, uint256 target, uint256 maxSteps)
        external
        view
        returns (ChainlinkRounds.Round memory)
    {
        return ChainlinkRounds.lastAtOrBefore(feed, target, maxSteps);
    }

    function firstAtOrAfter(IAggregatorV3 feed, uint256 target, uint256 maxSteps)
        external
        view
        returns (ChainlinkRounds.Round memory)
    {
        return ChainlinkRounds.firstAtOrAfter(feed, target, maxSteps);
    }
}
