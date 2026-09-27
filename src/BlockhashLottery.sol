// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Permissionless DRAW lottery. Sepolia test toy with no value.
/// @dev Future blockhash randomness is validator-influenceable, not suitable for valuable prizes.
contract BlockhashLottery is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant TICKET_PRICE = 1_000 * 10 ** 18;
    uint256 public constant ROUND_BLOCKS = 300;
    uint256 public constant DRAW_DELAY = 5;
    uint256 public constant HASH_WINDOW = 256;
    uint256 public constant MAX_TICKETS_PER_BUY = 100;

    IERC20 public immutable token;
    uint256 public immutable deploymentBlock;

    enum State {
        Unsettled,
        Settled,
        Expired
    }

    struct Round {
        uint256 tickets;
        uint256 carryIn;
        State state;
        address winner;
        uint256 prize;
    }

    /// @dev A purchase owns [previous endIndex, endIndex), with zero-based ticket indices.
    struct Range {
        address buyer;
        uint256 endIndex;
    }

    mapping(uint256 => Round) private _rounds;
    mapping(uint256 => Range[]) private _ranges;
    mapping(uint256 => mapping(address => uint256)) public ticketsOf;
    mapping(uint256 => mapping(address => bool)) public refunded;
    mapping(address => uint256) public claimable;

    uint256 public totalClaimable;
    /// @notice Unsettled pots plus expired ticket payments not yet credited as refunds.
    uint256 public totalReserved;

    error InvalidToken();
    error InvalidTicketCount();
    error AlreadySettled();
    error TooEarly();
    error HashUnavailable();
    error NotExpired();
    error NothingToRefund();
    error AlreadyRefunded();
    error NothingToClaim();

    event Bought(uint256 indexed r, address indexed buyer, uint256 count, uint256 endIndex);
    event Settled(uint256 indexed r, address indexed winner, uint256 prize, uint256 carryOut);
    event Expired(uint256 indexed r);
    event Refunded(uint256 indexed r, address indexed buyer, uint256 amount);
    event Claimed(address indexed account, uint256 amount);
    event CarryForwarded(uint256 indexed fromRound, uint256 indexed toRound, uint256 amount);

    /// @param drawToken The factory-deployed LaunchToken, supplied as $token. No funding is needed.
    constructor(address drawToken) {
        if (drawToken.code.length == 0) revert InvalidToken();
        token = IERC20(drawToken);
        deploymentBlock = block.number;
    }

    function currentRound() public view returns (uint256) {
        return (block.number - deploymentBlock) / ROUND_BLOCKS;
    }

    function closeBlock(uint256 r) public view returns (uint256) {
        return deploymentBlock + ROUND_BLOCKS * r + ROUND_BLOCKS - 1;
    }

    function drawBlock(uint256 r) public view returns (uint256) {
        return closeBlock(r) + DRAW_DELAY;
    }

    /// @notice carryIn is the live carry balance; it becomes zero when the round is finalized.
    /// @dev State Unsettled includes both rounds still selling and closed rounds awaiting settlement.
    function roundInfo(uint256 r)
        external
        view
        returns (uint256 tickets, uint256 carryIn, State state, address winner, uint256 prize)
    {
        Round storage round = _rounds[r];
        return (round.tickets, round.carryIn, round.state, round.winner, round.prize);
    }

    function buy(uint256 count) external nonReentrant {
        if (count == 0 || count > MAX_TICKETS_PER_BUY) revert InvalidTicketCount();
        uint256 r = currentRound();
        Round storage round = _rounds[r];
        uint256 cost = count * TICKET_PRICE;
        round.tickets += count;
        ticketsOf[r][msg.sender] += count;
        _ranges[r].push(Range(msg.sender, round.tickets));
        totalReserved += cost;
        token.safeTransferFrom(msg.sender, address(this), cost);
        emit Bought(r, msg.sender, count, round.tickets);
    }

    /// @notice Anyone may finalize once the future draw block is strictly in the past.
    function settle(uint256 r) external nonReentrant {
        Round storage round = _rounds[r];
        if (round.state != State.Unsettled) revert AlreadySettled();
        uint256 draw = drawBlock(r);
        if (block.number <= draw) revert TooEarly();

        uint256 carry = round.carryIn;
        if (round.tickets == 0) {
            round.state = State.Settled;
            round.carryIn = 0;
            _forwardCarry(r, carry);
            emit Settled(r, address(0), 0, carry);
            return;
        }

        if (block.number > draw + HASH_WINDOW) {
            round.state = State.Expired;
            round.carryIn = 0;
            _forwardCarry(r, carry);
            emit Expired(r);
            return;
        }

        bytes32 hash = blockhash(draw);
        // A zero hash during the valid window must not select a predictable winner or expire early.
        if (hash == bytes32(0)) revert HashUnavailable();
        uint256 index = uint256(keccak256(abi.encode(hash, r))) % round.tickets;
        address winner = _winnerAt(r, index);
        uint256 pot = round.tickets * TICKET_PRICE + carry;
        uint256 prize = pot * 95 / 100;
        uint256 carryOut = pot - prize;

        round.state = State.Settled;
        round.carryIn = 0;
        round.winner = winner;
        round.prize = prize;
        totalReserved -= prize;
        totalClaimable += prize;
        claimable[winner] += prize;
        _forwardCarry(r, carryOut);
        emit Settled(r, winner, prize, carryOut);
    }

    /// @notice Credit all of the caller's original ticket payments for an expired round, once.
    function refund(uint256 r) external nonReentrant {
        if (_rounds[r].state != State.Expired) revert NotExpired();
        if (refunded[r][msg.sender]) revert AlreadyRefunded();
        uint256 amount = ticketsOf[r][msg.sender] * TICKET_PRICE;
        if (amount == 0) revert NothingToRefund();
        refunded[r][msg.sender] = true;
        totalReserved -= amount;
        totalClaimable += amount;
        claimable[msg.sender] += amount;
        emit Refunded(r, msg.sender, amount);
    }

    /// @notice Withdraw all winnings and refunds. A failed transfer leaves the credit intact.
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function _forwardCarry(uint256 fromRound, uint256 amount) private {
        if (amount == 0) return;
        // Settlement requires drawBlock(fromRound) < block.number, so the open round is later
        // and cannot already be finalized. Skipped rounds need no initialization or iteration.
        uint256 toRound = currentRound();
        _rounds[toRound].carryIn += amount;
        emit CarryForwarded(fromRound, toRound, amount);
    }

    function _winnerAt(uint256 r, uint256 index) private view returns (address) {
        Range[] storage ranges = _ranges[r];
        uint256 low = 0;
        uint256 high = ranges.length;
        while (low < high) {
            uint256 middle = low + (high - low) / 2;
            if (index < ranges[middle].endIndex) high = middle;
            else low = middle + 1;
        }
        return ranges[low].buyer;
    }
}
