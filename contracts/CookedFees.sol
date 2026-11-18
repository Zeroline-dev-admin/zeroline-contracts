// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IFeeFactory {
    function contestPrizes(uint256 id) external view returns (address);
}

interface IFeePrizes {
    function book() external view returns (address);
    function organizer() external view returns (address);
    function prizePool() external view returns (uint256);
}

interface IFeeBook {
    function startTime() external view returns (uint64);
}

/// @title CookedFees
/// @notice Entry-fee contests (v0.21). One contract for the whole platform.
///
///   Each player pays the same fixed fee once, before the start. The platform keeps
///   rakeBps of it; the rest goes to the organizer. Before the contest was created the
///   organizer already locked the largest possible prize pool in ContestPrizes:
///       guarantee + (fee - rake) x maxPlayers
///   The prizes actually paid are guarantee + (fee - rake) x players who paid, so every
///   prize is covered by money that is already locked. What is not used goes back to the
///   organizer after the claim deadline (as with every contest).
///   Fees cannot be refunded or moved by anyone once paid; the split is fixed when the
///   fee pool opens and can be read here.
contract CookedFees {
    using SafeERC20 for IERC20;

    address public immutable operator;
    IFeeFactory public immutable factory;
    IERC20 public immutable token;
    address public immutable treasury;

    uint16 public constant MAX_RAKE_BPS = 3000;

    struct Pool {
        uint256 fee; // what each player pays
        uint16 rakeBps; // platform share of each fee
        uint32 maxPlayers;
        uint32 players; // players who paid
        uint64 startTime; // payments close here
        address organizer;
        uint256 toOrganizer; // total sent to the organizer
        uint256 toTreasury; // total kept by the platform
    }

    mapping(uint256 => Pool) public pools;
    mapping(uint256 => mapping(address => bool)) public paid;

    event FeePoolOpened(uint256 indexed contestId, uint256 fee, uint16 rakeBps, uint32 maxPlayers, address organizer);
    event FeePaid(uint256 indexed contestId, address indexed player, uint256 fee, uint256 rake);

    error NotOperator();
    error NoContest();
    error WrongPhase();
    error Already();
    error BadConfig();
    error NoPool();
    error Full();

    constructor(address factory_, address token_, address treasury_) {
        if (factory_ == address(0) || token_ == address(0) || treasury_ == address(0)) revert BadConfig();
        operator = msg.sender;
        factory = IFeeFactory(factory_);
        token = IERC20(token_);
        treasury = treasury_;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    /// @notice Opens the fee pool of a contest, once, before the start. Fee, rake and the
    ///         player cap come from the rules file; the start and the organizer come from
    ///         the contest itself.
    function openPool(uint256 id, uint256 fee, uint16 rakeBps, uint32 maxPlayers) external onlyOperator {
        if (pools[id].fee != 0) revert Already();
        if (fee == 0 || rakeBps > MAX_RAKE_BPS || maxPlayers == 0) revert BadConfig();
        address prizes = factory.contestPrizes(id);
        if (prizes == address(0)) revert NoContest();
        uint64 start = IFeeBook(IFeePrizes(prizes).book()).startTime();
        if (block.timestamp >= start) revert WrongPhase();
        pools[id] = Pool({fee: fee, rakeBps: rakeBps, maxPlayers: maxPlayers, players: 0, startTime: start, organizer: IFeePrizes(prizes).organizer(), toOrganizer: 0, toTreasury: 0});
        emit FeePoolOpened(id, fee, rakeBps, maxPlayers, pools[id].organizer);
    }

    /// @notice The player pays directly (after approving the token).
    function pay(uint256 id) external {
        _pay(id, msg.sender);
    }

    /// @notice Relayed by the operator: the player signed a permit for exactly the fee.
    function payWithPermit(uint256 id, address player, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external onlyOperator {
        try IERC20Permit(address(token)).permit(player, address(this), pools[id].fee, deadline, v, r, s) {} catch {}
        _pay(id, player);
    }

    function _pay(uint256 id, address player) internal {
        Pool storage p = pools[id];
        if (p.fee == 0) revert NoPool();
        if (block.timestamp >= p.startTime) revert WrongPhase();
        if (paid[id][player]) revert Already();
        if (p.players >= p.maxPlayers) revert Full();
        paid[id][player] = true;
        p.players++;
        uint256 rake = (p.fee * p.rakeBps) / 10000;
        p.toTreasury += rake;
        p.toOrganizer += p.fee - rake;
        if (rake > 0) token.safeTransferFrom(player, treasury, rake);
        token.safeTransferFrom(player, p.organizer, p.fee - rake);
        emit FeePaid(id, player, p.fee, rake);
    }
}
