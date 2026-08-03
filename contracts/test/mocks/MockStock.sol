// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice An 18 decimal stand-in for a Robinhood stock token.
/// @dev The real token is a beacon proxy that a local simulator cannot resolve,
///      so tests use this instead. Only the ERC20 surface matters here: the
///      arithmetic under test is the decimal conversion between an 18 decimal
///      collateral and a 6 decimal debt asset, and that behaves identically.
contract MockStock is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
