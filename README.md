# Draw — lab-blockhash-lottery

**Sepolia test toy with no value.** DRAW and this future-blockhash lottery are for experimentation, not valuable wagers. This contribution delivers the contracts, Foundry tests, ABI exports, and the source-stage deployment handoff.

## Build and test

Requires Foundry and Solidity **0.8.26**. `foundry.toml` pins that compiler, Cancun EVM, optimizer runs 200, and `bytecode_hash = "none"`. All Solidity dependencies are ordinary files in `lib/`; no package installation, network, FFI, environment variables, or filesystem cheatcodes are needed by the tests. The verifier supplies the pinned compiler. Dependency versions, archive hashes, and licenses are in [lib/DEPENDENCIES.md](lib/DEPENDENCIES.md).

```sh
forge build
forge test
forge fmt --check
python3 scripts/export-abi.py --check
```

`python3 scripts/export-abi.py` regenerates the two JSON ABI arrays. The export tool uses Python's standard library and Foundry; it is not needed to build or run the Solidity tests.

## Contracts and deployment parameters

| Artifact | Constructor arguments | Behavior at deployment |
| --- | --- | --- |
| `src/LaunchToken.sol:LaunchToken` | None | Mints exactly 1,000,000,000 DRAW (`10^27` minor units), with 18 decimals, to its deployer. Name `Draw`, symbol `DRAW`. |
| `src/BlockhashLottery.sol:BlockhashLottery` | One nonzero deployed DRAW address: `["$token"]` | Stores `token` and `deploymentBlock` immutably. Starts empty. No transfers, approvals, initialization, or initial DRAW funding. |

Deployment target is **Sepolia, chain ID 11155111**, via the project factory, with LaunchToken before BlockhashLottery. The source is portable for local tests; it does not enforce a chain ID in its constructor. Services and the frontend must enforce Sepolia. Constructors are nonpayable, and the only application constructor type is `address`. The factory receives the entire launch supply. The lottery never treats `msg.sender` at deployment as an owner.

Both contracts have no owner, administration, pause, upgrade, mint-after-deployment, fee, blocklist, rescue, or privileged withdrawal function. DRAW is a plain ERC-20. There is no burn method or automatic lottery burn. Voluntary transfers to `0x000000000000000000000000000000000000dEaD` strand tokens there without changing ERC-20 `totalSupply`.

The manifest contribution must identify `LaunchToken` as the token and `BlockhashLottery` as the single application using `$token`. No `$owner` argument is needed. The separate manifest assignment writes `launch.json`; the independent reviewer inspects that manifest and this source together. Source publication, signed artifact linkage, policy selection, admission, factory execution, deployment addresses, and deployment receipts belong to services after this stage. Those live addresses are intentionally unresolved here, not hard-coded. The lottery needs no keepers, external oracle, or VRF subscription.

## Round lifecycle

Let `G = deploymentBlock`, with round numbers starting at zero. Round `r` sells in **[G + 300r, G + 300r + 299]**, inclusive. `closeBlock(r) = G + 300r + 299`, and `drawBlock(r) = closeBlock(r) + 5`. Windows are fixed by block height; they do not wait for previous rounds to settle. Unsettled includes rounds still selling and closed rounds awaiting finalization.

1. Acquire DRAW by swapping Sepolia ETH in the factory-seeded ETH/DRAW launch pool. The application has no swap or faucet.
2. Approve the lottery to spend DRAW, then call `buy(count)` with **1–100 tickets per call**, each costing **1,000 DRAW** (`10^21` minor units). Repeated purchases are allowed. `buy` chooses the round at transaction execution, so a transaction mined after the close enters the next round. Purchases form cumulative exclusive-end ranges; winner lookup is logarithmic in purchase count.
3. Anyone calls `settle(r)` strictly after the draw block. A nonempty round draws at `drawBlock + 1` through **`drawBlock + 256` inclusive**, provided the hash is nonzero. The zero-based winning index is `uint256(keccak256(abi.encode(blockhash(drawBlock), uint256(r)))) % tickets`. The encoding is exactly two 32-byte words.
4. The pot is `tickets * TICKET_PRICE + carryIn`. The winner receives credit for `floor(pot * 95 / 100)`. The entire remainder, including rounding dust, moves to the round open **at settlement time**. Settlement performs no external payment. Empty rounds finalize without a hash or winner and forward all carry. Every finalized round rejects a second settlement.
5. A zero hash during the valid window reverts `HashUnavailable`, preserving the round for retry. At **`drawBlock + 257`** and later, a nonempty unsettled round expires. Its carry moves to the open round; every buyer may call `refund(r)` once for **all** their tickets in that round at full purchase price. Refunds require an explicit successful expired settlement first.
6. `claim()` sends all the caller's accumulated winnings and refunds in DRAW. It clears credit before calling the token, uses SafeERC20 and a reentrancy guard, and restores the credit if the transfer fails. Refunds and claims have no deadline. A blocked recipient cannot stop settlement or another user's claim.

