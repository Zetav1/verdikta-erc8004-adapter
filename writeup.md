# Verdikta as an ERC-8004 Validator: Reference Adapter Design

**This work was sponsored by a Verdikta bounty.**

## Abstract

ERC-8004 (*Trustless Agents*) defines three lightweight on-chain registries — Identity, Reputation, Validation — so agents can be discovered and trusted across organizational boundaries without pre-existing relationships. The Validation Registry lets an agent's owner or operator request verification of work, and lets a designated `validatorAddress` publish a scored response (0–100) that other contracts can read.

This writeup proposes a **reference adapter** implementing the ERC-8004 validator role on top of Verdikta's asynchronous AI evaluation dispatch. Verdikta runs multi-model arbitration over IPFS-referenced evidence and settles a scored result on-chain from commit-reveal consensus — the shape the Validation Registry was designed to hook into, with one structural consequence the adapter must absorb: the oracle result arrives in a *later* transaction, and may never arrive at all.

The proposal concentrates on the three points where naive integration breaks: **asynchronous oracle latency**, **timeout and no-result failure paths**, and **the trust a user inherits by naming this adapter as their validator**. Verdikta-specific parameters (oracle class, reputation weight, fee ceiling, timeout) are labelled throughout as **design proposals** — adapter policy, not ERC-8004 requirements and not existing Verdikta features. No deployment, address, transaction hash, audit, or endorsement is claimed.

This work was sponsored by a Verdikta bounty. The disclosure appears here in the document body, and again in the accompanying forum post, because the ERC-8004 discussion is an independent standards venue whose readers should know the provenance of a design arguing for one vendor's mechanism.

## Spec version cited

All ERC-8004 claims below come from the published draft:

