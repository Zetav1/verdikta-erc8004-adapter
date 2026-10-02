# DESIGN — ERC-8004 Validation Registry <-> Verdikta Adapter

**Spec cited:** ERC-8004 *Trustless Agents* (Draft, created 2025-08-13), ethereum/ERCs
`ERCS/erc-8004.md` at commit `503591a6e80e6e1affdd6403341e25269141f046` (2026-01-25),
which is `master` HEAD for that file at the time of writing.
Discussion: https://ethereum-magicians.org/t/erc-8004-trustless-agents/25098

**This work was sponsored by a Verdikta bounty.**

## Flow mapping

| ERC-8004 Validation Registry | Adapter | Verdikta evaluator |
|---|---|---|
| Owner/operator calls `validationRequest(validatorAddress=adapter, agentId, requestURI, requestHash)` | adapter chosen as `validatorAddress`; relayer observes the event | — |
| (no on-chain callback exists) | relayer calls `openRound(agentId, requestHash, cids, addendum)` payable | `requestAIEvaluationWithApproval{value: ...}` returns `aggRequestId` |
| — | state `Requested`, maps `requestHash <-> aggRequestId` | arbiters commit then reveal; aggregator clusters |
| — | `settle(requestHash)` (permissionless) reads `getEvaluation(aggRequestId)` | stores aggregate + justification CID |
| — | maps likelihood vector -> `uint8` in `[0,100]`, state `Fulfilled` | — |
| adapter calls `validationResponse(requestHash, response, responseURI, responseHash, tag)` | state `Responded` | — |
| validator never responds within the policy window | `resolveFailure(requestHash, true)` -> `response=0`, `tag="timeout"` | round may still be open or already dead |
| evaluator round ended in failure | `resolveFailure(requestHash, false)` -> `response=0`, `tag="failed"` | `getAggregationStatus` reports `isComplete && failed` |

Key structural point: the evaluator **stores** the result and exposes a getter. There is no
push callback, and ERC-8004 has no callback either. Both layers are pull-based, which is why
the adapter has three separate transactions instead of one.

## States

```
None --> Requested --> Fulfilled --> Responded
            |
            +--> TimedOut --> Responded   (resolveFailure(_, true),  tag="timeout")
            +--> Failed   --> Responded   (resolveFailure(_, false), tag="failed")
```

No `Pending` state: dispatch happens inside the transaction that accepts the job, so an
intermediate state could never be observed externally.

## Score mapping

`aggregatedLikelihoods[j]` in the evaluator is the **arithmetic mean over clustered reveals**,
documented on a **0-100** scale. Therefore: do not sum the vector, and do not rescale.
The reference takes the max element and saturates at 100 (the evaluator's own clamp is `1e34`,
far outside `uint8`, so a raw cast would wrap).

Which element means "passed" is outcome-schema dependent — a design decision, flagged in the
writeup, not a solved problem.

## Trust assumptions (summary)

- The requesting agent owner trusts the adapter address they nominate as `validatorAddress`.
- Round surplus is a pull: the evaluator credits `ethOwed[adapter]`; it is not transferred until
  `claimAggregatorCredit(aggregator)` runs. The address must be one this adapter was configured with.
- The adapter trusts its configured evaluator deployment and oracle class. ERC-8004 leaves
  incentives and slashing to the validation protocol, so this trust sits in Verdikta's
  economics and reputation system, not in the registry.
- `requestURI` / evidence CIDs must stay resolvable. A hash binds integrity, not liveness.
- The likelihood->percent rule is a deployer heuristic. Read `tag` and `responseURI` for
  high-stakes decisions.
- No zkML and no TEE attestation is claimed.

Everything Verdikta-specific (class, alpha, fee ceiling, timeout, mapping) is a **design
proposal** relative to the ERC.
