// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPyth} from "./PythOracle.sol";

/// @title PriceRelay
/// @notice Pyth prices are pulled: someone posts a signed price update first, then
///         contracts can read it. This relay does both in one transaction, so a price
///         checkpoint (ContestPrices.poke) or an order (ContestBook.commit) always reads
///         the price posted in the same block. It holds no funds: the Pyth fee comes
///         from msg.value and anything left goes back to the caller.
contract PriceRelay {
    IPyth public immutable pyth;

    error CallFailed(bytes reason);
    error RefundFailed();

    constructor(address pyth_) {
        pyth = IPyth(pyth_);
    }

    function run(bytes[] calldata updates, address target, bytes calldata data) external payable returns (bytes memory ret) {
        uint256 fee;
        if (updates.length > 0) {
            fee = pyth.getUpdateFee(updates);
            pyth.updatePriceFeeds{value: fee}(updates);
        }
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) revert CallFailed(ret);
        uint256 left = msg.value - fee;
        if (left > 0) {
            (bool sent, ) = msg.sender.call{value: left}("");
            if (!sent) revert RefundFailed();
        }
    }
}
