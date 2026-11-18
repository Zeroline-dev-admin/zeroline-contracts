// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

interface IContestPrices {
    function readAll() external view returns (uint64[] memory);
}

/// @title ContestBook
/// @notice Sealed actions. A player (or a session key the player approved once)
///         signs a hash of the action; anyone (the relayer) submits it and pays gas.
///         At the commit the contract records the block time and the oracle price of
///         every contest coin, so a market order fills at the price of the block that
///         recorded it. After endTime the plaintext is revealed and must match the hash.
///         The contract does not score; invalid actions are ignored by the public rules.
contract ContestBook is EIP712 {
    // Set once by initialize(): each contest is a minimal clone made by CookedFactory.
    address public prices; // ContestPrices of this contest
    uint64 public startTime;
    uint64 public endTime;
    uint64 public revealDeadline;
    uint32 public maxActions; // per player
    bool private _initialized;

    bytes32 public constant COMMIT_TYPEHASH =
        keccak256("Commit(address player,uint256 nonce,bytes32 commitHash,uint64 deadline)");
    bytes32 public constant SESSION_TYPEHASH =
        keccak256("Session(address player,address sessionKey,uint64 expiry)");

    struct Action {
        bytes32 commitHash;
        uint64 commitTime;
        bool revealed;
        uint8 kind; // 1 = open, 2 = close position or cancel order
        uint8 coin; // index into ContestPrices.coins()
        bool isLong;
        uint8 leverage;
        uint8 orderType; // 0 = market, 1 = limit
        uint32 posId;
        uint64 margin; // micro points
        uint64 stopPx; // raw oracle units, 0 = none
        uint64 tpPx; // take profit, raw oracle units, 0 = none
        uint64 limitPx; // limit: the limit price. market: worst accepted price (0 = any)
        uint64[] commitPx; // oracle price of every coin in the commit block
    }

    struct RevealInput {
        address player;
        uint256 nonce;
        uint8 kind;
        uint32 posId;
        uint8 coin;
        bool isLong;
        uint8 leverage;
        uint8 orderType;
        uint64 margin;
        uint64 stopPx;
        uint64 tpPx;
        uint64 limitPx;
        bytes32 salt;
    }

    mapping(address => uint256) public nonces;
    mapping(address => mapping(uint256 => Action)) private _actions;
    address[] private _players;
    mapping(address => bool) public joined;
    mapping(address => address) public sessionKey;
    mapping(address => uint64) public sessionExpiry;

    event Joined(address indexed player);
    event SessionApproved(address indexed player, address sessionKey, uint64 expiry);
    event Committed(address indexed player, uint256 indexed nonce, bytes32 commitHash, uint64 time, uint64[] prices);
    event Revealed(address indexed player, uint256 indexed nonce);

    error BadConfig();
    error WrongPhase();
    error BadSignature();
    error Expired();
    error TooManyActions();
    error UnknownCommit();
    error AlreadyRevealed();
    error HashMismatch();

    error AlreadyInitialized();

    /// @dev EIP712 name and version live in the implementation's code; a clone's
    ///      domain separator uses the clone's own address. The implementation itself
    ///      can never be initialized.
    constructor() EIP712("ContestBook", "2") {
        _initialized = true;
    }

    function initialize(address prices_, uint64 start_, uint64 end_, uint64 revealDeadline_, uint32 maxActions_) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        if (prices_ == address(0) || start_ >= end_ || end_ >= revealDeadline_ || maxActions_ == 0) revert BadConfig();
        prices = prices_;
        startTime = start_;
        endTime = end_;
        revealDeadline = revealDeadline_;
        maxActions = maxActions_;
    }

    /// @notice The player approves a session key once; it can then sign commits for
    ///         this contest only, until `expiry` (at most the contest end). Anyone may
    ///         submit the approval. A later approval replaces the earlier key.
    function approveSession(address player, address key, uint64 expiry, bytes calldata signature) external {
        if (block.timestamp >= endTime) revert WrongPhase();
        if (expiry > endTime || expiry <= block.timestamp || key == address(0)) revert Expired();
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(SESSION_TYPEHASH, player, key, expiry)));
        if (ECDSA.recover(digest, signature) != player) revert BadSignature();
        sessionKey[player] = key;
        sessionExpiry[player] = expiry;
        emit SessionApproved(player, key, expiry);
    }

    function commit(address player, bytes32 commitHash, uint64 deadline, bytes calldata signature) external {
        if (block.timestamp < startTime || block.timestamp >= endTime) revert WrongPhase();
        if (block.timestamp > deadline) revert Expired();
        uint256 nonce = nonces[player];
        if (nonce >= maxActions) revert TooManyActions();
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(COMMIT_TYPEHASH, player, nonce, commitHash, deadline)));
        address signer = ECDSA.recover(digest, signature);
        if (signer != player && !(signer == sessionKey[player] && block.timestamp <= sessionExpiry[player])) revert BadSignature();
        nonces[player] = nonce + 1;
        Action storage a = _actions[player][nonce];
        a.commitHash = commitHash;
        a.commitTime = uint64(block.timestamp);
        a.commitPx = IContestPrices(prices).readAll();
        if (!joined[player]) {
            joined[player] = true;
            _players.push(player);
            emit Joined(player);
        }
        emit Committed(player, nonce, commitHash, uint64(block.timestamp), a.commitPx);
    }

    function commitHashOf(RevealInput calldata r) public view returns (bytes32) {
        // RevealInput has only static fields, so this equals abi.encode(address(this),
        // r.player, r.nonce, r.kind, ..., r.limitPx, r.salt) field by field.
        return keccak256(abi.encode(address(this), r));
    }

    /// @notice Anyone may reveal. Only plaintext matching the commit is accepted.
    function reveal(RevealInput[] calldata rs) external {
        if (block.timestamp < endTime || block.timestamp >= revealDeadline) revert WrongPhase();
        for (uint256 i; i < rs.length; ++i) {
            RevealInput calldata r = rs[i];
            Action storage a = _actions[r.player][r.nonce];
            if (a.commitTime == 0) revert UnknownCommit();
            if (a.revealed) revert AlreadyRevealed();
            if (commitHashOf(r) != a.commitHash) revert HashMismatch();
            a.revealed = true;
            a.kind = r.kind;
            a.coin = r.coin;
            a.isLong = r.isLong;
            a.leverage = r.leverage;
            a.orderType = r.orderType;
            a.posId = r.posId;
            a.margin = r.margin;
            a.stopPx = r.stopPx;
            a.tpPx = r.tpPx;
            a.limitPx = r.limitPx;
            emit Revealed(r.player, r.nonce);
        }
    }

    function players() external view returns (address[] memory) {
        return _players;
    }

    /// @notice Batch read for verifiers.
    function getActions(address player) external view returns (Action[] memory out) {
        uint256 n = nonces[player];
        out = new Action[](n);
        for (uint256 i; i < n; ++i) out[i] = _actions[player][i];
    }
}
