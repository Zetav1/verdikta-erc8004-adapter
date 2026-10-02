// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title VerdiktaValidationAdapter
 * @notice Minimal reference adapter that lets a Verdikta AI-evaluation dispatch act as the
 *         `validatorAddress` of an ERC-8004 Validation Registry.
 * @dev Reference design for the ERC-8004 Magicians discussion. Not audited. Not deployed.
 *      No deployment address, transaction hash, audit, or endorsement is claimed anywhere.
 *
 * -- Spec pin ---------------------------------------------------------------------
 * ERC-8004 "Trustless Agents" (Draft, created 2025-08-13), ethereum/ERCs
 * `ERCS/erc-8004.md` @ commit 503591a6e80e6e1affdd6403341e25269141f046 (2026-01-25).
 * That commit is master HEAD at the time of writing. Surface used, verbatim from the draft:
 *   validationRequest(address validatorAddress, uint256 agentId, string requestURI, bytes32 requestHash) external
 *   validationResponse(bytes32 requestHash, uint8 response, string responseURI, bytes32 responseHash, string tag) external
 *   getValidationStatus(bytes32 requestHash) external view returns (address,uint256,uint8,bytes32,string,uint256)
 *   getSummary(uint256 agentId, address[] validatorAddresses, string tag) external view returns (uint64,uint8)
 * The draft states validationResponse() MAY be called multiple times for the same
 * requestHash (progressive finality via tag), and that validator incentives/slashing are
 * out of scope for the registry and belong to the validation protocol (here: Verdikta).
 *
 * -- Interface provenance (verified against source, not prose) ---------------------
 * Verdikta dispatcher: github.com/verdikta/verdikta-dispatcher @ master.
 *   reputationBasedAggregator/contracts/ReputationAggregator.sol  (pragma ^0.8.23)
 *     - requestAIEvaluationWithApproval(...) is `public payable` and RETURNS bytes32 aggId.
 *     - Aggregation result event: FulfillAIEvaluation(aggRequestId, uint256[] aggregated, string justifications).
 *     - getEvaluation(aggId) -> (uint256[] likelihoods, string cid, bool exists)
 *     - getAggregationStatus(aggId) -> (isComplete, failed, commitPhaseComplete, ...)
 *     - ETH-funded: maxTotalFee(maxFee) = eff * (K + B*P); caller sends msg.value.
 *   reputationBasedSingleton/contracts/ReputationSingleton.sol    (pragma ^0.8.21)
 *     - Emits EvaluationFulfilled(requestId, ...) / EvaluationFailed(requestId); fee model 2x; NOT ETH-funded.
 * This adapter targets the AGGREGATOR (multi-oracle commit-reveal), the ETH-funded contract
 * the docs describe. See writeup.md for the ReputationSingleton variant.
 *
 * Items tagged "DESIGN PROPOSAL" are adapter policy. They are NOT ERC-8004 requirements
 * and NOT existing Verdikta features.
 */

/// @dev Minimal ERC-8004 Validation Registry surface used by this adapter.
interface IERC8004ValidationRegistry {
    function validationResponse(
        bytes32 requestHash,
        uint8 response,
        string calldata responseURI,
        bytes32 responseHash,
        string calldata tag
    ) external;

    function getValidationStatus(bytes32 requestHash)
        external
        view
        returns (
            address validatorAddress,
            uint256 agentId,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        );
}

/// @dev Minimal Verdikta ReputationAggregator surface (ETH-funded commit-reveal edition).
interface IVerdiktaAggregator {
    /// @dev payable: the aggregator is ETH-funded ("no LINK approval step" in its docs).
    function requestAIEvaluationWithApproval(
        string[] calldata cids,
        string calldata addendumText,
        uint256 alpha,
        uint256 maxOracleFee,
        uint256 estimatedBaseCost,
        uint256 maxFeeBasedScalingFactor,
        uint64 requestedClass
    ) external payable returns (bytes32 aggRequestId);

    /// @return likelihoods Aggregated scores. Only meaningful when `exists` is true.
    /// @return justificationCID IPFS CID of the combined justification.
    /// @return exists True only if the round completed AND did not fail (not merely "ended").
    function getEvaluation(bytes32 aggId)
        external
        view
        returns (uint256[] memory likelihoods, string memory justificationCID, bool exists);

