// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title PostedOracleV2
/// @notice PostedOracle plus one way in: a player's own transaction can carry a price the
///         operator signed for exactly that order (postSignedAndCall). The order then leaves
///         from the player's address (gas can be sponsored by a paymaster), and it still fills
///         at a fresh operator price, read in the same transaction.
///         Everything else is as in PostedOracle: ContestPrices reads it with
///         staticcall(abi.encode(uint32 asset)), a price older than maxAge is refused, every post
///         is a Posted event, feeds can only be added.
///         A signed price:
///         - is bound to this chain, this oracle, one order book, one player and one sealed order
///           (commit hash), so it cannot be used for any other order;
///         - can be used once, and only within signedTtl seconds of being issued;
///         - can never move a feed back to an older price than the one already posted.
contract PostedOracleV2 {
    address public immutable operator;
    uint256 public immutable maxAge; // seconds
    uint256 public immutable signedTtl; // seconds a signed price stays usable

    /// ContestBook.commit(address player, bytes32 commitHash, uint64 deadline, bytes signature)
    bytes4 public constant COMMIT_SELECTOR = bytes4(keccak256("commit(address,bytes32,uint64,bytes)"));

    struct Feed {
        string symbol;
        int32 szDecimals;
    }

    Feed[] private _feeds;
    mapping(uint32 => uint64) public lastPrice;
    mapping(uint32 => uint64) public lastTime; // block time of the last post (freshness)
    mapping(uint32 => uint64) public lastIssued; // the moment the last price was taken (ordering)
    mapping(bytes32 => bool) public usedSignature;

    event FeedAdded(uint32 indexed asset, string symbol, int32 szDecimals);
    event Posted(uint64 time, uint32[] assets, uint64[] prices);
    event SignedPosted(address indexed player, address indexed target, bytes32 commitHash, uint64 issuedAt);

    error NotOperator();
    error BadInput();
    error NoPrice(uint32 asset);
    error CallFailed(bytes reason);
    error BadPriceSignature();
    error PriceExpired();
    error PriceOlderThanPosted(uint32 asset);
    error PriceUsed();
    error NotThisOrder();

    constructor(uint256 maxAge_, uint256 signedTtl_) {
        if (maxAge_ == 0 || signedTtl_ == 0 || signedTtl_ > maxAge_) revert BadInput();
        operator = msg.sender;
        maxAge = maxAge_;
        signedTtl = signedTtl_;
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

    function _store(uint32[] calldata assets, uint64[] calldata prices, uint64 issued, bool checkOrder) private {
        if (assets.length == 0 || assets.length != prices.length) revert BadInput();
        uint64 t = uint64(block.timestamp);
        for (uint256 i; i < assets.length; ++i) {
            uint32 a = assets[i];
            if (a >= _feeds.length || prices[i] == 0) revert BadInput();
            if (checkOrder && issued < lastIssued[a]) revert PriceOlderThanPosted(a);
            lastPrice[a] = prices[i];
            lastTime[a] = t;
            if (issued > lastIssued[a]) lastIssued[a] = issued;
        }
        emit Posted(t, assets, prices);
    }

    function post(uint32[] calldata assets, uint64[] calldata prices) public onlyOperator {
        _store(assets, prices, uint64(block.timestamp), false);
    }

    /// @notice Post prices, then make the call that reads them, in one transaction (operator).
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

    /// @notice The message the operator signs for one order's price
    ///         (pricesHash = keccak256(abi.encode(uint32[] assets, uint64[] prices))).
    function signedPriceDigest(address target, address player, bytes32 commitHash, uint64 issuedAt, bytes32 pricesHash)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(this), target, player, commitHash, issuedAt, pricesHash));
    }

    /// @notice Anyone (normally the player) sends a sealed order to an order book together with
    ///         the price the operator signed for it. The order must be ContestBook.commit for the
    ///         same player and commit hash the operator signed; the book still checks the
    ///         player's own signature on the order.
    function postSignedAndCall(
        uint32[] calldata assets,
        uint64[] calldata prices,
        uint64 issuedAt,
        bytes calldata operatorSig,
        address target,
        bytes calldata data
    ) external returns (bytes memory ret) {
        if (issuedAt > block.timestamp + 5 || block.timestamp > uint256(issuedAt) + signedTtl) revert PriceExpired();
        _useSignature(keccak256(abi.encode(assets, prices)), issuedAt, operatorSig, target, data);
        _store(assets, prices, issuedAt, true);
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) revert CallFailed(ret);
    }

    function _useSignature(
        bytes32 pricesHash,
        uint64 issuedAt,
        bytes calldata operatorSig,
        address target,
        bytes calldata data
    ) private {
        if (data.length < 4 + 64 || bytes4(data[:4]) != COMMIT_SELECTOR) revert NotThisOrder();
        (address player, bytes32 commitHash) = abi.decode(data[4:68], (address, bytes32));
        bytes32 digest = signedPriceDigest(target, player, commitHash, issuedAt, pricesHash);
        if (usedSignature[digest]) revert PriceUsed();
        if (ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(digest), operatorSig) != operator) revert BadPriceSignature();
        usedSignature[digest] = true;
        emit SignedPosted(player, target, commitHash, issuedAt);
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
