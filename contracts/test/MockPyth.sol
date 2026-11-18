// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPyth} from "../PythOracle.sol";

/// @notice Test stand-in for the Pyth contract. An "update" is abi.encode(id, price, conf,
///         expo, publishTime); the real Pyth checks publisher signatures instead.
///         set() posts a price directly (for tests that only move the market).
contract MockPyth is IPyth {
    mapping(bytes32 => Price) public prices;
    uint256 public feePerUpdate;

    constructor(uint256 fee_) {
        feePerUpdate = fee_;
    }

    function set(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime) external {
        prices[id] = Price(price, conf, expo, publishTime);
    }

    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256) {
        return updateData.length * feePerUpdate;
    }

    function updatePriceFeeds(bytes[] calldata updateData) external payable {
        require(msg.value >= updateData.length * feePerUpdate, "fee");
        for (uint256 i; i < updateData.length; ++i) {
            (bytes32 id, int64 price, uint64 conf, int32 expo, uint256 t) = abi.decode(updateData[i], (bytes32, int64, uint64, int32, uint256));
            if (t > prices[id].publishTime) prices[id] = Price(price, conf, expo, t);
        }
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory p) {
        p = prices[id];
        require(p.publishTime != 0, "no price");
        require(block.timestamp <= p.publishTime + age || p.publishTime > block.timestamp, "stale");
    }
}