    /// @dev Distinguishes "still running" from "ended but failed" -- required for timeout policy.
    function getAggregationStatus(bytes32 aggId)
        external
        view
        returns (
            bool isComplete,
            bool failed,
            bool commitPhaseComplete,
            uint256 commitExpected,
            uint256 commitReceived,
            uint256 responseCount,
            uint256 requiredN,
            uint256 clusterP,
            address requester,
            uint256 startTimestamp
        );

    /// @dev Worst-case cost of a round: effMaxFee * (K + B*P).
    function maxTotalFee(uint256 requestedMaxOracleFee) external view returns (uint256);

    /// @dev Pull-payment claim for the caller's own credited balance (ethOwed[msg.sender]).
    ///      Refunds are NOT pushed by the aggregator: _refundRequester only does
    ///      `ethOwed[requester] += refund`. Without this call the round surplus stays
    ///      credited to this adapter inside the aggregator and is unreachable.
    function withdrawEth() external;
}

/// @dev Ownable-style access control, inlined to keep this file dependency-free.
abstract contract SimpleOwnable {
    address public owner;

    error NotOwner();
    error ZeroAddress();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

/// @dev Lightweight reentrancy guard for the ETH-moving paths.
abstract contract ReentrancyGuardLite {
    uint256 private _status;

    error Reentrant();

    constructor() {
        _status = 1;
    }

    modifier nonReentrant() {
        if (_status != 1) revert Reentrant();
        _status = 2;
        _;
        _status = 1;
    }
}

contract VerdiktaValidationAdapter is SimpleOwnable, ReentrancyGuardLite {
    // --- Immutables / roles ------------------------------------------------------

    /// @notice ERC-8004 Validation Registry. Immutable: repointing it would silently
    ///         change which registry this address is an authorized validator for.
    IERC8004ValidationRegistry public immutable validationRegistry;

    /// @notice Verdikta aggregator whose arbiters perform the evaluation.
    IVerdiktaAggregator public verdiktaAggregator;

    /// @dev Aggregators this adapter has been configured with. A claim is accepted only
    ///      for one of these, so a repoint cannot strand `ethOwed` on the previous
    ///      deployment and a caller cannot aim the pull at an arbitrary contract.
    mapping(address => bool) public knownAggregators;

    /// @notice Relayers allowed to progress job state (open a round, record a result).
    /// @dev DESIGN PROPOSAL. ERC-8004 has no notion of relayer; it only binds
    ///      `validatorAddress` on the request. Keeping relayers separate from `owner`
    ///      lets the operational key be hot while the policy key stays cold.
    mapping(address => bool) public relayers;

    // --- DESIGN PROPOSAL: Verdikta request policy --------------------------------
    uint256 public alpha; // Reputation weighting 0-1000 (Verdikta semantics)
    uint256 public maxOracleFee; // Per-oracle ceiling in wei; the aggregator clamps it further
    uint256 public estimatedBaseCost;
    uint256 public maxFeeBasedScalingFactor;
    uint64 public requestedClass;
    /// @notice Seconds after which an unfulfilled round may be resolved as a timeout.
    uint256 public timeoutSeconds;

    // --- Job state ---------------------------------------------------------------

    enum Status {
        None, // never seen
        Requested, // aggregator round open, awaiting arbiters
        Fulfilled, // result read from the aggregator, awaiting registry write
        TimedOut, // policy deadline passed with no usable result
        Failed, // aggregator round failed, or explicitly aborted
        Responded // validationResponse committed to the ERC-8004 registry
    }

    struct Job {
        Status status;
        uint256 agentId;
        bytes32 requestHash;
        bytes32 aggRequestId; // Verdikta aggregator id
        address aggregator; // the aggregator this round was opened against (pinned)
        uint64 openedAt; // block.timestamp when the round was opened
        uint8 mappedResponse; // 0-100, ERC-8004 response domain
        string responseURI; // IPFS CID of the justification
        bytes32 responseHash; // optional commitment; 0 for content-addressed URIs
        string tag;
    }

    /// @dev Primary index: ERC-8004 requestHash -> Job.
    mapping(bytes32 => Job) public jobs;
    /// @dev Reverse index: Verdikta aggRequestId -> ERC-8004 requestHash.
    mapping(bytes32 => bytes32) public aggToRequestHash;

    // --- Events ------------------------------------------------------------------

    event RelayerUpdated(address indexed account, bool allowed);
    event AggregatorUpdated(address indexed aggregator);
    event PolicyUpdated(
        uint256 alpha,
        uint256 maxOracleFee,
        uint256 estimatedBaseCost,
        uint256 maxFeeBasedScalingFactor,
        uint64 requestedClass,
        uint256 timeoutSeconds
    );
    event RoundOpened(bytes32 indexed requestHash, uint256 indexed agentId, bytes32 indexed aggRequestId);
    event ResultRecorded(bytes32 indexed requestHash, bytes32 indexed aggRequestId, uint8 mappedResponse);
    event ValidationTimedOut(bytes32 indexed requestHash);
    event ValidationFailed(bytes32 indexed requestHash, string reason);
    event RegistryResponseSubmitted(bytes32 indexed requestHash, uint8 response, string tag);
    event AggregatorCreditClaimed(address indexed aggregator);
    event EthWithdrawn(address indexed to, uint256 amount);

    // --- Errors ------------------------------------------------------------------

    error NotRelayer();
    error BadStatus();
    error TimeoutNotReached();
    error EmptyCids();
    error AggregatorCallFailed();
    error RegistryCallFailed();
    error NotSettleable();
    error NotNominatedValidator();
    error UnknownAggregator();
    error EthTransferFailed();

    modifier onlyOwnerOrRelayer() {
        if (msg.sender != owner && !relayers[msg.sender]) revert NotRelayer();
        _;
    }

    constructor(
        address initialOwner,
        address validationRegistry_,
        address verdiktaAggregator_,
        uint64 requestedClass_,
        uint256 timeoutSeconds_
    ) SimpleOwnable(initialOwner) {
        if (validationRegistry_ == address(0) || verdiktaAggregator_ == address(0)) {
            revert ZeroAddress();
        }
        validationRegistry = IERC8004ValidationRegistry(validationRegistry_);
        verdiktaAggregator = IVerdiktaAggregator(verdiktaAggregator_);
        requestedClass = requestedClass_;
        // DESIGN PROPOSAL default: 30 minutes. The aggregator's own arbiter deadline is
        // responseTimeoutSeconds (300s = 5 min default, contract-set); 30 min allows several
        // commit/reveal rounds plus manual retries before the adapter gives up.
        uint256 timeout = timeoutSeconds_ == 0 ? 1800 : timeoutSeconds_;
        // Same floor as setPolicy. A 1–59s window is as much a footgun as zero:
        // resolveFailure could fire before the aggregator's own round can finish.
        timeoutSeconds = timeout < 60 ? 60 : timeout;
        knownAggregators[verdiktaAggregator_] = true;
        // DESIGN PROPOSAL: the aggregator holds no alpha, no fee default and no base-cost
        // constant. It takes all of them per request. 500 is the balanced reputation weight
        // used by Verdikta's own DemoClient, not a contract default; 5 mirrors the typical
        // scaling factor in the same example; 8e9 is this adapter's own estimate.
        alpha = 500;
        maxFeeBasedScalingFactor = 5;
        estimatedBaseCost = 8e9;
        // maxOracleFee intentionally left 0 until the owner sets policy: a 0 ceiling would
        // starve oracle selection, so this fails loudly at request time rather than silently.
    }

    // --- Admin -------------------------------------------------------------------

    function setRelayer(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        relayers[account] = allowed;
        emit RelayerUpdated(account, allowed);
    }

    /// @dev Not immutable on purpose: a Verdikta aggregator deployment can be superseded.
    ///      Each Job pins the aggregator it was opened against, so repointing does not
    ///      retarget already-open rounds at a different contract.
    function setAggregator(address aggregator_) external onlyOwner {
        if (aggregator_ == address(0)) revert ZeroAddress();
        verdiktaAggregator = IVerdiktaAggregator(aggregator_);
        // Keep the previous aggregator claimable. Its ethOwed credit does not move
        // when this pointer changes.
        knownAggregators[aggregator_] = true;
        emit AggregatorUpdated(aggregator_);
    }

    function setPolicy(
        uint256 alpha_,
        uint256 maxOracleFee_,
        uint256 estimatedBaseCost_,
        uint256 maxFeeBasedScalingFactor_,
        uint64 requestedClass_,
        uint256 timeoutSeconds_
    ) external onlyOwner {
        alpha = alpha_;
        maxOracleFee = maxOracleFee_;
        estimatedBaseCost = estimatedBaseCost_;
        maxFeeBasedScalingFactor = maxFeeBasedScalingFactor_;
        requestedClass = requestedClass_;
        // A zero window would let resolveFailure fire in the same timestamp the round opened.
        // Enforce a floor rather than silently documenting a footgun.
        timeoutSeconds = timeoutSeconds_ < 60 ? 60 : timeoutSeconds_;
        emit PolicyUpdated(
            alpha_, maxOracleFee_, estimatedBaseCost_, maxFeeBasedScalingFactor_, requestedClass_, timeoutSeconds
        );
    }

    /// @notice Pull this adapter's `ethOwed` credit out of a configured aggregator.
    /// @dev The aggregator credits refunds to `ethOwed[requester]` and does NOT push ETH.
    ///      `_refundRequester` only does `ethOwed[agg.requester] += refund`. This adapter is
    ///      that requester. Pass the aggregator the round was opened against: after
    ///      `setAggregator`, the surplus stays on the previous deployment.
    ///      The aggregator then transfers to `msg.sender` == this adapter, which `receive()` accepts.
    ///      Permissionless on purpose: it can only move credit TO this contract, and only
    ///      from an aggregator this adapter was configured with.
    ///      The aggregator reverts with `NothingOwed()` when the credit is zero, so this
    ///      call reverts too. Simulate with `ethOwed(address(this))` on that aggregator.
    function claimAggregatorCredit(address aggregator_) external nonReentrant {
        if (aggregator_ == address(0) || !knownAggregators[aggregator_]) revert UnknownAggregator();
        IVerdiktaAggregator(aggregator_).withdrawEth();
        emit AggregatorCreditClaimed(aggregator_);
    }

    /// @notice Sweep ETH actually held by this adapter to a destination.
    /// @dev Run `claimAggregatorCredit(aggregator)` first, otherwise this only moves a balance that
    ///      may still be zero while the surplus sits in the aggregator's ledger.
    ///      nonReentrant; no state is written after the call.
    function withdrawEth(address payable to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit EthWithdrawn(to, amount);
    }

    receive() external payable {}

    // --- Open a round ------------------------------------------------------------

    /**
     * @notice Open a Verdikta evaluation for an ERC-8004 validation request.
     * @dev Caller must forward ETH of at least `aggregator.maxTotalFee(maxOracleFee)`.
     *      The aggregator does NOT push change back: it credits the surplus to
     *      `ethOwed[this adapter]`. That credit must be pulled with
     *      claimAggregatorCredit(aggregator), which calls that aggregator's withdrawEth().
     *
     *      Why a relayer call and not an automatic hook: ERC-8004 emits ValidationRequest
     *      as an event; there is no on-chain callback to `validatorAddress`. Something
     *      off-chain must observe the request and drive this adapter. That is inherent to
     *      the registry's design, not a shortcut taken here.
     *
     * @param agentId     ERC-8004 agentId from the ValidationRequest event.
     * @param requestHash keccak256 commitment from the ValidationRequest event.
     * @param cids        IPFS CIDs of the evidence, resolved from requestURI off-chain.
     * @param addendum    Optional context forwarded to Verdikta (<= 1000 chars per aggregator).
     */
    function openRound(
        uint256 agentId,
        bytes32 requestHash,
        string[] calldata cids,
        string calldata addendum
    ) external payable onlyOwnerOrRelayer returns (bytes32 aggRequestId) {
        if (cids.length == 0) revert EmptyCids();
        Job storage job = jobs[requestHash];
        if (job.status != Status.None) revert BadStatus();
        // DESIGN PROPOSAL guard: refuse to spend ETH on a request that was not addressed to
        // this adapter. ERC-8004 stores `validatorAddress` on the request, so if the registry
        // already has a status for this hash and it names someone else, the round would be
        // paid for and then rejected by validationResponse. If the registry has no record yet
        // (request not submitted, or implementation reverts on unknown hash), this check is
        // skipped and the relayer remains responsible -- see the trust section of the writeup.
        try validationRegistry.getValidationStatus(requestHash) returns (
            address validator, uint256, uint8, bytes32, string memory, uint256
        ) {
            if (validator != address(0) && validator != address(this)) revert NotNominatedValidator();
        } catch {}

        // Effects before interaction: reserve the slot so a re-entrant or retried call
        // cannot open two rounds for the same requestHash.
        job.status = Status.Requested;
        job.agentId = agentId;
        job.requestHash = requestHash;
        job.openedAt = uint64(block.timestamp);

        try verdiktaAggregator.requestAIEvaluationWithApproval{ value: msg.value }(
            cids, addendum, alpha, maxOracleFee, estimatedBaseCost, maxFeeBasedScalingFactor, requestedClass
        ) returns (bytes32 aggId) {
            aggRequestId = aggId;
        } catch {
            // The revert unwinds this assignment and any event. Nothing is observable.
            job.status = Status.None;
            revert AggregatorCallFailed();
        }

        if (aggRequestId == bytes32(0)) {
            job.status = Status.None;
            revert AggregatorCallFailed();
        }

        job.aggRequestId = aggRequestId;
        job.aggregator = address(verdiktaAggregator);
        aggToRequestHash[aggRequestId] = requestHash;
        emit RoundOpened(requestHash, agentId, aggRequestId);
    }

    // --- Settle ------------------------------------------------------------------

    /**
     * @notice Read the aggregator and latch the mapped score onto the job.
     * @dev Only valid from `Requested`; reverts while the round is still running rather
     *      than latching a placeholder score. Permissionless by design (DESIGN PROPOSAL):
     *      anyone may push the read, because the adapter -- not the caller -- decides what
     *      value gets written to the registry.
     */
    function settle(bytes32 requestHash) external {
        Job storage job = jobs[requestHash];
        if (job.status != Status.Requested) revert BadStatus();

        IVerdiktaAggregator agg = IVerdiktaAggregator(job.aggregator);
        (uint256[] memory likelihoods, string memory justificationCID, bool exists) =
            agg.getEvaluation(job.aggRequestId);

        if (!exists) {
            // Still running, or finished in failure. Either way no score is latched.
            // An event here would be wiped by the revert. resolveFailure(_, false)
            // is the path that records a failed round.
            revert NotSettleable();
        }

        uint8 mapped = _mapLikelihoodsToResponse(likelihoods);
        job.mappedResponse = mapped;
        job.responseURI = justificationCID;
        job.responseHash = bytes32(0); // content-addressed IPFS URI; hash optional per ERC-8004
        job.tag = "verdikta-aggregator";
        job.status = Status.Fulfilled;

        emit ResultRecorded(requestHash, job.aggRequestId, mapped);
    }

    /**
     * @notice Terminal path when no usable result exists.
     * @dev DESIGN PROPOSAL. ERC-8004 does not require a validator to ever respond and says
     *      nothing about deadlines. Without this, consumers reading getValidationStatus()
     *      would see silence forever and could not distinguish "still pending" from "will
     *      never answer". Two triggers:
     *        - policy deadline passed (timeout_ = true), or
     *        - the aggregator round already ended in failure (timeout_ = false).
     *      `tag` records which, so indexers can tell them apart.
     */
    function resolveFailure(bytes32 requestHash, bool timeout_) external onlyOwnerOrRelayer {
        Job storage job = jobs[requestHash];
        if (job.status != Status.Requested) revert BadStatus();

        if (timeout_) {
            if (block.timestamp < uint256(job.openedAt) + timeoutSeconds) revert TimeoutNotReached();
            // A policy deadline is not evidence of absence. If the round already produced a
            // usable result that nobody settled yet, writing 0 here would overwrite a real
            // score with a false negative. Refuse and let settle() latch it.
            (, , bool exists) = IVerdiktaAggregator(job.aggregator).getEvaluation(job.aggRequestId);
            if (exists) revert NotSettleable();
            job.tag = "timeout";
        } else {
            IVerdiktaAggregator agg = IVerdiktaAggregator(job.aggregator);
            (bool isComplete, bool failed,,,,,,,,) = agg.getAggregationStatus(job.aggRequestId);
            if (!(isComplete && failed)) revert BadStatus();
            job.tag = "failed";
        }

        // ERC-8004's response is a single uint8 in [0,100] with no null value. Writing 0 is
        // the only way to make the absence explicit on-chain. This is NOT a claim that the
        // agent's work failed validation -- the tag carries that distinction. Consumers
        // making high-stakes decisions must read the tag, not just the uint8.
        job.mappedResponse = 0;
        job.status = timeout_ ? Status.TimedOut : Status.Failed;

        if (timeout_) emit ValidationTimedOut(requestHash);
        else emit ValidationFailed(requestHash, "aggregator_failed");

        _submitToRegistry(requestHash, job);
    }

    /**
     * @notice Commit a latched result to the ERC-8004 registry.
     * @dev Separate from settle() so a registry write can be retried without re-reading the
     *      aggregator. ERC-8004 explicitly allows multiple validationResponse calls per
     *      requestHash, so a later refinement (e.g. tag="hard") stays representable.
     */
    function submitValidationResponse(bytes32 requestHash) external onlyOwnerOrRelayer {
        Job storage job = jobs[requestHash];
        if (job.status != Status.Fulfilled) revert BadStatus();
        _submitToRegistry(requestHash, job);
    }

    // --- Internals ---------------------------------------------------------------

    function _submitToRegistry(bytes32 requestHash, Job storage job) internal {
        // Effects before interaction.
        Status prior = job.status;
        job.status = Status.Responded;

        try validationRegistry.validationResponse(
            requestHash, job.mappedResponse, job.responseURI, job.responseHash, job.tag
        ) {
            emit RegistryResponseSubmitted(requestHash, job.mappedResponse, job.tag);
        } catch {
            // The revert below rolls back the ENTIRE transaction, including the
            // `job.status = Status.Responded` above and this assignment. There is no partial
            // commit: the job simply returns to whatever status it had on entry (Requested or
            // Fulfilled), which is exactly the status the corresponding entrypoint accepts, so
            // the call can be retried. The assignment is kept for clarity but is not what makes
            // the retry work. TimedOut/Failed are internal marks within a single transaction --
            // they are never observable externally, because resolveFailure writes them and
            // reaches Responded in the same call, or reverts entirely.
            job.status = prior;
            revert RegistryCallFailed();
        }
    }

    /**
     * @dev Map an aggregator likelihood vector to ERC-8004's uint8 response in [0,100].
     *
     *      Grounded in the aggregator source: aggregatedLikelihoods[j] is the arithmetic
     *      MEAN over clustered reveals, and each revealed score is clamped on the way in to
     *      MAX_ARBITER_RETURN_SCORE (1e34). The dispatcher docs describe the output as
     *      likelihood scores on a 0-100 scale. So the mean already IS the aggregate -- the
     *      vector must NOT be summed, and there is no basis-points rescaling to do.
     *
     *      DESIGN PROPOSAL: which element of the vector means "this agent's work passed" is
     *      outcome-schema dependent. Default here is the maximum element (best-outcome
     *      reading). Deployers using a binary [pass, fail] schema should index element 0
     *      instead, and multi-class schemas should document the mapping per agent skill.
     */
    function _mapLikelihoodsToResponse(uint256[] memory likelihoods) internal pure returns (uint8) {
        if (likelihoods.length == 0) return 0;
        uint256 maxL = 0;
        for (uint256 i = 0; i < likelihoods.length; i++) {
            if (likelihoods[i] > maxL) maxL = likelihoods[i];
        }
        // Clamp defensively: the aggregator's own clamp (1e34) is far outside uint8, so an
        // out-of-range value must be saturated, never wrapped.
        if (maxL > 100) return 100;
        return uint8(maxL);
    }

    // --- Views -------------------------------------------------------------------

    function getJob(bytes32 requestHash)
        external
        view
        returns (
            Status status,
            uint256 agentId,
            bytes32 aggRequestId,
            uint64 openedAt,
            uint8 mappedResponse,
            string memory responseURI,
            string memory tag
        )
    {
        Job storage job = jobs[requestHash];
        return (
            job.status,
            job.agentId,
            job.aggRequestId,
            job.openedAt,
            job.mappedResponse,
            job.responseURI,
            job.tag
        );
    }

    /// @notice Worst-case ETH this adapter must forward for one round at current policy.
    function requiredRoundFunding() external view returns (uint256) {
        return verdiktaAggregator.maxTotalFee(maxOracleFee);
    }
}
