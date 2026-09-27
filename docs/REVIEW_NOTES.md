# Implementation review handoff

This is an implementation-side analysis, not an independent security review. The assigned independent reviewer must inspect the accepted source and the separately generated `launch.json` before release. No mainnet or valuable-wager suitability is claimed.

## Evidence delivered

| Attack surface | Evidence in tests |
| --- | --- |
| Factory assumptions | A factory harness deploys both contracts, retains all `10^27` token units, and gives the unfunded application only the token address. Both runtime artifacts are scanned at opcode boundaries for DELEGATECALL, CALLCODE, SELFDESTRUCT, and EIP-170 size. |
| Blockhash window | Draws at offsets +1 and +256, expiry at +257; rejection at the draw block and earlier. Zero-hash reverts preserve the round, allow retry, and cannot enable early refunds. |
| Range endpoints | Every index in four interleaved buyer ranges, including repeated buyers; fuzzed counts and a nonzero round ID; a 257-purchase round. |
| Carry and rounding | Empty rounds forward carry even after skipped windows; prize includes carry; twenty consecutive draws test rounding dust; both orders of older expiry and newer draw preserve liabilities. |
| Duplicate actions | Settled, expired, and empty rounds cannot settle twice; expired refunds credit all purchases exactly once; repeated claims cannot pay again. |
| Payment faults | Missing balance/allowance, false-return and reverting token calls roll back state. Empty-return tokens exercise SafeERC20. A blocked winner does not stop settlement or another buyer's refund and claim. |
| Reentrancy | Malicious token callbacks during buy attempt every mutating entry point; a callback during claim sees zero credit and cannot reenter. DRAW itself has no transfer callbacks. |
| Custody conservation | Stateful randomized buys, block advances, settlements, refunds, and claims independently reconstruct round/user liabilities. Every campaign then expires outstanding rounds and withdraws all available credits; only carry remains. |
| Late entry | Once a round's hash is known, a new purchase affects only the current round and cannot change the old winner. |

## Deliberate assumptions and limitations to assess independently

- The factory must pass this fee-free LaunchToken. The constructor's code check does not certify arbitrary ERC-20 behavior, and fee/rebase tokens would violate accounting assumptions.
- Validator influence and block withholding can bias blockhash randomness. Settlement censorship or lack of callers can turn a known result into refunds. Any caller may settle, but there is no liveness service or reward. The independent reviewer should test feasible result-steering and the frontend's disclosure, not treat local hash injection as production randomness validation.
- Carry targets the open round at execution, so settlement delay changes the beneficiary round. It never enters a finalized round. Carry stays reserved indefinitely if no future ticket buyer appears.
- For a zero hash within the available window, the selected behavior is a retryable revert until the +257 expiry path. Empty rounds need no hash and finalize as Settled even after the hash window.
- Direct token donations add inaccessible surplus; strict balance equality holds for authorized lottery operations, and solvency holds with donations. Forced ETH is also inaccessible. There is intentionally no rescue authority.
- All sums are bounded by the fixed DRAW supply under normal operations. Round calculations use checked arithmetic, so nonsensical round IDs that overflow revert. Winner lookup is logarithmic and no state-changing application function enumerates all buyers or rounds.
- There is no deployment or signing script and no privileged parameter. Services resolve policy, addresses, source attestations, artifact linkage, factory deployment, and publication. The manifest review still needs to verify the selected source artifacts and `$token` wiring; policy and signed linkage are service responsibilities.

The source-stage test suite requires no external network, wallet, shared environment state, FFI, or filesystem permissions. Network consensus, actual validator economics, factory policy integration, and live frontend behavior remain outside its evidence.