| Field | Value |
|---|---|
| Title | ERC-8004: Trustless Agents |
| Status | Draft (Standards Track, ERC) |
| Created | 2025-08-13 |
| Authors | Marco De Rossi, Davide Crapis, Jordan Ellis, Erik Reppel |
| Commit cited | [`503591a6e80e6e1affdd6403341e25269141f046`](https://github.com/ethereum/ERCs/commit/503591a6e80e6e1affdd6403341e25269141f046) — "Updates from community feedback", 2026-01-25 |
| Spec path | https://github.com/ethereum/ERCs/blob/master/ERCS/erc-8004.md |
| Review-move PR | [ethereum/ERCs#1244](https://github.com/ethereum/ERCs/pull/1244) — merged 2025-10-08 |
| Original ERC PR | [ethereum/ERCs#1170](https://github.com/ethereum/ERCs/pull/1170) — merged 2025-08-18 |
| Discussion | [ethereum-magicians.org/t/erc-8004-trustless-agents/25098](https://ethereum-magicians.org/t/erc-8004-trustless-agents/25098) |

The cited commit `503591a6` is the tip of `master` for `erc-8004.md` at the time of writing, so the interface below is the current draft. Readers should re-pin before integrating.

## The ERC-8004 Validation Registry surface

Quoted from the cited draft, because the design is constrained by it.

**Request** — MUST be called by the owner or operator of `agentId`:

`validationRequest(address validatorAddress, uint256 agentId, string requestURI, bytes32 requestHash) external`

`requestURI` points to off-chain data holding everything the validator needs, including inputs and outputs. `requestHash` is the `keccak256` commitment to that payload and identifies the request.

**Response** — MUST be called by the `validatorAddress` named in the original request:

`validationResponse(bytes32 requestHash, uint8 response, string responseURI, bytes32 responseHash, string tag) external`

Only `requestHash` and `response` are mandatory. `response` is a value between 0 and 100, usable as a binary (0 failed, 100 passed) or with intermediate values for outcomes with a spectrum. Critically for this design, **`validationResponse()` may be called multiple times for the same `requestHash`**, enabling progressive states such as "soft finality" and "hard finality" distinguished via `tag`.

**Reads** — `getValidationStatus(requestHash)`, `getSummary(agentId, validatorAddresses, tag)`, `getAgentValidations(agentId)`, `getValidatorRequests(validatorAddress)`.

Two statements from the draft shape everything that follows. *"Incentives and slashing related to validation are managed by the specific validation protocol and are outside the scope of this registry."* And the Security Considerations note that the ERC cannot cryptographically guarantee advertised capabilities are functional or non-malicious. The registry is deliberately an **evidence layer**; the validator is where the epistemic work happens.

## The Verdikta evaluation pattern

Verdikta runs arbiter nodes combining a Chainlink request/response rail with an off-chain AI panel. Evidence is referenced by IPFS CIDs; a request is funded in ETH and dispatched to arbiters, who commit to a hash of their scores then reveal; the aggregator clusters the reveals and stores an aggregate. Names and shapes below were read from the `verdikta/verdikta-dispatcher` repository, not inferred from prose. The relevant contract is `ReputationAggregator` (multi-oracle commit-reveal, ETH-funded):

The four calls this adapter depends on are `requestAIEvaluationWithApproval`, `getEvaluation`,
`getAggregationStatus` and `maxTotalFee`. Their exact signatures are in the adapter's interface
declaration, and are quoted verbatim from the source rather than restated here.

Four properties of that surface are design constraints, not implementation details:

1. **The request is `payable`; the result is pulled, not pushed.** The aggregator does not call back into the requester with a verdict — it stores the result and exposes `getEvaluation(aggId)`, so the adapter must be *read* in a later transaction.
2. **The request returns an identifier, not a verdict.** `aggRequestId` returns immediately; the AI work happens afterwards.
3. **Failure is not signalled by `getEvaluation` alone.** Its third return, `exists`, is true only for a round that completed *and did not fail*; telling "still running" from "ran and failed" needs the separate `getAggregationStatus(aggId)` view. Reading only `getEvaluation` is the most common mistake available here.
4. **Funding is deterministic, but refunds are pulled, not pushed.** `maxTotalFee` gives the worst case; the surplus is credited to the requester's ledger.

## Problem statement

ERC-8004's Validation Registry is already event-driven: requesting and responding are separate transactions and the same `requestHash` accepts repeated responses. The friction is not in the registry but in the **policy** the adapter must invent for the gap, at three points — **latency** (an oracle round takes minutes; consumers reading `getValidationStatus` need an honest story for "in flight"), **timeout and no-result** (the draft requires no response ever and sets no deadline, so without adapter policy a consumer sees silence indistinguishable from "still working"), and **trust** (naming this adapter as `validatorAddress` means trusting its admin, aggregator, oracle class, and mapping rule — none visible from the registry).

## Adapter architecture

### Role

`VerdiktaValidationAdapter` is intended to *be* the `validatorAddress` — the only address the draft permits to call `validationResponse` for requests naming it. It holds a `requestHash -> Job` map with a reverse `aggRequestId -> requestHash` index, plus dispatch policy and the score-mapping rule.

### State machine

| State | Meaning |
|---|---|
| `None` | Request unknown to this adapter |
| `Requested` | Oracles dispatched; `aggRequestId` stored; awaiting a result |
| `Fulfilled` | Result read and mapped; registry write pending |
| `TimedOut` / `Failed` | Terminal internal marks: policy deadline passed, or the round failed (**design proposal**) |
| `Responded` | `validationResponse` committed to the registry |

A `Pending` state — "accepted but dispatch unconfirmed" — was deliberately **removed**: dispatch happens in the same transaction that accepts the job, so it could never be observed.

### Async latency handling

The adapter never blocks. Three details make the boundary explicit:

- **Opening a round is one transaction.** `openRound(agentId, requestHash, cids, addendum)` forwards ETH, stores the returned `aggRequestId`, and returns. Dispatch and acceptance are atomic; there is no half-open state.
- **Reading the result is a separate, permissionless transaction.** `settle(requestHash)` calls `getEvaluation`; if the result is usable it latches the mapped score. Anyone may call it — the adapter, not the caller, decides what value is written, so opening the push path does not open the score to manipulation.
- **The registry write is a third transaction.** `submitValidationResponse(requestHash)` is split from `settle`, so a registry revert can be retried without re-reading the aggregator.

ERC-8004 offers no callback to the validator, so something off-chain must observe the `ValidationRequest` event or the aggregator's completion and transact. Making it permissionless means a validation's liveness does not hinge on one operator being awake; correctness stays with the adapter's policy.

**Progressive finality is available and deliberately unused.** The draft permits repeated `validationResponse` calls per `requestHash`, so a deployment could publish an early "in flight" record then a final one. The reference submits once at a terminal outcome; the split between `settle` and `submitValidationResponse` keeps that option open without redesign.

### Timeout and no-result

The adapter's largest policy invention, labelled as such. `timeoutSeconds` (owner-configurable, default 1800) bounds how long a job may sit in `Requested`. `resolveFailure(requestHash, true)` requires the deadline to have passed, then writes `response = 0` with `tag = "timeout"`. `resolveFailure(requestHash, false)` requires the aggregator to have already reported `isComplete && failed`, then writes `response = 0` with `tag = "failed"`.

Two notes matter more than the code.

**Why write 0, and why it is not a lie.** ERC-8004's response is a single `uint8` in `[0,100]` — no null, no "unknown". A timed-out validation therefore has two representable outcomes: never respond (permanent silence, consumer hangs) or respond with the lowest value. Writing 0 makes the absence explicit; the risk is that 0 reads conventionally as "the work failed validation", which is *not* what a timeout means. The adapter separates the claims: the integer carries "no passing evidence exists", `tag` carries the cause. **Consumers taking high-stakes decisions off `getValidationStatus` must read `tag`, not just `response`.** This is policy built on the registry's type system, and a design proposal.

**The deadline is not the aggregator's deadline.** The aggregator's arbiter cutoff defaults to 300 seconds; the adapter's `timeoutSeconds` is a separate, later bound, because a round that misses its internal cutoff still needs a settlement path and the adapter's clock must outlast the mechanism it watches.

### Failure paths

| Cause | Adapter behaviour |
|---|---|
| Dispatch reverts | Caller's tx reverts with `AggregatorCallFailed`; the whole transaction unwinds, so the reservation never commits and the slot stays free |
| Dispatch returns a zero id | Same, reason `aggregator_zero_id` — treated as failure, not stored as a valid round |
| Round still running | `settle` reverts with `NotSettleable`; **no placeholder score is latched** |
| Round ran and failed | `settle` emits `aggregator_failed` then reverts; `resolveFailure(_, false)` is the terminal path |
| Deadline passed, result already available | `settle` — a timeout never overwrites a usable score |
| Round opened for a request naming another validator | `openRound` refuses before spending ETH |
| Registry response reverts | Status restored to the state its entrypoint accepts, then revert, so the call can be retried |

The last row is the subtle one. A revert in the registry call rolls back the **entire** transaction, including the status write that preceded it — there is no partial commit. The job returns to its entry status (`Requested` or `Fulfilled`), which is by construction the status the corresponding entrypoint accepts, so the call can be retried. `TimedOut` and `Failed` are internal marks within one transaction: `resolveFailure` writes them and reaches `Responded` in the same call, or the whole transaction reverts, so no external reader observes them.

A second deliberate choice: **no placeholder score is ever latched.** Writing `0` optimistically while a round is in flight would make `getValidationStatus` transiently report a failing validation for work still being evaluated. The same reasoning is why a timeout refuses to fire when the round already produced a usable result — a deadline is not evidence of absence.

### Score mapping

Verdikta's aggregator returns `uint256[]`; ERC-8004 wants `uint8` in `[0,100]`. The mapping is where an integration silently loses its meaning.

From the aggregator source: revealed score vectors are clamped on the way in, responses are clustered, and the stored aggregate is the **arithmetic mean over the clustered reveals**. The dispatcher documentation describes the output as likelihood scores on a **0–100 scale**. So the mean is already the aggregate: the vector is **not** summed and there is no basis-point rescaling to perform. An earlier draft guessed at basis-point and 1e18-scaled fallbacks; both were wrong for this contract and were removed, because a rescaler that is never correct is worse than none — it turns a bad number into a confidently formatted one.

The reference takes the maximum element and saturates at 100. **Which element means "this agent's work passed" is outcome-schema dependent and is an explicit design decision**: the maximum is a best-outcome reading, a binary `[pass, fail]` schema should index element 0, and multi-class schemas should document the mapping per agent skill. This is a real limitation, flagged rather than papered over. The saturation is not decoration: the aggregator's clamp is `1e34`, far outside `uint8`, so a raw cast would wrap.

### Access control and safety

- `SimpleOwnable` plus a `relayers` mapping. Admin (`setRelayer`, `setAggregator`, `setPolicy`, `withdrawEth`, `transferOwnership`) is `onlyOwner`; job progression is `onlyOwnerOrRelayer`, so the operational key can be hot and the policy key cold.
- `nonReentrant` on both ETH-out paths (`claimAggregatorCredit`, `withdrawEth`). `openRound` reserves state before its external call.
- External calls use `try/catch` with explicit status handling, never unchecked low-level calls.
- Immutable `validationRegistry`: repointing it would silently change which registry this address is an authorized validator for. The aggregator *is* settable, and each `Job` **pins** the aggregator it was opened against, so a repoint cannot retarget a round already in flight at a different contract.
- `openRound` refuses a `requestHash` whose registry record names a different `validatorAddress`, so ETH is not spent on a request this adapter was never asked to validate.
- `pragma solidity ^0.8.23`, matching the aggregator's own pragma. Compiles clean with solc 0.8.37 under `--optimize --via-ir`. SPDX `MIT`.

## Trust assumptions

1. **Registry trust is structural and minimal.** The draft binds responses to the nominated `validatorAddress`: the registry enforces *who* may answer for a `requestHash`, not whether the answer is good. Which address is nominated is the requesting agent owner's choice at `validationRequest` time.
2. **Adapter admin trust.** The owner can change the aggregator, relayers, class, fee ceiling, and timeout, so a compromised owner can delay, censor, or bias scores. Mitigations — multisig owner, timelock, more immutable config — are deployment choices, not properties of this reference.
3. **Oracle / Verdikta trust.** Score quality depends on the oracle class, the reputation weighting (`alpha`), the clustering rule, and the underlying models. ERC-8004 delegates incentives and slashing to the validation protocol, so this trust sits deliberately in Verdikta's economics and reputation system rather than in the registry.
4. **Data availability.** `requestURI` and the evidence CIDs must stay resolvable for arbiters. A hash binds integrity, not liveness.
5. **Mapping trust.** The likelihood-to-percent rule is a deployer heuristic. For high-stakes use, read the `responseURI` justification and the `tag`, not only the integer.
6. **No attestation claim.** Nothing here is zkML and nothing here is a TEE attestation. Unless a specific Verdikta oracle class produces such proofs, an agent advertising this adapter should file it under a crypto-economic/oracle trust model in its `supportedTrust` metadata.

## What is a design proposal, and what is ERC-8004

| Item | Status |
|---|---|
| `validationRequest` / `validationResponse` signatures, semantics, `[0,100]` response, repeated responses per `requestHash`, incentives/slashing out of scope | ERC-8004 draft @ `503591a6` |
| Adapter occupying the `validatorAddress` role | Compatible use of the draft |
| This adapter as a deployed artefact | **Not claimed — reference source only** |
| `requestAIEvaluationWithApproval`, `getEvaluation`, `getAggregationStatus`, `maxTotalFee`, `withdrawEth`, ETH funding with pull-based refunds | Verdikta `ReputationAggregator` |
| `timeoutSeconds` + auto `tag = "timeout"`; writing `0` for a non-result with cause in `tag` | **Design proposal** |
| Relayer-driven progression; refuse-non-nominated guard | **Design proposal**; relaying is forced by the absence of a registry callback |
| Likelihood → percent mapping; `alpha`, class id, fee ceiling, minimum timeout; soft/hard tag vocabulary | **Design proposal** / deployment config |

## Limitations and non-claims

- No deployment address, transaction hash, audit report, adoption figure, or endorsement is asserted. The Solidity is reference source, offered for review.
- `ReputationSingleton`, in the same repository, exposes `EvaluationFulfilled(requestId, likelihoods, justificationCID)` and a 2× fee model, and is **not** ETH-funded. This adapter targets the aggregator; a singleton-backed variant would need a different funding path.
- The adapter assumes `getEvaluation` returns a vector in the documented 0–100 domain. A deployment returning a different scale needs the mapping changed: saturation is not a substitute for a correct domain.
- Gas costs, IPFS pinning and the relayer runbook are out of scope. The evaluator does not push the round surplus back: it credits `ethOwed` to the adapter, which pulls it with `claimAggregatorCredit()` before `withdrawEth(to, amount)` sweeps what the adapter then holds. Both are admin-gated and hold no user funds.

## Questions the ERC-8004 community should settle

1. **Should a non-result be representable at all?** The type system forces a choice between silence and a dishonest-looking zero; a reserved value or "expired" convention would let validators report absence without implying failure. Registry change, or tag convention?
2. **Should the tag vocabulary and validator metadata be standardised?** `timeout` / `failed` / `soft` / `hard` are indexer-relevant and currently validator-local; oracle class, model panel and trust tier have no home in the registry at all.
3. **Is one validator address per request the right granularity?** The draft binds a single `validatorAddress`, while multi-validator networks are under discussion in the same thread. Separately, nothing on-chain distinguishes "no validator responded" from "working" from "censoring".

## Conclusion

The Validation Registry and an asynchronous oracle network fit together better than the usual "oracles need a callback" framing suggests: the draft separates request from response, allows repeated responses, and pushes incentives and slashing into the validation protocol. What is missing is not a mechanism but a **policy layer** — an explicit answer to what a validator does while it waits, what it says when nothing comes back, and what a user trusts when they name it.

This document and its adapter are an attempt at that layer, written down far enough to be argued with: a three-transaction lifecycle, a timeout path that makes absence legible without pretending it is failure, a mapping rule whose limits are stated, and a six-line trust boundary. It is offered as a concrete reference for the validator role — not an extension to the standard, and not a claim that anything here is deployed.

**This work was sponsored by a Verdikta bounty.** (Repeated for clarity; the primary disclosure is at the top of this document.)
