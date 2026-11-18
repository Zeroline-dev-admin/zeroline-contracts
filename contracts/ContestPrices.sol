// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ContestPrices
/// @notice Records HyperCore oracle prices for the contest coins, at most once
///         per slot. Anyone may call poke(). The contract reads the oracle
///         itself (HyperEVM read precompile 0x...0807), so the caller never
///         supplies a price. The caller only chooses the moment inside the slot.
contract ContestPrices {
    // Set once by initialize(): each contest is a minimal clone made by CookedFactory.
    address public oracle;
    uint64 public startTime;
    uint64 public endTime;
    uint32 public interval;
    bool private _initialized;
    uint32[] private _coins; // HyperCore perp asset indices

    uint256 public constant MAX_COINS = 10;

    mapping(uint256 => uint64) public checkpointTime; // slot => block time
    mapping(uint256 => uint64[]) private _px; // slot => prices, same order as coins
    uint256 public checkpointCount;

    event Checkpoint(uint256 indexed slot, uint64 time, uint64[] prices);

    error BadConfig();
    error WrongPhase();
    error SlotTaken();
    error OracleFailed(uint32 asset);

    error AlreadyInitialized();

    /// @dev The implementation itself can never be initialized.
    constructor() {
        _initialized = true;
    }

    function initialize(address oracle_, uint64 start_, uint64 end_, uint32 interval_, uint32[] calldata coins_) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        if (oracle_ == address(0) || start_ >= end_ || interval_ == 0 || coins_.length == 0 || coins_.length > MAX_COINS) {
            revert BadConfig();
        }
        oracle = oracle_;
        startTime = start_;
        endTime = end_;
        interval = interval_;
        for (uint256 i; i < coins_.length; ++i) _coins.push(coins_[i]);
    }

    /// @notice Slot index that contains endTime. Its price is the closing price.
    function lastSlot() public view returns (uint256) {
        return (uint256(endTime) - startTime) / interval;
    }

    function poke() external {
        if (block.timestamp < startTime) revert WrongPhase();
        uint256 slot = (block.timestamp - startTime) / interval;
        if (slot > lastSlot()) revert WrongPhase();
        if (checkpointTime[slot] != 0) revert SlotTaken();
        uint64[] memory px = readAll();
        checkpointTime[slot] = uint64(block.timestamp);
        _px[slot] = px;
        checkpointCount += 1;
        emit Checkpoint(slot, uint64(block.timestamp), px);
    }

    /// @notice Current oracle price of every contest coin, read on chain. ContestBook
    ///         calls this at every commit, so a market order's price is the price in
    ///         the block that recorded it.
    function readAll() public view returns (uint64[] memory px) {
        uint256 n = _coins.length;
        px = new uint64[](n);
        for (uint256 i; i < n; ++i) {
            uint32 asset = _coins[i];
            (bool ok, bytes memory ret) = oracle.staticcall(abi.encode(asset));
            if (!ok || ret.length < 32) revert OracleFailed(asset);
            uint64 p = abi.decode(ret, (uint64));
            if (p == 0) revert OracleFailed(asset);
            px[i] = p;
        }
    }

    function coins() external view returns (uint32[] memory) {
        return _coins;
    }

    function getCheckpoint(uint256 slot) external view returns (uint64 time, uint64[] memory prices) {
        return (checkpointTime[slot], _px[slot]);
    }

    /// @notice Batch read for verifiers: slots [from, to).
    function getCheckpoints(uint256 from, uint256 to) external view returns (uint64[] memory times, uint64[][] memory prices) {
        uint256 last = lastSlot() + 1;
        if (to > last) to = last;
        if (from > to) from = to;
        times = new uint64[](to - from);
        prices = new uint64[][](to - from);
        for (uint256 s = from; s < to; ++s) {
            times[s - from] = checkpointTime[s];
            prices[s - from] = _px[s];
        }
    }
}
