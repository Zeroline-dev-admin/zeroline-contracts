// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Testnet-only prize token for COOKED. No value. 6 decimals like USDC.
///         Supports permit, so an organizer can deposit a prize pool with a signature.
///         The faucet gives each address up to `faucetAmount` once per `faucetCooldown`;
///         the platform operator relays it so users need no gas.
contract TestUSDC is ERC20, ERC20Permit {
    address public immutable minter;
    uint256 public constant faucetAmount = 10_000e6;
    uint256 public constant faucetCooldown = 1 days;
    mapping(address => uint256) public lastFaucet;

    error NotMinter();
    error TooSoon(uint256 nextAt);

    constructor() ERC20("Test USDC (COOKED testnet, no value)", "tUSDC") ERC20Permit("tUSDC") {
        minter = msg.sender;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Faucet, relayed by the operator for `to`.
    function faucet(address to) external {
        if (msg.sender != minter) revert NotMinter();
        uint256 next = lastFaucet[to] + faucetCooldown;
        if (lastFaucet[to] != 0 && block.timestamp < next) revert TooSoon(next);
        lastFaucet[to] = block.timestamp;
        _mint(to, faucetAmount);
    }

    /// @notice Operator mint for the platform's own featured contests.
    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        _mint(to, amount);
    }
}
