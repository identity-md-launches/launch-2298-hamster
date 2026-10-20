// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title HAMSTER ($HAMSTER)
/// @notice A fixed-supply ERC-20 with EIP-2612 permit and nothing else.
/// @dev Design, in one place:
///  - The whole supply, `TOTAL_SUPPLY`, is minted once in the constructor to `msg.sender`
///    (the launch factory). There is no mint function, no minter role and no owner: the supply
///    can never grow after deployment, by anyone.
///  - Transfers are plain: no tax, no burn-on-transfer, no reflection, no limits, no
///    allow-list or block-list, no pause. Every transfer moves exactly the amount asked for,
///    so the launch flows (factory -> distributor -> claimants, factory -> pool, pool <-> traders)
///    arrive whole.
///  - The constructor takes no arguments and calls no other contract, so it deploys on an
///    empty chain and never depends on an address having code.
///  - `permit` (EIP-2612) lets holders approve spenders with a signature instead of a
///    transaction. It carries a nonce and a deadline and uses the chain id in its domain,
///    so a signature cannot be replayed on this chain or another.
///  - All library code is internal; the runtime bytecode contains no DELEGATECALL, CALLCODE
///    or SELFDESTRUCT and no proxy.
contract HamsterToken is ERC20, ERC20Permit {
    /// @notice The token's ERC-20 name.
    string public constant NAME = "HAMSTER";

    /// @notice The token's ERC-20 symbol.
    string public constant SYMBOL = "HAMSTER";

    /// @notice Decimals: the ERC-20 default of 18, inherited unchanged from OpenZeppelin's ERC20.
    uint8 public constant DECIMALS = 18;

    /// @notice The fixed supply: 1,000,000,000 HAMSTER in minor units (18 decimals).
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** DECIMALS;

    /// @notice Mints the whole fixed supply to the deployer. Nothing can mint afterwards.
    constructor() ERC20(NAME, SYMBOL) ERC20Permit(NAME) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
