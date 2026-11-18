// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PostedOracle
/// @notice Prices posted by the operator: the median of public exchange prices at that moment
///         (see the rules file). ContestPrices reads it like the HyperEVM price input: call with
///         abi.encode(uint32 asset), get abi.encode(uint64 price) in the contest format
///         (price x 10^(6 - szDecimals)). Every post is an event with its block time, so anyone
///         can compare each recorded price with the exchanges' public 1-minute candles.
///         The operator cannot post a price for a past moment: a post is stamped with the
///         block time, and a price older than maxAge is refused.
///         Feeds can only be added, never changed or removed.
contract PostedOracle {
    address public immutable operator;
    uint256 public immutable maxAge; // seconds

    struct Feed {
        string symbol;
        int32 szDecimals;
    }

    Feed[] private _feeds;
    mapping(uint32 => uint64) public lastPrice;
    mapping(uint32 => uint64) public lastTime;

    event FeedAdded(uint32 indexed asset, string symbol, int32 szDecimals);
    event Posted(uint64 time, uint32[] assets, uint64[] prices);

    error NotOperator();
    error BadInput();
    error NoPrice(uint32 asset);
    error CallFailed(bytes reason);

    constructor(uint256 maxAge_) {
        if (maxAge_ == 0) revert BadInput();
        operator = msg.sender;
        maxAge = maxAge_;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    function addFeed(string calldata symbol, int32 szDecimals) external onlyOperator returns (uint32 asset) {
        if (bytes(symbol).length == 0 || szDecimals > 6 || szDecimals < -12) revert BadInput();
        asset = uint32(_feeds.length);
        _feeds.push(Feed(symbol, szDecimals));
        emit FeedAdded(asset, symbol, szDecimals);
    }

    function feedCount() external view returns (uint256) {
        return _feeds.length;
    }

    function feed(uint32 asset) external view returns (string memory symbol, int32 szDecimals) {
        Feed storage f = _feeds[asset];
        return (f.symbol, f.szDecimals);
    }

    function post(uint32[] calldata assets, uint64[] calldata prices) public onlyOperator {
        if (assets.length == 0 || assets.length != prices.length) revert BadInput();
        uint64 t = uint64(block.timestamp);
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] >= _feeds.length || prices[i] == 0) revert BadInput();
            lastPrice[assets[i]] = prices[i];
            lastTime[assets[i]] = t;
        }
        emit Posted(t, assets, prices);
    }

    /// @notice Post prices, then make the call that reads them (a price record or an order),
    ///         in one transaction, so the call reads exactly the posted prices.
    function postAndCall(uint32[] calldata assets, uint64[] calldata prices, address target, bytes calldata data)
        external
        onlyOperator
        returns (bytes memory ret)
    {
        post(assets, prices);
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) revert CallFailed(ret);
    }

    function priceOf(uint32 asset) public view returns (uint64) {
        uint64 t = lastTime[asset];
        if (t == 0 || block.timestamp > uint256(t) + maxAge) revert NoPrice(asset);
        return lastPrice[asset];
    }

    /// @dev ContestPrices calls staticcall(abi.encode(uint32 asset)), with no function selector.
    fallback(bytes calldata data) external returns (bytes memory) {
        if (data.length != 32) revert BadInput();
        return abi.encode(priceOf(abi.decode(data, (uint32))));
    }
}
