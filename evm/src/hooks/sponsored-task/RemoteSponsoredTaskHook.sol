// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { OwnableUpgradeable } from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ITMPCore } from "../../interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../../interfaces/ITMPDiamond.sol";
import { TMP_AUCTION } from "../../interfaces/ITMPModes.sol";
import { BaseTMPHook } from "../base/BaseTMPHook.sol";
import { ISponsoredTaskFeeBank } from "./interfaces/ISponsoredTaskFeeBank.sol";
import { SponsoredTaskSettlement } from "./libraries/SponsoredTaskSettlement.sol";
import { SponsoredTaskTerms } from "./libraries/SponsoredTaskTerms.sol";

/// @title RemoteSponsoredTaskHook
/// @notice The Base half of settler mode: binds a Taskmarket task to a Sponsored Task vault on a
///         remote chain that has no Taskmarket Diamond.
/// @dev Specified in `docs/specs/sponsored-tasks/evm-attested-settler.md`.
///
///      At funding it records the commitment `(remoteChainId, vault, token, grossAmount,
///      commitmentNonce)`; at completion it commits the verdict's awards; and the permissionless
///      `finalizeSettlement` computes the award root with the remote allocation's ids and emits it
///      with one entitlement event per leaf. It moves no tokens and calls no vault: the settler
///      service reads these events and drives the remote `SponsoredTaskSettler`. It is a separate
///      contract from `SponsoredTaskHook`, which stays the controller of every Base-local vault.
///
///      The one token it does move is the per-task creation fee: at funding it charges the manager's
///      `SponsoredTaskFeeBank` credit once, keyed by the task id, exactly as `SponsoredTaskHook` does
///      for a Base-local task. Its fee bank is its own (the Base hook's fee bank guard cannot add a
///      charger), deployed with the Base fee bank's token, amount and recipient, so a remote task
///      costs the same fee as a hook-mode task. The fee is not refunded when the task is cancelled
///      or expires; only the remote reservation is released.
///
///      UUPS-upgradeable with fixed-slot storage, the same pattern `SponsoredTaskHook` uses.
contract RemoteSponsoredTaskHook is BaseTMPHook, ReentrancyGuard, OwnableUpgradeable, UUPSUpgradeable {
    uint8 public constant HOOK_DATA_VERSION = 1;
    /// @dev Same gas-safety bound as `SponsoredTaskHook.MAX_AWARDS`: the completion commitment loops
    ///      over awards inside the Diamond's fixed hook gas stipend.
    uint32 public constant MAX_AWARDS = 8;
    /// @notice How long after the Base task's expiry an unsettled reservation may be released.
    uint256 public constant RESERVATION_RELEASE_GRACE = 7 days;

    /// @notice The Base fee bank charged once per task at commitment, keyed by task id. An
    ///         immutable of the implementation, so it takes no proxy storage.
    ISponsoredTaskFeeBank public immutable feeBank;

    enum HookStatus {
        None,
        Committed,
        CompletionCommitted,
        ReleaseCommitted,
        SettlementPrepared,
        AwardCountExceeded
    }

    /// @dev What the vault manager commits to at task creation. `epoch`, `feeBps` and
    ///      `feeRecipient` are the remote vault's values the settler reserves against.
    struct FundingRequest {
        uint256 remoteChainId;
        address vault;
        bytes32 vaultId;
        address token;
        uint256 grossAmount;
        uint64 commitmentNonce;
        uint64 epoch;
        uint16 feeBps;
        address feeRecipient;
        bytes32 taskTermsHash;
    }

    struct Commitment {
        uint256 remoteChainId;
        address vault;
        bytes32 vaultId;
        address token;
        bytes32 allocationId;
        address manager;
        uint64 commitmentNonce;
        uint64 epoch;
        uint16 feeBps;
        address feeRecipient;
        uint256 grossAmount;
        bytes32 termsHash;
    }

    struct Outcome {
        ITMPCore.VerdictType verdictType;
        bytes32 awardsDigest;
        uint32 awardCount;
        uint256 nativePayoutPool;
        bytes32 rewardsRoot;
        uint32 leafCount;
        uint256 sponsoredTaskTotal;
        uint256 feeTotal;
        uint256 distributedGross;
        HookStatus status;
    }

    /// @dev Fixed-slot storage. Fields must only ever be APPENDED.
    struct HookStorage {
        mapping(bytes32 taskId => Commitment commitment) commitments;
        mapping(bytes32 taskId => Outcome outcome) outcomes;
        mapping(bytes32 commitmentKey => bytes32 taskId) taskByCommitment;
    }

    bytes32 private constant HOOK_STORAGE_SLOT = keccak256("taskmarket.remotesponsoredtaskhook.storage.v1");

    function _s() private pure returns (HookStorage storage hs) {
        bytes32 slot = HOOK_STORAGE_SLOT;
        assembly {
            hs.slot := slot
        }
    }

    error InvalidHookDataVersion(uint8 version);
    error InvalidHookContext(bytes32 taskId);
    error InvalidFundingRequest();
    error CommitmentAlreadyExists(bytes32 taskId);
    error CommitmentNonceUsed(uint256 remoteChainId, address vault, uint64 commitmentNonce, bytes32 taskId);
    error CommitmentNotFound(bytes32 taskId);
    error CommitmentWrongStatus(bytes32 taskId, HookStatus status);
    error TaskTermsMismatch(bytes32 expected, bytes32 actual);
    error TaskNotTerminal(bytes32 taskId, ITMPCore.TaskStatus status);
    error VerdictNotIssued();
    error VerdictCommitmentMismatch(bytes32 taskId);
    error AwardsRequired(bytes32 taskId);
    error ZeroAddress();
    error InvalidContract(address target);

    event RemoteSponsoredTaskCommitted(
        bytes32 indexed taskId,
        bytes32 indexed vaultId,
        bytes32 indexed allocationId,
        uint256 remoteChainId,
        address vault,
        address token,
        address manager,
        uint256 grossAmount,
        uint64 commitmentNonce,
        uint64 epoch,
        uint16 feeBps,
        address feeRecipient,
        bytes32 taskTermsHash
    );
    event CompletionCommitted(
        bytes32 indexed taskId,
        bytes32 indexed allocationId,
        ITMPCore.VerdictType verdictType,
        bytes32 awardsDigest,
        uint32 awardCount,
        uint256 nativePayoutPool
    );
    event TerminalReleaseCommitted(bytes32 indexed taskId, bytes32 indexed allocationId);
    event ForfeitReservationRetained(bytes32 indexed taskId, bytes32 indexed allocationId, address indexed worker);
    event SponsoredTaskEntitlement(
        bytes32 indexed taskId,
        uint256 indexed leafIndex,
        address indexed worker,
        uint256 awardIndex,
        uint256 grossAmount,
        uint256 feeAmount,
        uint256 netAmount,
        bytes32 leaf
    );
    event SettlementPrepared(
        bytes32 indexed taskId,
        bytes32 indexed allocationId,
        bytes32 rewardsRoot,
        uint32 leafCount,
        uint256 sponsoredTaskTotal,
        uint256 feeTotal,
        uint256 distributedGross,
        uint256 releasedGross,
        uint256 remoteChainId
    );
    event SponsoredTaskUnsettleableAwardCount(bytes32 indexed taskId, bytes32 indexed allocationId, uint256 awardCount);

    constructor(address taskmarket_, ISponsoredTaskFeeBank feeBank_) BaseTMPHook(taskmarket_) {
        if (address(feeBank_) == address(0)) revert ZeroAddress();
        if (address(feeBank_).code.length == 0) revert InvalidContract(address(feeBank_));
        feeBank = feeBank_;
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner { }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice The remote allocation id for a Base task: one Base task maps to one allocation.
    function allocationIdFor(uint256 baseChainId, bytes32 taskId) public pure returns (bytes32) {
        return keccak256(abi.encode(baseChainId, taskId));
    }

    function commitment(bytes32 taskId) external view returns (Commitment memory) {
        return _s().commitments[taskId];
    }

    function outcome(bytes32 taskId) external view returns (Outcome memory) {
        return _s().outcomes[taskId];
    }

    function taskByCommitment(uint256 remoteChainId, address vault, uint64 commitmentNonce)
        external
        view
        returns (bytes32)
    {
        return _s().taskByCommitment[_commitmentKey(remoteChainId, vault, commitmentNonce)];
    }

    /// @notice When the keeper may release a reservation that has no settlement: seven days after
    ///         the Base task's expiry.
    function reservationReleaseAfter(bytes32 taskId) external view returns (uint256) {
        _requireCommitment(taskId);
        return ITMPCore(diamond).getTask(taskId).expiryTime + RESERVATION_RELEASE_GRACE;
    }

    function encodeHookData(FundingRequest calldata request) external pure returns (bytes memory) {
        return abi.encode(HOOK_DATA_VERSION, request);
    }

    function currentTaskTermsHash(bytes32 taskId) external view returns (bytes32) {
        ITMPCore.TaskContext memory context = ITMPDiamond(diamond).getTaskContext(taskId);
        return _currentTermsHash(taskId, context);
    }

    // ---------------------------------------------------------------------------------------------
    // Permissionless settlement and repair
    // ---------------------------------------------------------------------------------------------

    /// @notice Computes and emits the award root of an accepted task against its committed awards.
    function finalizeSettlement(bytes32 taskId, ITMPCore.Award[] calldata awards)
        external
        nonReentrant
        returns (bytes32 rewardsRoot)
    {
        _requireCommitment(taskId);
        ITMPCore.Award[] memory awardsMemory = awards;
        return _finalizeSettlement(taskId, awardsMemory);
    }

    /// @notice Records a release for a cancelled or expired task whose callback was missed.
    function finalizeRelease(bytes32 taskId) external nonReentrant returns (HookStatus) {
        _requireCommitment(taskId);
        ITMPCore.Task memory task = ITMPCore(diamond).getTask(taskId);
        if (task.status != ITMPCore.TaskStatus.Cancelled && task.status != ITMPCore.TaskStatus.Expired) {
            revert TaskNotTerminal(taskId, task.status);
        }
        _commitRelease(taskId);
        return _s().outcomes[taskId].status;
    }

    /// @notice Repairs a swallowed after-hook from Taskmarket's terminal state, as
    ///         `SponsoredTaskHook.reconcile` does for a Base-local vault.
    function reconcile(bytes32 taskId) external nonReentrant returns (HookStatus) {
        Commitment storage c = _requireCommitment(taskId);
        Outcome storage o = _s().outcomes[taskId];
        if (
            o.status == HookStatus.SettlementPrepared || o.status == HookStatus.ReleaseCommitted
                || o.status == HookStatus.AwardCountExceeded
        ) return o.status;

        ITMPCore.Task memory task = ITMPCore(diamond).getTask(taskId);
        if (task.id != taskId || task.requester != c.manager) revert InvalidHookContext(taskId);

        if (task.status == ITMPCore.TaskStatus.Cancelled || task.status == ITMPCore.TaskStatus.Expired) {
            _commitRelease(taskId);
            return o.status;
        }
        if (task.status != ITMPCore.TaskStatus.Accepted) revert TaskNotTerminal(taskId, task.status);

        if (o.status == HookStatus.CompletionCommitted) {
            ITMPCore.Verdict memory verdict = ITMPDiamond(diamond).getTaskVerdict(taskId);
            ITMPCore.Award[] memory awards = verdict.awards;
            if (!verdict.issued) {
                if (o.awardCount != 1) revert AwardsRequired(taskId);
                awards = new ITMPCore.Award[](1);
                uint256 amount = task.mode == TMP_AUCTION ? task.stakeAmount : task.reward;
                awards[0] = ITMPCore.Award({ worker: task.worker, amount: amount, rank: 1 });
            }
            _finalizeSettlement(taskId, awards);
            return o.status;
        }

        // An accepted auction with no completion commitment (a verdict finalized after expiry
        // skips the check hooks): commit what checkComplete would have committed.
        if (o.status == HookStatus.Committed && task.mode == TMP_AUCTION && task.worker != address(0)) {
            ITMPCore.Verdict memory verdict = ITMPDiamond(diamond).getTaskVerdict(taskId);
            ITMPCore.VerdictType verdictType = ITMPCore.VerdictType.APPROVE;
            ITMPCore.Award[] memory awards;
            if (verdict.issued) {
                verdictType = verdict.verdictType;
                awards = verdict.awards;
            } else {
                awards = new ITMPCore.Award[](1);
                awards[0] = ITMPCore.Award({ worker: task.worker, amount: task.stakeAmount, rank: 1 });
            }
            uint256 pool = _nativePayoutPool(
                taskId, task.mode, task.reward, ITMPDiamond(diamond).getTaskEvaluatorConfig(taskId).evaluatorFeeBps
            );
            if (!_commitAwards(taskId, verdictType, awards, pool)) return o.status;
            _finalizeSettlement(taskId, awards);
            return o.status;
        }

        revert AwardsRequired(taskId);
    }

    // ---------------------------------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------------------------------

    function _checkFund(bytes32 taskId, ITMPCore.TaskContext calldata ctx, bytes calldata hookData)
        internal
        override
        returns (bool)
    {
        if (
            taskId == bytes32(0) || taskId != ctx.taskId || ctx.requester == address(0) || ctx.reward == 0
                || ctx.currentState != ITMPCore.TaskStatus.Open
        ) revert InvalidHookContext(taskId);
        if (_s().outcomes[taskId].status != HookStatus.None) revert CommitmentAlreadyExists(taskId);

        (uint8 version, FundingRequest memory request) = abi.decode(hookData, (uint8, FundingRequest));
        if (version != HOOK_DATA_VERSION) revert InvalidHookDataVersion(version);
        _validateFundingRequest(request);

        bytes32 termsHash = _currentTermsHash(taskId, ctx);
        if (request.taskTermsHash != termsHash) revert TaskTermsMismatch(request.taskTermsHash, termsHash);

        bytes32 key = _commitmentKey(request.remoteChainId, request.vault, request.commitmentNonce);
        bytes32 existing = _s().taskByCommitment[key];
        if (existing != bytes32(0)) {
            revert CommitmentNonceUsed(request.remoteChainId, request.vault, request.commitmentNonce, existing);
        }
        _s().taskByCommitment[key] = taskId;

        // Charge in the same transaction as Taskmarket creation, as `SponsoredTaskHook` does. Any
        // later revert rolls this back, and charge() reverts on every real failure
        // (InsufficientCredit etc.), so the receipt never needs checking here.
        // slither-disable-next-line unused-return
        feeBank.charge(ctx.requester, taskId);

        _recordCommitment(taskId, ctx.requester, request);
        return true;
    }

    /// @dev Split out of `_checkFund` to keep the struct literal in its own stack frame.
    function _recordCommitment(bytes32 taskId, address manager, FundingRequest memory request) private {
        bytes32 allocationId = allocationIdFor(block.chainid, taskId);
        _s().commitments[taskId] = Commitment({
            remoteChainId: request.remoteChainId,
            vault: request.vault,
            vaultId: request.vaultId,
            token: request.token,
            allocationId: allocationId,
            manager: manager,
            commitmentNonce: request.commitmentNonce,
            epoch: request.epoch,
            feeBps: request.feeBps,
            feeRecipient: request.feeRecipient,
            grossAmount: request.grossAmount,
            termsHash: request.taskTermsHash
        });
        _s().outcomes[taskId].status = HookStatus.Committed;
        emit RemoteSponsoredTaskCommitted(
            taskId,
            request.vaultId,
            allocationId,
            request.remoteChainId,
            request.vault,
            request.token,
            manager,
            request.grossAmount,
            request.commitmentNonce,
            request.epoch,
            request.feeBps,
            request.feeRecipient,
            request.taskTermsHash
        );
    }

    function _checkComplete(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.Verdict calldata verdict)
        internal
        override
        returns (bool)
    {
        _requireMatchingCommitment(taskId, ctx);
        _commitCompletion(taskId, ctx, verdict);
        return true;
    }

    function _checkEvaluate(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address)
        internal
        view
        override
        returns (bool)
    {
        _requireMatchingCommitment(taskId, ctx);
        HookStatus status = _s().outcomes[taskId].status;
        if (status != HookStatus.Committed) revert CommitmentWrongStatus(taskId, status);
        return true;
    }

    function _onComplete(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.Verdict calldata verdict)
        internal
        override
    {
        Commitment storage c = _s().commitments[taskId];
        if (c.manager == address(0) || c.manager != ctx.requester) return;
        if (_s().outcomes[taskId].status == HookStatus.Committed) _commitCompletion(taskId, ctx, verdict);
    }

    function _onCancel(bytes32 taskId, ITMPCore.TaskContext calldata ctx) internal override {
        _tryCommitRelease(taskId, ctx, ITMPCore.TaskStatus.Cancelled);
    }

    function _onExpire(bytes32 taskId, ITMPCore.TaskContext calldata ctx) internal override {
        _tryCommitRelease(taskId, ctx, ITMPCore.TaskStatus.Expired);
    }

    function _onForfeit(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker) internal override {
        Commitment storage c = _s().commitments[taskId];
        if (_s().outcomes[taskId].status != HookStatus.Committed || c.manager != ctx.requester) return;
        emit ForfeitReservationRetained(taskId, c.allocationId, worker);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _commitCompletion(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.Verdict calldata verdict)
        private
    {
        if (!verdict.issued) revert VerdictNotIssued();
        uint256 pool = _nativePayoutPool(taskId, ctx.mode, ctx.reward, ctx.evaluatorFeeBps);
        ITMPCore.Award[] memory awards = verdict.awards;
        Outcome storage o = _s().outcomes[taskId];
        if (o.status == HookStatus.CompletionCommitted) {
            bytes32 digest = SponsoredTaskSettlement.awardsDigestMemory(taskId, verdict.verdictType, awards);
            if (
                o.verdictType != verdict.verdictType || o.awardsDigest != digest
                    || o.awardCount != uint32(awards.length) || o.nativePayoutPool != pool
            ) revert VerdictCommitmentMismatch(taskId);
            return;
        }
        if (o.status == HookStatus.AwardCountExceeded) return;
        if (o.status != HookStatus.Committed) revert CommitmentWrongStatus(taskId, o.status);
        _commitAwards(taskId, verdict.verdictType, awards, pool);
    }

    /// @dev Never reverts on award count: above `MAX_AWARDS` the sponsorship is marked unsettleable
    ///      so the settler releases it, and Taskmarket's own USDC settlement proceeds.
    /// @return committed False when the award count was too large.
    function _commitAwards(
        bytes32 taskId,
        ITMPCore.VerdictType verdictType,
        ITMPCore.Award[] memory awards,
        uint256 pool
    ) private returns (bool committed) {
        Outcome storage o = _s().outcomes[taskId];
        bytes32 allocationId = _s().commitments[taskId].allocationId;
        uint256 count = awards.length;
        if (count > MAX_AWARDS) {
            o.status = HookStatus.AwardCountExceeded;
            emit SponsoredTaskUnsettleableAwardCount(taskId, allocationId, count);
            return false;
        }
        o.verdictType = verdictType;
        o.awardsDigest = SponsoredTaskSettlement.awardsDigestMemory(taskId, verdictType, awards);
        o.awardCount = uint32(count);
        o.nativePayoutPool = pool;
        o.status = HookStatus.CompletionCommitted;
        emit CompletionCommitted(taskId, allocationId, verdictType, o.awardsDigest, uint32(count), pool);
        return true;
    }

    function _finalizeSettlement(bytes32 taskId, ITMPCore.Award[] memory awards) private returns (bytes32) {
        Outcome storage o = _s().outcomes[taskId];
        if (o.status == HookStatus.SettlementPrepared) return o.rewardsRoot;
        if (o.status == HookStatus.AwardCountExceeded) return bytes32(0);
        if (o.status != HookStatus.CompletionCommitted) revert CommitmentWrongStatus(taskId, o.status);

        ITMPCore.Task memory task = ITMPCore(diamond).getTask(taskId);
        if (task.status != ITMPCore.TaskStatus.Accepted) revert TaskNotTerminal(taskId, task.status);
        if (
            SponsoredTaskSettlement.awardsDigestMemory(taskId, o.verdictType, awards) != o.awardsDigest
                || awards.length != o.awardCount
        ) revert VerdictCommitmentMismatch(taskId);

        Commitment storage c = _s().commitments[taskId];
        SponsoredTaskSettlement.Result memory result = SponsoredTaskSettlement.calculate(
            SponsoredTaskSettlement.SettlementIdentity({
                vaultId: c.vaultId, vaultEpoch: c.epoch, allocationId: c.allocationId, taskId: taskId
            }),
            c.grossAmount,
            o.nativePayoutPool,
            c.feeBps,
            o.verdictType,
            awards
        );
        _recordAndEmit(taskId, o, c, result);
        return result.rewardsRoot;
    }

    function _recordAndEmit(
        bytes32 taskId,
        Outcome storage o,
        Commitment storage c,
        SponsoredTaskSettlement.Result memory result
    ) private {
        o.rewardsRoot = result.rewardsRoot;
        o.leafCount = result.leafCount;
        o.sponsoredTaskTotal = result.sponsoredTaskTotal;
        o.feeTotal = result.feeTotal;
        o.distributedGross = result.distributedGross;
        o.status = HookStatus.SettlementPrepared;

        uint256 entitlementCount = result.entitlements.length;
        for (uint256 i; i < entitlementCount; ++i) {
            SponsoredTaskSettlement.Entitlement memory e = result.entitlements[i];
            emit SponsoredTaskEntitlement(
                taskId, e.leafIndex, e.worker, e.awardIndex, e.grossAmount, e.feeAmount, e.netAmount, e.leaf
            );
        }
        emit SettlementPrepared(
            taskId,
            c.allocationId,
            result.rewardsRoot,
            result.leafCount,
            result.sponsoredTaskTotal,
            result.feeTotal,
            result.distributedGross,
            result.releasedGross,
            c.remoteChainId
        );
    }

    function _tryCommitRelease(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.TaskStatus expected)
        private
    {
        Commitment storage c = _s().commitments[taskId];
        if (c.manager == address(0) || c.manager != ctx.requester || ctx.taskId != taskId) return;
        if (ctx.currentState != expected) return;
        HookStatus status = _s().outcomes[taskId].status;
        if (status != HookStatus.Committed && status != HookStatus.CompletionCommitted) return;
        _s().outcomes[taskId].status = HookStatus.ReleaseCommitted;
        emit TerminalReleaseCommitted(taskId, c.allocationId);
    }

    function _commitRelease(bytes32 taskId) private {
        Outcome storage o = _s().outcomes[taskId];
        if (o.status == HookStatus.ReleaseCommitted) return;
        if (o.status != HookStatus.Committed && o.status != HookStatus.CompletionCommitted) {
            revert CommitmentWrongStatus(taskId, o.status);
        }
        o.status = HookStatus.ReleaseCommitted;
        emit TerminalReleaseCommitted(taskId, _s().commitments[taskId].allocationId);
    }

    function _nativePayoutPool(bytes32 taskId, bytes4 mode, uint256 reward, uint256 evaluatorFeeBps)
        private
        view
        returns (uint256)
    {
        uint256 base = mode == TMP_AUCTION ? ITMPCore(diamond).getTask(taskId).stakeAmount : reward;
        return base - Math.mulDiv(base, evaluatorFeeBps, 10_000);
    }

    function _validateFundingRequest(FundingRequest memory request) private view {
        if (
            request.remoteChainId == 0 || request.remoteChainId == block.chainid || request.vault == address(0)
                || request.vaultId == bytes32(0) || request.token == address(0) || request.grossAmount == 0
                || request.epoch == 0 || request.feeBps > 10_000 || request.taskTermsHash == bytes32(0)
                || (request.feeBps != 0 && request.feeRecipient == address(0))
        ) revert InvalidFundingRequest();
    }

    function _commitmentKey(uint256 remoteChainId, address vault, uint64 commitmentNonce)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(remoteChainId, vault, commitmentNonce));
    }

    function _requireCommitment(bytes32 taskId) private view returns (Commitment storage c) {
        if (_s().outcomes[taskId].status == HookStatus.None) revert CommitmentNotFound(taskId);
        return _s().commitments[taskId];
    }

    function _requireMatchingCommitment(bytes32 taskId, ITMPCore.TaskContext calldata ctx) private view {
        Commitment storage c = _requireCommitment(taskId);
        if (ctx.taskId != taskId || ctx.requester != c.manager) revert InvalidHookContext(taskId);
    }

    /// @dev The same inline terms hash as `SponsoredTaskHook._currentTermsHash`; see its comment on
    ///      why this is inlined rather than a library call.
    function _currentTermsHash(bytes32 taskId, ITMPCore.TaskContext memory ctx) private view returns (bytes32) {
        ITMPDiamond market = ITMPDiamond(diamond);
        ITMPCore.Task memory task = market.getTask(taskId);
        ITMPCore.TaskMetadata memory metadata = market.getTaskMetadata(taskId);
        ITMPCore.TaskEvaluatorConfig memory evaluator = market.getTaskEvaluatorConfig(taskId);
        ITMPCore.TaskAuctionConfig memory auction = market.getTaskAuctionConfig(taskId);
        ITMPCore.TaskPitchConfig memory pitch = market.getTaskPitchConfig(taskId);
        address[] memory hooks = market.getTaskHooks(taskId);

        if (
            task.id != taskId || ctx.taskId != taskId || task.requester != ctx.requester || task.reward != ctx.reward
                || task.mode != ctx.mode || task.expiryTime < metadata.createdAt
                || (pitch.pitchDeadline != 0 && pitch.pitchDeadline < metadata.createdAt)
                || (auction.bidDeadline != 0 && auction.bidDeadline < metadata.createdAt)
        ) revert SponsoredTaskTerms.InvalidTaskContext(taskId);

        SponsoredTaskTerms.Terms memory terms = SponsoredTaskTerms.Terms({
            reward: task.reward,
            duration: task.expiryTime - metadata.createdAt,
            mode: task.mode,
            pitchDuration: pitch.pitchDeadline == 0 ? 0 : pitch.pitchDeadline - metadata.createdAt,
            bidDuration: auction.bidDeadline == 0 ? 0 : auction.bidDeadline - metadata.createdAt,
            auctionSubtype: auction.auctionSubtype,
            stakeRequired: task.stakeRequired,
            stakeBps: task.stakeBps,
            feeBps: task.feeBps,
            evaluator: evaluator.evaluator,
            evaluatorStake: evaluator.evaluatorStake,
            evaluatorFeeBps: evaluator.evaluatorFeeBps,
            evaluationWindow: evaluator.evaluationWindow,
            appealWindow: evaluator.appealWindow,
            disputeResolver: evaluator.disputeResolver,
            contentHash: metadata.contentHash,
            contentURIHash: keccak256(bytes(metadata.contentURI)),
            tagsHash: keccak256(abi.encode(ctx.tags)),
            hooksHash: keccak256(abi.encode(hooks))
        });
        return keccak256(abi.encode(SponsoredTaskTerms.TASK_TERMS_TYPEHASH, terms));
    }
}
