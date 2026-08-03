// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title TestDollar
/// @notice Settlement collateral for Alpha Market on Robinhood Chain testnet,
///         with a self-service faucet so a tester needs nothing from the team.
///
/// @dev WHY THIS EXISTS, STATED PLAINLY
///      USDG is issued by Paxos and is not deployed on testnet 46630. Verified
///      2026-08-02: the official Robinhood faucet distributes testnet ETH and
///      five stock tokens and no stablecoin, and every USDG-named contract
///      found on the testnet explorer is a third-party deployment absent from
///      mainnet. A prediction market settles in a unit that is worth the same
///      tomorrow as today, so settling in a stock token is not an option
///      either: the holder would be betting on the question and on the equity
///      at once.
///
///      This contract is therefore a deliberate testnet stand-in, named so that
///      nobody can mistake it for USDG. On mainnet the same contracts take the
///      real USDG address through the COLLATERAL environment variable and this
///      contract is simply not deployed. No production code depends on it.
///
/// @dev WHY THE FAUCET IS RATE LIMITED RATHER THAN OPEN
///      An unlimited mint makes every balance meaningless: anyone can conjure
///      enough to move any price, so nothing observed on the venue reflects
///      real behaviour. A per-address allowance with a cooldown keeps balances
///      scarce enough that order books, collateral ratios and liquidations
///      behave the way they will on mainnet, which is the entire point of
///      running a testnet.
contract TestDollar is ERC20, Ownable {
    error CooldownActive(uint256 availableAt);
    error FaucetEmpty();
    error BadParams();

    /// @notice Amount minted per claim.
    uint256 public claimAmount;

    /// @notice Seconds an address must wait between claims.
    uint256 public cooldown;

    /// @notice Hard ceiling on total supply, so the faucet cannot inflate
    ///         without bound if it is left running for months.
    uint256 public supplyCap;

    mapping(address => uint256) public lastClaimedAt;

    event Claimed(address indexed to, uint256 amount, uint256 nextClaimAt);
    event FaucetConfigured(uint256 claimAmount, uint256 cooldown, uint256 supplyCap);

    constructor(uint256 claimAmount_, uint256 cooldown_, uint256 supplyCap_)
        ERC20("Alpha Test Dollar", "aUSD")
        Ownable(msg.sender)
    {
        if (claimAmount_ == 0 || supplyCap_ < claimAmount_) revert BadParams();
        claimAmount = claimAmount_;
        cooldown = cooldown_;
        supplyCap = supplyCap_;
        emit FaucetConfigured(claimAmount_, cooldown_, supplyCap_);
    }

    /// @dev Six decimals mirrors USDG, so every amount, price and rounding rule
    ///      carries over to mainnet unchanged.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Claim testnet collateral. Permissionless, rate limited.
    /// @dev Mints to msg.sender rather than an argument, so one address cannot
    ///      farm the faucet by naming a different recipient each call.
    function claim() external returns (uint256) {
        uint256 next = lastClaimedAt[msg.sender] + cooldown;
        if (lastClaimedAt[msg.sender] != 0 && block.timestamp < next) {
            revert CooldownActive(next);
        }
        if (totalSupply() + claimAmount > supplyCap) revert FaucetEmpty();

        lastClaimedAt[msg.sender] = block.timestamp;
        _mint(msg.sender, claimAmount);
        emit Claimed(msg.sender, claimAmount, block.timestamp + cooldown);
        return claimAmount;
    }

    /// @notice When `who` may claim again. Zero means immediately.
    function claimableAt(address who) external view returns (uint256) {
        if (lastClaimedAt[who] == 0) return 0;
        uint256 next = lastClaimedAt[who] + cooldown;
        return block.timestamp >= next ? 0 : next;
    }

    function canClaim(address who) external view returns (bool) {
        if (totalSupply() + claimAmount > supplyCap) return false;
        if (lastClaimedAt[who] == 0) return true;
        return block.timestamp >= lastClaimedAt[who] + cooldown;
    }

    /// @notice Adjust faucet parameters. Testnet operations only.
    function configure(uint256 claimAmount_, uint256 cooldown_, uint256 supplyCap_)
        external
        onlyOwner
    {
        if (claimAmount_ == 0 || supplyCap_ < totalSupply()) revert BadParams();
        claimAmount = claimAmount_;
        cooldown = cooldown_;
        supplyCap = supplyCap_;
        emit FaucetConfigured(claimAmount_, cooldown_, supplyCap_);
    }
}
