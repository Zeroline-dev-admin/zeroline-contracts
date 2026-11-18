// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The part of the Pyth price contract that ZEROLINE uses.
interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory);
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
}

/// @title PythOracle
/// @notice Gives ContestPrices the same price input it reads on HyperEVM: call with
///         abi.encode(uint32 asset), get abi.encode(uint64 price). The price comes from
///         Pyth, whose prices are signed by Pyth's data publishers, so whoever submits a
///         price update cannot choose the number, only the moment.
///         Asset numbers are positions in the feed list. Feeds can only be added, never
///         changed or removed, so a running contest always reads the same feeds.
///         Price format: raw = price * 10^scale (scale is fixed per feed when it is added).
contract PythOracle {
    IPyth public immutable pyth;
    uint256 public immutable maxAge; // seconds: older prices are refused
    uint256 public immutable maxConfBps; // refuse a price whose uncertainty is wider than this
    address public immutable admin;

    struct Feed {
        bytes32 id;
        int32 scale;
        string symbol;
    }

    Feed[] private _feeds;

    event FeedAdded(uint32 indexed asset, bytes32 id, int32 scale, string symbol);

    error NotAdmin();
    error BadFeed();
    error NoPrice(uint32 asset);

    constructor(address pyth_, uint256 maxAge_, uint256 maxConfBps_) {
        if (pyth_ == address(0) || maxAge_ == 0 || maxConfBps_ == 0) revert BadFeed();
        pyth = IPyth(pyth_);
        maxAge = maxAge_;
        maxConfBps = maxConfBps_;
        admin = msg.sender;
    }

    function addFeed(bytes32 id, int32 scale, string calldata symbol) external returns (uint32 asset) {
        if (msg.sender != admin) revert NotAdmin();
        if (id == bytes32(0) || scale < 0 || scale > 18) revert BadFeed();
        asset = uint32(_feeds.length);
        _feeds.push(Feed(id, scale, symbol));
        emit FeedAdded(asset, id, scale, symbol);
    }

    function feedCount() external view returns (uint256) {
        return _feeds.length;
    }

    function feed(uint32 asset) external view returns (bytes32 id, int32 scale, string memory symbol) {
        Feed storage f = _feeds[asset];
        return (f.id, f.scale, f.symbol);
    }

    /// @notice Current price of an asset in the contest format. Reverts if Pyth has no
    ///         price newer than maxAge, or the price is too uncertain.
    function priceOf(uint32 asset) public view returns (uint64) {
        if (asset >= _feeds.length) revert NoPrice(asset);
        Feed storage f = _feeds[asset];
        IPyth.Price memory p = pyth.getPriceNoOlderThan(f.id, maxAge);
        if (p.price <= 0) revert NoPrice(asset);
        uint256 v = uint256(uint64(p.price));
        if (uint256(p.conf) * 10_000 > v * maxConfBps) revert NoPrice(asset);
        int256 e = int256(p.expo) + int256(f.scale);
        if (e >= 0) {
            if (e > 18) revert NoPrice(asset);
            v = v * 10 ** uint256(e);
        } else {
            if (e < -30) revert NoPrice(asset);
            v = v / 10 ** uint256(-e);
        }
        if (v == 0 || v > type(uint64).max) revert NoPrice(asset);
        return uint64(v);
    }

    /// @dev ContestPrices calls staticcall(abi.encode(uint32 asset)), with no function selector.
    fallback(bytes calldata data) external returns (bytes memory) {
        if (data.length != 32) revert BadFeed();
        return abi.encode(priceOf(abi.decode(data, (uint32))));
    }
}
