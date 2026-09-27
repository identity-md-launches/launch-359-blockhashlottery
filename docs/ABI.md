# Contract ABI and integration

Canonical JSON ABI arrays are [LaunchToken.json](abi/LaunchToken.json) and [BlockhashLottery.json](abi/BlockhashLottery.json). Regenerate with `python3 scripts/export-abi.py`; verify with its `--check` flag. Amounts use 18-decimal DRAW minor units. Round IDs, block heights, counts, and amounts are `uint256`; state is encoded as `uint8`.

## LaunchToken

Nonpayable constructor with no arguments. Standard ERC-20 interface: `name()`, `symbol()`, `decimals()`, `totalSupply()`, `balanceOf(address)`, `allowance(address,address)`, `approve(address,uint256)`, `transfer(address,uint256)`, and `transferFrom(address,address,uint256)`. Transfers have no fee and return `true` on success; failures revert with ERC-6093 errors. Standard `Transfer` and `Approval` events. No additional privileged method.

## BlockhashLottery

Nonpayable `constructor(address drawToken)`. No initializer. Every transaction below is nonpayable and permissionless; actions affecting a user's money always use the transaction caller.

| Transaction | Effect |
| --- | --- |
| `buy(uint256 count)` | Pulls `count * TICKET_PRICE` from caller after ERC-20 approval and issues 1–100 tickets in the current round. |
| `settle(uint256 r)` | Finalizes a closed round after its draw block; credits a prize, expires it, or forwards an empty round's carry. |
| `refund(uint256 r)` | Once per caller per expired round, credits all their original ticket payments. Does not transfer yet. |
| `claim()` | Transfers all the caller's claimable DRAW to the caller. |

| View | Result |
| --- | --- |
| `token()` | Immutable DRAW address. |
| `deploymentBlock()` | Anchor block `G`; also the first block to query for events. |
| `currentRound()` | `(block.number - G) / 300`. |
| `closeBlock(uint256 r)` | Last sales block, inclusive. |
| `drawBlock(uint256 r)` | Close block plus five. Earliest settlement is the next block. |
| `roundInfo(uint256 r)` | Tuple `(uint256 tickets, uint256 carryIn, uint8 state, address winner, uint256 prize)`. State 0 = Unsettled, 1 = Settled, 2 = Expired. Missing/future rounds return zero fields. |
| `ticketsOf(uint256 r,address buyer)` | Historical total tickets bought, unchanged by refunds. |
| `refunded(uint256 r,address buyer)` | Whether that buyer has credited an expired round's refund. |
| `claimable(address account)` | Total outstanding winnings and refund credits. |
| `totalClaimable()` | Sum of all user credits. |
| `totalReserved()` | Unsettled pots/carry plus expired tickets still awaiting refund credit. |
| Constant getters | `TICKET_PRICE() = 10^21`, `ROUND_BLOCKS() = 300`, `DRAW_DELAY() = 5`, `HASH_WINDOW() = 256`, `MAX_TICKETS_PER_BUY() = 100`. |

For an unsettled round, the pot is `tickets * TICKET_PRICE + carryIn`. After finalization, `prize` is historical and `carryIn` is zero; the original ticket count should not be presented as a current pot. Finalized empty rounds have zero winner and zero prize. Filter those out of a winners list.

## Events

| Signature | Indexed fields | Meaning |
| --- | --- | --- |
| `Bought(uint256 r,address buyer,uint256 count,uint256 endIndex)` | `r`, `buyer` | This purchase owns zero-based indices `[endIndex - count, endIndex)`. |
| `Settled(uint256 r,address winner,uint256 prize,uint256 carryOut)` | `r`, `winner` | Successful draw or empty-round finalization. Credit is not a transfer. |
| `Expired(uint256 r)` | `r` | Buyers may now credit their refunds. |
| `Refunded(uint256 r,address buyer,uint256 amount)` | `r`, `buyer` | Refund credited for later claim. |
| `Claimed(address account,uint256 amount)` | `account` | All accumulated credit was paid successfully. |
| `CarryForwarded(uint256 fromRound,uint256 toRound,uint256 amount)` | `fromRound`, `toRound` | Nonzero carry assigned to the open round, emitted before `Settled` or `Expired`. |

Chunk log queries from `deploymentBlock()` to the confirmed head and deduplicate by transaction hash and log index. Re-query reorg-sensitive blocks. Use views for current balances, allowance, credits, and refund eligibility. No account list or round list needs to be stored by a backend.

## Errors and caller flow

Application errors have no arguments: `InvalidToken`, `InvalidTicketCount`, `AlreadySettled`, `TooEarly`, `HashUnavailable`, `NotExpired`, `NothingToRefund`, `AlreadyRefunded`, and `NothingToClaim`. The exported ABI also includes the OpenZeppelin SafeERC20, Address, and ReentrancyGuard errors reachable from the application. Token transfer failures may bubble ERC-20 errors from the token ABI.

Before buying, read the token address, wallet balance, and allowance; offer an approval for the total ticket cost and wait for it to confirm before sending `buy`. A purchase mined in the next round goes into that round, even if the page displayed the previous one. Read `Bought.r` from the receipt to show the actual round.

Settlement eligibility is `block.number > drawBlock(r)` and state 0. Inside the valid hash window, `HashUnavailable` means retry later; it never triggers an early refund. Beyond the window, call `settle` to mark expiry, then `refund` as the buyer, then `claim`. Credit may combine several rounds. A zero claim or repeat refund reverts without changing funds.