Carry is always sent to a later open round that cannot yet have been settled. Old rounds may settle in any order; a settlement cannot add money to an already finalized pot. `roundInfo(r).carryIn` reports live carry, so it becomes zero after finalization; historical carry movement is available through events. `ticketsOf` remains historical after a refund, with `refunded` recording whether the payment was credited. Empty-round `Settled` events use winner zero and prize zero.

## Funding and custody assumptions

The constructor validates that the token address has code, not that arbitrary code implements DRAW correctly. Deployment review must verify the immutable reference resolves to this LaunchToken. Exact accounting assumes its fixed, fee-free, non-rebasing ERC-20 behavior. Supporting arbitrary fee-on-transfer or dishonest tokens is outside the design.

For normal lottery operations, the tested conservation identity is:

```text
DRAW balance = totalClaimable + totalReserved
totalReserved = all unsettled ticket pots and carry
              + expired ticket payments not yet credited through refund()
```

Crediting a winner or refund moves the amount from reserved funds to claimable funds. Claiming reduces both the contract balance and claimable funds. Carry transfers change neither aggregate. The invariant suite independently reconstructs these liabilities from round state and buyers, including expired but unrefunded tickets.

Anyone can transfer ERC-20 tokens directly to any address. Unsolicited DRAW is surplus, creates no tickets or prize entitlement, and is permanently unrecoverable here. With such donations the correct identity adds that surplus, and the solvency inequality is `balance >= totalClaimable + totalReserved`. Strict equality cannot be guaranteed against arbitrary external donations. Carry is not refundable, including when a round has no buyers; anyone can keep forwarding it through later empty rounds until a round sells tickets.

All entry points are nonpayable, with no receive or fallback. Ordinary ETH transfers and value-bearing calls revert. EVM mechanisms can nevertheless force ETH to a contract; forced ETH and unrelated tokens cannot be recovered. No lottery accounting uses ETH.

## Randomness and operational responsibilities

A Sepolia validator could withhold a block to change the outcome at the cost of its block reward; the pot is a test toy. The hash is not cryptographically unbiasable randomness. Sales close five blocks before the draw block, so users cannot buy tickets in that round after seeing its hash. See the [Solidity blockhash documentation](https://docs.soliditylang.org/en/v0.8.26/units-and-global-variables.html#block-and-transaction-properties) for hash availability and influence limitations.

Once the hash is known, everyone can calculate the winner. A participant can decline to submit settlement after losing, although anyone else can settle. Delaying or censoring all settlement through the 256-block window forces refunds. Settlement timing also chooses which open round receives carry. There is no on-chain automation or promised timely settlement; users or other permissionless callers supply transactions and gas. Network reorganizations can change hashes, entries, or observed winners until finality. Tests inject hashes only to exercise local behavior, not to establish production randomness security.

The next independent adversarial review must assess window boundaries and zero hashes, range lookup endpoints, carry across settlement orders, duplicate refunds/settlements, and result prediction or steering. [docs/REVIEW_NOTES.md](docs/REVIEW_NOTES.md) records implementation-side evidence and remaining review responsibilities; it is not an independent audit.

After services deploy, the frontend assignment can use [docs/ABI.md](docs/ABI.md) and [docs/abi](docs/abi). Its one-page static export (`dist/index.html`, site label `lab-blockhash-lottery`) should enforce Sepolia, read DRAW from `token()`, show wallet DRAW balance and allowance, offer approval before ticket purchases, display the current round, pot, block countdowns, settle/refund/claim actions, and past winners. It must display **“Sepolia test toy with no value”** and explain that DRAW comes from an external ETH/DRAW pool swap, without an in-page swap. Discover history from views and chunked event queries beginning at `deploymentBlock`, with no backend or indexer. The live website follows deployment and is not part of this source assignment.
