// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title OutcomeToken
/// @notice Freely transferable ERC-20 representing one side of a binary market.
/// @dev Payout accrues to whoever holds the token at resolution; the contract
///      does not track who minted it. Supply is controlled solely by the core.
contract OutcomeToken is ERC20 {
    error OnlyCore();

    /// @notice The AlphaMarketCore permitted to mint and burn.
    address public immutable core;

    uint8 private immutable _decimals;

    modifier onlyCore() {
        if (msg.sender != core) revert OnlyCore();
        _;
    }

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address core_)
        ERC20(name_, symbol_)
    {
        core = core_;
        _decimals = decimals_;
    }

    /// @inheritdoc ERC20
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint outcome tokens. Core only.
    function mint(address to, uint256 amount) external onlyCore {
        _mint(to, amount);
    }

    /// @notice Burn outcome tokens. Core only.
    function burn(address from, uint256 amount) external onlyCore {
        _burn(from, amount);
    }
}
