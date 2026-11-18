// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ContestPrices} from "./ContestPrices.sol";
import {ContestBook} from "./ContestBook.sol";
import {ContestPrizes} from "./ContestPrizes.sol";

/// @title CookedFactory
/// @notice Anyone can host a contest (or, with hostsOnly, the operator and the hosts it approved). One transaction makes the three contest
///         contracts (minimal clones), moves the organizer's full prize pool into
///         the prize contract and initializes everything. No deposit, no contest.
///         The organizer either calls createContest directly, or signs the exact
///         configuration (and a token permit) and lets the operator relay it, so
///         the organizer needs no gas. The operator posts results; the organizer
///         gets back whatever is left after the claim deadline.
contract CookedFactory is EIP712 {
    using SafeERC20 for IERC20;

    address public immutable pricesImpl;
    address public immutable bookImpl;
    address public immutable prizesImpl;
    address public immutable oracle;
    address public immutable operator;
    mapping(address => bool) public allowedToken;
    /// @notice true on mainnet: only the operator and hosts it approved can host a contest
    bool public immutable hostsOnly;
    mapping(address => bool) public isHost;

    uint256 public contestCount;
    mapping(uint256 => address) public contestPrizes; // id => ContestPrizes
    mapping(address => uint256) public organizerNonce;

    uint256 public constant MAX_COINS = 10;
    uint64 public constant MAX_LENGTH = 30 days;

    bytes32 public constant CREATE_TYPEHASH =
        keccak256("CreateContest(address organizer,bytes32 configHash,uint256 nonce,uint64 deadline)");

    struct Config {
        uint64 startTime;
        uint64 endTime;
        uint64 revealDeadline;
        uint64 claimDeadline;
        uint32 interval;
        uint32 claimDelay;
        uint32 maxActions;
        uint32[] coins; // HyperCore perp asset indices
        address token;
        uint256 prizePool;
        bytes32 rulesHash; // keccak256 of the public rules file (leverage, payout, ...)
    }

    struct Permit {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    event ContestCreated(
        uint256 indexed id, address indexed organizer, address prizes, address book, address prices,
        address token, uint256 prizePool, bytes32 rulesHash
    );
    event TokenAllowed(address token, bool allowed);
    event HostSet(address host, bool allowed);

    error NotOperator();
    error BadConfig();
    error BadSignature();
    error Expired();
    error NotHost();

    /// @param firstId_ id of the first contest made here (0 or 1 = start at 1). A factory that replaces
    ///        an older one continues its numbering, so a contest id stays unique on the site.
    constructor(address pricesImpl_, address bookImpl_, address prizesImpl_, address oracle_, address token_, bool hostsOnly_, uint256 firstId_)
        EIP712("CookedFactory", "1")
    {
        if (firstId_ > 1) contestCount = firstId_ - 1;
        hostsOnly = hostsOnly_;
        pricesImpl = pricesImpl_;
        bookImpl = bookImpl_;
        prizesImpl = prizesImpl_;
        oracle = oracle_;
        operator = msg.sender;
        allowedToken[token_] = true;
        emit TokenAllowed(token_, true);
    }

    function setToken(address token, bool allowed) external {
        if (msg.sender != operator) revert NotOperator();
        allowedToken[token] = allowed;
        emit TokenAllowed(token, allowed);
    }

    function setHost(address host, bool allowed) external {
        if (msg.sender != operator) revert NotOperator();
        isHost[host] = allowed;
        emit HostSet(host, allowed);
    }

    function configHash(Config calldata c) public pure returns (bytes32) {
        return keccak256(abi.encode(c.startTime, c.endTime, c.revealDeadline, c.claimDeadline, c.interval, c.claimDelay, c.maxActions, keccak256(abi.encodePacked(c.coins)), c.token, c.prizePool, c.rulesHash));
    }

    /// @notice The organizer calls this directly (after approving the token).
    function createContest(Config calldata c) external returns (uint256) {
        return _create(c, msg.sender);
    }

    /// @notice Relayed: the organizer signed the configuration and a permit; anyone may submit.
    function createContestFor(Config calldata c, address organizer, uint64 sigDeadline, bytes calldata sig, Permit calldata p)
        external
        returns (uint256)
    {
        if (block.timestamp > sigDeadline) revert Expired();
        uint256 nonce = organizerNonce[organizer]++;
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(CREATE_TYPEHASH, organizer, configHash(c), nonce, sigDeadline)));
        if (ECDSA.recover(digest, sig) != organizer) revert BadSignature();
        if (p.deadline != 0) {
            // a permit that was already used (or front-run) is fine as long as the allowance is there
            try IERC20Permit(c.token).permit(organizer, address(this), p.value, p.deadline, p.v, p.r, p.s) {} catch {}
        }
        return _create(c, organizer);
    }

    function _create(Config calldata c, address organizer) internal returns (uint256 id) {
        if (hostsOnly && organizer != operator && !isHost[organizer]) revert NotHost();
        // a cup without a prize (a community cup: ranking only) is hosted by the operator alone
        if (!allowedToken[c.token] || (c.prizePool == 0 && organizer != operator)) revert BadConfig();
        if (c.startTime < block.timestamp || c.endTime <= c.startTime || c.endTime - c.startTime > MAX_LENGTH) revert BadConfig();
        if (c.coins.length == 0 || c.coins.length > MAX_COINS || c.interval < 10) revert BadConfig();
        id = ++contestCount;
        address prices = Clones.clone(pricesImpl);
        address book = Clones.clone(bookImpl);
        address prizes = Clones.clone(prizesImpl);
        ContestPrices(prices).initialize(oracle, c.startTime, c.endTime, c.interval, c.coins);
        ContestBook(book).initialize(prices, c.startTime, c.endTime, c.revealDeadline, c.maxActions);
        // the full pool moves from the organizer into the prize contract, or nothing happens
        if (c.prizePool > 0) IERC20(c.token).safeTransferFrom(organizer, prizes, c.prizePool);
        ContestPrizes(prizes).initialize(ContestPrizes.Init({
            owner: operator, organizer: organizer, book: book, token: c.token, contestId: id,
            pool: c.prizePool, claimDelay: c.claimDelay, claimDeadline: c.claimDeadline, rulesHash: c.rulesHash
        }));
        contestPrizes[id] = prizes;
        emit ContestCreated(id, organizer, prizes, book, prices, c.token, c.prizePool, c.rulesHash);
    }
}
