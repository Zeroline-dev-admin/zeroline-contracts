// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface IFactory {
    function contestPrizes(uint256 id) external view returns (address);
}

interface IPrizes {
    function book() external view returns (address);
    function organizer() external view returns (address);
}

interface IBook {
    function startTime() external view returns (uint64);
    function endTime() external view returns (uint64);
}

/// @title CookedEntry
/// @notice Entry conditions for COOKED contests. One contract for the whole platform.
///
///   Passes (pass contests). A pass is a record that an address may play one contest.
///   It cannot be transferred or sold: there is no transfer function.
///   - From the organizer's list: the operator records the addresses written in the
///     contest's rules file (whose hash the organizer signed). Anyone can check every
///     recorded address against that list.
///   - From an entry code: the player signs the code, the operator relays it. Each code
///     works once. Only the code's hash is in the rules file, so anyone can check that
///     every redeemed code was one the organizer made.
///
///   Deposits (principal-protected contests). Each player deposits the same fixed amount
///   before the start. After the end every deposit goes back to its owner, in full:
///   anyone can trigger it, and nothing else can move a deposit. Interest is paid to
///   the organizer from outside (on testnet it is simulated: the operator pays it).
contract CookedEntry {
    using SafeERC20 for IERC20;

    address public immutable operator;
    IFactory public immutable factory;
    IERC20 public immutable token;

    uint8 public constant FROM_LIST = 1;
    uint8 public constant FROM_CODE = 2;

    // contest id => player => FROM_LIST or FROM_CODE (0: no pass)
    mapping(uint256 => mapping(address => uint8)) public passOf;
    // contest id => player => keccak256(code) for code passes
    mapping(uint256 => mapping(address => bytes32)) public codeOf;
    // contest id => keccak256(code) => player who used it
    mapping(uint256 => mapping(bytes32 => address)) public codeUsedBy;
    mapping(uint256 => uint256) public passCount;

    struct Pool {
        uint256 amount; // each player's deposit
        uint64 startTime;
        uint64 endTime;
        uint16 aprBps; // interest rate the organizer is paid on (simulated on testnet)
        address organizer;
        uint32 depositors;
        uint256 total; // deposits still held
        uint256 interestPaid;
    }

    mapping(uint256 => Pool) public pools;
    mapping(uint256 => mapping(address => uint256)) public deposited;
    mapping(uint256 => mapping(address => bool)) public hasDeposited;

    event PassFromList(uint256 indexed contestId, address indexed player);
    event PassFromCode(uint256 indexed contestId, address indexed player, bytes32 codeHash);
    event PoolOpened(uint256 indexed contestId, uint256 amount, uint16 aprBps, address organizer);
    event Deposited(uint256 indexed contestId, address indexed player, uint256 amount);
    event Returned(uint256 indexed contestId, address indexed player, uint256 amount);
    event InterestPaid(uint256 indexed contestId, address indexed organizer, uint256 amount);

    error NotOperator();
    error NoContest();
    error WrongPhase();
    error Already();
    error CodeUsed();
    error BadSignature();
    error BadConfig();
    error NoPool();

    constructor(address factory_, address token_) {
        operator = msg.sender;
        factory = IFactory(factory_);
        token = IERC20(token_);
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    function _times(uint256 id) internal view returns (uint64 start, uint64 end, address organizer) {
        address prizes = factory.contestPrizes(id);
        if (prizes == address(0)) revert NoContest();
        IBook book = IBook(IPrizes(prizes).book());
        return (book.startTime(), book.endTime(), IPrizes(prizes).organizer());
    }

    // ---- passes ---------------------------------------------------------------------

    /// @notice Records passes for addresses on the organizer's list (from the rules file).
    function grantPasses(uint256 id, address[] calldata players) external onlyOperator {
        (, uint64 end,) = _times(id);
        if (block.timestamp >= end) revert WrongPhase();
        for (uint256 i = 0; i < players.length; i++) {
            if (passOf[id][players[i]] != 0) continue;
            passOf[id][players[i]] = FROM_LIST;
            passCount[id]++;
            emit PassFromList(id, players[i]);
        }
    }

    /// @notice The message a player signs to use an entry code.
    function codeMessage(uint256 id, string calldata code) public pure returns (bytes32) {
        return keccak256(abi.encodePacked("COOKED pass", id, code));
    }

    /// @notice Uses an entry code for `player`, with the player's signature (EIP-191).
    function redeemCode(uint256 id, string calldata code, address player, bytes calldata sig) external onlyOperator {
        (, uint64 end,) = _times(id);
        if (block.timestamp >= end) revert WrongPhase();
        if (passOf[id][player] != 0) revert Already();
        bytes32 h = keccak256(bytes(code));
        if (codeUsedBy[id][h] != address(0)) revert CodeUsed();
        if (ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(codeMessage(id, code)), sig) != player) revert BadSignature();
        codeUsedBy[id][h] = player;
        codeOf[id][player] = h;
        passOf[id][player] = FROM_CODE;
        passCount[id]++;
        emit PassFromCode(id, player, h);
    }

    // ---- principal-protected deposits -------------------------------------------------

    /// @notice Opens the deposit pool of a contest, once. Amount and rate come from the
    ///         rules file; the times and the organizer come from the contest itself.
    function openPool(uint256 id, uint256 amount, uint16 aprBps) external onlyOperator {
        if (pools[id].amount != 0) revert Already();
        if (amount == 0 || aprBps > 2000) revert BadConfig();
        (uint64 start, uint64 end, address organizer) = _times(id);
        if (block.timestamp >= start) revert WrongPhase();
        pools[id] = Pool({amount: amount, startTime: start, endTime: end, aprBps: aprBps, organizer: organizer, depositors: 0, total: 0, interestPaid: 0});
        emit PoolOpened(id, amount, aprBps, organizer);
    }

    /// @notice The player deposits directly (after approving the token).
    function deposit(uint256 id) external {
        _deposit(id, msg.sender);
    }

    /// @notice Relayed by the operator: the player signed a permit for exactly the deposit.
    function depositWithPermit(uint256 id, address player, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external onlyOperator {
        try IERC20Permit(address(token)).permit(player, address(this), pools[id].amount, deadline, v, r, s) {} catch {}
        _deposit(id, player);
    }

    function _deposit(uint256 id, address player) internal {
        Pool storage p = pools[id];
        if (p.amount == 0) revert NoPool();
        if (block.timestamp >= p.startTime) revert WrongPhase();
        if (hasDeposited[id][player]) revert Already();
        hasDeposited[id][player] = true;
        deposited[id][player] = p.amount;
        p.depositors++;
        p.total += p.amount;
        token.safeTransferFrom(player, address(this), p.amount);
        emit Deposited(id, player, p.amount);
    }

    /// @notice After the end the deposit goes back to its owner. Anyone may trigger.
    function returnDeposit(uint256 id, address player) public {
        Pool storage p = pools[id];
        if (p.amount == 0) revert NoPool();
        if (block.timestamp < p.endTime) revert WrongPhase();
        uint256 a = deposited[id][player];
        if (a == 0) return;
        deposited[id][player] = 0;
        p.total -= a;
        token.safeTransfer(player, a);
        emit Returned(id, player, a);
    }

    function returnDeposits(uint256 id, address[] calldata players) external {
        for (uint256 i = 0; i < players.length; i++) returnDeposit(id, players[i]);
    }

    /// @notice Interest the organizer is due: deposits x rate x contest length.
    function interestDue(uint256 id) public view returns (uint256) {
        Pool storage p = pools[id];
        uint256 held = uint256(p.depositors) * p.amount;
        uint256 due = (held * p.aprBps * (p.endTime - p.startTime)) / (10000 * 365 days);
        return due > p.interestPaid ? due - p.interestPaid : 0;
    }

    /// @notice Pays the organizer's interest from the caller's tokens, after the end.
    ///         Never touches deposits.
    function payInterest(uint256 id) external {
        Pool storage p = pools[id];
        if (p.amount == 0) revert NoPool();
        if (block.timestamp < p.endTime) revert WrongPhase();
        uint256 due = interestDue(id);
        if (due == 0) return;
        p.interestPaid += due;
        token.safeTransferFrom(msg.sender, p.organizer, due);
        emit InterestPaid(id, p.organizer, due);
    }
}
