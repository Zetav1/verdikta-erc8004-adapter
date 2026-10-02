# Verdikta as an ERC-8004 Validator (Reference Adapter)

Reference design and minimal Solidity adapter showing how a Verdikta asynchronous AI
evaluation dispatch can serve as the `validatorAddress` of an
[ERC-8004](https://github.com/ethereum/ERCs/blob/master/ERCS/erc-8004.md) Validation Registry.

**This work was sponsored by a Verdikta bounty.**

> Not audited. Not deployed. Reference source for the ERC-8004 discussion.

## Spec citation

| Item | Value |
|---|---|
| ERC | 8004 Trustless Agents (Draft) |
| Created | 2025-08-13 |
| Commit | [`503591a6e80e6e1affdd6403341e25269141f046`](https://github.com/ethereum/ERCs/commit/503591a6e80e6e1affdd6403341e25269141f046) (2026-01-25, `master` HEAD at time of writing) |
| Review-move PR | [ethereum/ERCs#1244](https://github.com/ethereum/ERCs/pull/1244) |
| Discussion | https://ethereum-magicians.org/t/erc-8004-trustless-agents/25098 |

## Files

| File | Purpose |
|---|---|
| `VerdiktaValidationAdapter.sol` | Reference adapter (self-contained interfaces) |
| `writeup.md` | Full design writeup (async latency, failure paths, trust) |
| `DESIGN.md` | Short state/flow map |
| `forum-post.md` | Ethereum Magicians post text |
| `build.sh` | Fetches solc and compiles the adapter |

## Lifecycle

```
validationRequest(validatorAddress=adapter, agentId, requestURI, requestHash)   [ERC-8004]
        |
        |  relayer observes ValidationRequest (no on-chain callback exists)
        v
openRound(agentId, requestHash, cids, addendum)  --payable-->  evaluator.requestAIEvaluationWithApproval(...)
        |                                                        returns aggRequestId
        v
   (async: arbiters commit, reveal, cluster)
        v
settle(requestHash)   [permissionless]  ->  getEvaluation(aggRequestId)
        |                                        map likelihoods -> uint8 [0,100]
        v
submitValidationResponse(requestHash)  ->  validationRegistry.validationResponse(...)

Failure paths:
  resolveFailure(requestHash, true)   -> response=0, tag="timeout"   (policy deadline passed)
  resolveFailure(requestHash, false)  -> response=0, tag="failed"    (evaluator round failed)
```

## Build

```bash
bash build.sh
```

That downloads solc 0.8.37 and compiles the adapter, printing `compile OK` on success.
Verified: compiles clean with `--optimize --via-ir`, no errors and no warnings.

Requirements:
- `pragma solidity ^0.8.23`
- No external dependencies; `SimpleOwnable` and `ReentrancyGuardLite` are inlined
- Constructor: `owner`, `validationRegistry`, `verdiktaAggregator`, `requestedClass`, `timeoutSeconds`
- Owner must call `setPolicy` (alpha, fee ceiling, class, timeout) before use; `maxOracleFee`
  is intentionally left at 0 so a misconfigured adapter fails loudly rather than silently
- `openRound` must be funded with at least `requiredRoundFunding()`; the evaluator refunds
  the unused remainder to the adapter, recoverable via `withdrawEth`

## Interface provenance

The evaluator interface in the adapter was read from the published `verdikta/verdikta-dispatcher`
repository, not inferred from documentation prose:

- `reputationBasedAggregator/contracts/ReputationAggregator.sol` (pragma `^0.8.23`)
  - `requestAIEvaluationWithApproval(...)` is `public payable` and returns `bytes32 aggRequestId`
  - `getEvaluation(aggId) -> (uint256[] likelihoods, string cid, bool exists)`
  - `getAggregationStatus(aggId) -> (bool isComplete, bool failed, ...)`
  - `maxTotalFee(maxFee) = effMaxFee * (K + B*P)`
- `reputationBasedSingleton/contracts/ReputationSingleton.sol` (pragma `^0.8.21`)
  - emits `EvaluationFulfilled(requestId, ...)`; 2x fee model; **not** ETH-funded

This adapter targets the **aggregator**. The singleton would need a different funding path.

## What is a design proposal

`timeoutSeconds`, the auto `tag="timeout"`, writing `0` for a non-result, relayer-driven
progression, the likelihood->percent rule, and the class/alpha/fee defaults are all **design
proposals** — adapter policy, not ERC-8004 requirements and not existing Verdikta features.
See `writeup.md` for the full table.

## Trust

Naming this adapter as `validatorAddress` means trusting its admin keys, its configured
evaluator deployment, its oracle class, and its score mapping. Do not advertise zkML or TEE
trust unless a specific oracle class actually provides those proofs.

## License

MIT (see SPDX in the Solidity file).
