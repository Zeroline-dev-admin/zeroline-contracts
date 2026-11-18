// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test stand-in for the HyperCore oraclePx precompile (0x...0807).
///         Its runtime code is copied to 0x...0807 in tests.
///         Input: abi.encode(uint32 asset). Output: abi.encode(uint64 price).
contract MockOracle {
    mapping(uint32 => uint64) public px;

    function set(uint32 asset, uint64 p) external {
        px[asset] = p;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        uint32 asset = abi.decode(data, (uint32));
        return abi.encode(px[asset]);
    }
}
