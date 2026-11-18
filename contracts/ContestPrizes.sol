// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

interface IContestBook {
    function startTime() external view returns (uint64);
    function revealDeadline() external view returns (uint64);
}

/// @title ContestPrizes
/// @notice The contest's identity and its prize pool. Each contest is a minimal
///         clone made by CookedFactory, which moves the organizer's deposit in and
///         initializes it in the same transaction, so a contest without its full
///         prize pool cannot exist.
///         - The pool cannot leave before claimDeadline except through claims.
///         - The operator (owner) posts a Merkle root of prizes. Claims open only
///           after claimDelay, so anyone can recompute the result first. Each post
///           restarts the timer. The root cannot pay out more than the pool.
///         - After claimDeadline whatever is left (unclaimed prizes, unused shares)
///           goes back to the organizer. Anyone can trigger it.
///         - Leaf = keccak256(abi.encodePacked(contestId, index, account, amount)).
contract ContestPrizes {
    using SafeERC20 for IERC20;

    // Set once by initialize()
    address public owner; // platform operator: posts the result
    address public organizer; // deposited the pool, gets the remainder back
    address public book; // ContestBook
    IERC20 public prizeToken;
    uint256 public contestId;
    uint256 public prizePool;
    uint32 public claimDelay;
    uint64 public claimDeadline;
    bytes32 public rulesHash; // keccak256 of the public rules file
    bool public funded;
    bool private _initialized;

    bytes32 public resultRoot;
    uint256 public resultTotal;
    bytes32 public resultDataHash; // keccak256 of the published results file
    uint64 public resultPostedAt;
    uint256 public claimedTotal;
    mapping(uint256 => uint256) private _claimedBitmap;

    event Funded(address indexed organizer, uint256 amount);
    event ResultPosted(bytes32 root, uint256 total, bytes32 dataHash, uint64 claimsOpenAt);
    event Claimed(uint256 indexed index, address indexed account, uint256 amount);
    event Returned(address to, uint256 amount);

    error NotOwner();
    error BadConfig();
    error WrongPhase();
    error AlreadyClaimed();
    error BadProof();
    error OverPool();
    error AlreadyInitialized();
    error NotFunded();

    constructor() {
        _initialized = true; // the implementation itself can never be initialized
    }

    struct Init {
        address owner;
        address organizer;
        address book;
        address token;
        uint256 contestId;
        uint256 pool;
        uint32 claimDelay;
        uint64 claimDeadline;
        bytes32 rulesHash;
    }

    /// @notice Called by the factory after it has moved the pool into this contract.
    function initialize(Init calldata i) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        // pool 0: a community cup (ranking only); the factory lets only the operator make one
        if (i.book == address(0) || i.token == address(0) || i.owner == address(0) || i.organizer == address(0)) revert BadConfig();
        if (uint256(IContestBook(i.book).revealDeadline()) + i.claimDelay >= i.claimDeadline) revert BadConfig();
        if (IERC20(i.token).balanceOf(address(this)) < i.pool) revert NotFunded();
        owner = i.owner;
        organizer = i.organizer;
        book = i.book;
        prizeToken = IERC20(i.token);
        contestId = i.contestId;
        prizePool = i.pool;
        claimDelay = i.claimDelay;
        claimDeadline = i.claimDeadline;
        rulesHash = i.rulesHash;
        funded = true;
        emit Funded(i.organizer, i.pool);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function postResult(bytes32 root, uint256 total, bytes32 dataHash) external onlyOwner {
        if (block.timestamp < IContestBook(book).revealDeadline()) revert WrongPhase();
        if (resultPostedAt != 0 && block.timestamp >= uint256(resultPostedAt) + claimDelay) revert WrongPhase();
        if (total > prizePool) revert OverPool();
        uint64 openAt = uint64(block.timestamp) + claimDelay;
        if (openAt >= claimDeadline) revert WrongPhase();
        resultRoot = root;
        resultTotal = total;
        resultDataHash = dataHash;
        resultPostedAt = uint64(block.timestamp);
        emit ResultPosted(root, total, dataHash, openAt);
    }

    function claimsOpenAt() public view returns (uint256) {
        return resultPostedAt == 0 ? 0 : uint256(resultPostedAt) + claimDelay;
    }

    function isClaimed(uint256 index) public view returns (bool) {
        return _claimedBitmap[index >> 8] & (1 << (index & 0xff)) != 0;
    }

    /// @notice Anyone may trigger; tokens always go to `account`.
    function claim(uint256 index, address account, uint256 amount, bytes32[] calldata proof) external {
        if (resultPostedAt == 0 || block.timestamp < claimsOpenAt() || block.timestamp > claimDeadline) {
            revert WrongPhase();
        }
        if (isClaimed(index)) revert AlreadyClaimed();
        bytes32 leaf = keccak256(abi.encodePacked(contestId, index, account, amount));
        if (!MerkleProof.verifyCalldata(proof, resultRoot, leaf)) revert BadProof();
        if (claimedTotal + amount > resultTotal) revert OverPool();
        _claimedBitmap[index >> 8] |= (1 << (index & 0xff));
        claimedTotal += amount;
        prizeToken.safeTransfer(account, amount);
        emit Claimed(index, account, amount);
    }

    /// @notice After claimDeadline the remainder goes back to the organizer. Anyone may trigger.
    function returnRemainder() external {
        if (block.timestamp <= claimDeadline) revert WrongPhase();
        uint256 bal = prizeToken.balanceOf(address(this));
        if (bal > 0) prizeToken.safeTransfer(organizer, bal);
        emit Returned(organizer, bal);
    }
}
