// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    Ownable2StepUpgradeable
} from "openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import { OwnableUpgradeable } from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ITMPCore } from "../../interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../../interfaces/ITMPDiamond.sol";
import { ITMPProject } from "../../interfaces/ITMPProject.sol";
import { TMP_AUCTION } from "../../interfaces/ITMPModes.sol";
import { BaseTMPHookV2 } from "../base/BaseTMPHookV2.sol";
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
///      Creating a task charges no fee; the one-time fee is paid when the remote vault is created.
///
///      UUPS-upgradeable with fixed-slot storage, the same pattern `SponsoredTaskHook` uses.
/// @dev rev028 Task Hook V2 port of RemoteSponsoredTaskHook, deployed beside it. Every task created
///      after the rev028 cut is a V2 task, so new cross-chain sponsored tasks attach this hook;
///      tasks created before the cut keep the V1 hook. Behaviour is the V1 hook's, reached through
///      the V2 callbacks at the end of this file. Its configuration is the V1 hookData unchanged.
contract RemoteSponsoredTaskHookV2 is BaseTMPHookV2, ReentrancyGuard, Ownable2StepUpgradeable, UUPSUpgradeable {
    uint8 public constant HOOK_DATA_VERSION = 1;
    /// @dev Same gas-safety bound as `SponsoredTaskHook.MAX_AWARDS`: the completion commitment loops
    ///      over awards inside the Diamond's fixed hook gas stipend.
    uint32 public constant MAX_AWARDS = 8;
    /// @notice How long after the task's expiry an unsettled reservation may be released.
    uint256 public constant RESERVATION_RELEASE_GRACE = 7 days;

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
        /// @dev Rev028: the task's requester of record. `manager` is the account the remote vault
        ///      charges, which differs from it for a project task an operator created. Appended last.
        address requester;
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

    bytes32 private constant HOOK_STORAGE_SLOT = keccak256("taskmarket.remotesponsoredtaskhookv2.storage.v1");

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

    error OwnershipRenunciationDisabled();
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

    constructor(address taskmarket_) BaseTMPHookV2(taskmarket_) {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner { }

    /// @dev Ownership moves in two steps and is never renounced: a one-step transfer to a wrong
    ///      address, or a renounce, would permanently lose upgrade authority.
    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice The remote allocation id for a task: one task maps to one allocation.
    function allocationIdFor(uint256 taskChainId, bytes32 taskId) public pure returns (bytes32) {
        return keccak256(abi.encode(taskChainId, taskId));
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
    ///         the task's expiry.
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
        if (task.id != taskId || task.requester != _requesterOf(c)) revert InvalidHookContext(taskId);

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

        // An accepted task with no completion commitment, in any mode (a verdict finalized after
        // expiry skips the check hooks): commit what checkComplete would have committed. A stored
        // evaluator verdict is used as issued; an auction with none pays its sole worker the
        // accepted price. Any other mode with no verdict has nothing to rebuild.
        if (o.status == HookStatus.Committed) {
            ITMPCore.Verdict memory verdict = ITMPDiamond(diamond).getTaskVerdict(taskId);
            if (!verdict.issued && (task.mode != TMP_AUCTION || task.worker == address(0))) {
                revert AwardsRequired(taskId);
            }
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

    function _checkFund(bytes32 taskId, ITMPCore.TaskContext memory ctx, bytes memory hookData)
        internal
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

        _recordCommitment(taskId, _chargedManager(taskId, ctx.requester), request);
        _s().commitments[taskId].requester = ctx.requester;
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
            termsHash: request.taskTermsHash,
            requester: address(0) // set by _checkFund; see Commitment.requester
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

    function _checkComplete(bytes32 taskId, ITMPCore.TaskContext memory ctx, ITMPCore.Verdict memory verdict)
        internal
        returns (bool)
    {
        _requireMatchingCommitment(taskId, ctx);
        _commitCompletion(taskId, ctx, verdict);
        return true;
    }

    function _checkEvaluate(bytes32 taskId, ITMPCore.TaskContext memory ctx, address) internal view returns (bool) {
        _requireMatchingCommitment(taskId, ctx);
        HookStatus status = _s().outcomes[taskId].status;
        if (status != HookStatus.Committed) revert CommitmentWrongStatus(taskId, status);
        return true;
    }

    function _onComplete(bytes32 taskId, ITMPCore.TaskContext memory ctx, ITMPCore.Verdict memory verdict) internal {
        Commitment storage c = _s().commitments[taskId];
        if (c.manager == address(0) || _requesterOf(c) != ctx.requester) return;
        if (_s().outcomes[taskId].status == HookStatus.Committed) _commitCompletion(taskId, ctx, verdict);
    }

    function _onCancel(bytes32 taskId, ITMPCore.TaskContext memory ctx) internal {
        _tryCommitRelease(taskId, ctx, ITMPCore.TaskStatus.Cancelled);
    }

    function _onExpire(bytes32 taskId, ITMPCore.TaskContext memory ctx) internal {
        _tryCommitRelease(taskId, ctx, ITMPCore.TaskStatus.Expired);
    }

    function _onForfeit(bytes32 taskId, ITMPCore.TaskContext memory ctx, address worker) internal {
        Commitment storage c = _s().commitments[taskId];
        if (_s().outcomes[taskId].status != HookStatus.Committed || _requesterOf(c) != ctx.requester) return;
        emit ForfeitReservationRetained(taskId, c.allocationId, worker);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _commitCompletion(bytes32 taskId, ITMPCore.TaskContext memory ctx, ITMPCore.Verdict memory verdict)
        private
    {
        if (!verdict.issued) revert VerdictNotIssued();
        Outcome storage o = _s().outcomes[taskId];
        // The count guard runs before the payout pool is read, so an oversized verdict marks the
        // sponsorship unsettleable without spending more of the hook's gas first.
        if (o.status == HookStatus.AwardCountExceeded) return;
        if (o.status == HookStatus.Committed && verdict.awards.length > MAX_AWARDS) {
            o.status = HookStatus.AwardCountExceeded;
            emit SponsoredTaskUnsettleableAwardCount(
                taskId, _s().commitments[taskId].allocationId, verdict.awards.length
            );
            return;
        }
        uint256 pool = _nativePayoutPool(taskId, ctx.mode, ctx.reward, ctx.evaluatorFeeBps);
        ITMPCore.Award[] memory awards = verdict.awards;
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

    function _tryCommitRelease(bytes32 taskId, ITMPCore.TaskContext memory ctx, ITMPCore.TaskStatus expected) private {
        Commitment storage c = _s().commitments[taskId];
        if (c.manager == address(0) || _requesterOf(c) != ctx.requester || ctx.taskId != taskId) return;
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

    function _requireMatchingCommitment(bytes32 taskId, ITMPCore.TaskContext memory ctx) private view {
        Commitment storage c = _requireCommitment(taskId);
        if (ctx.taskId != taskId || ctx.requester != _requesterOf(c)) revert InvalidHookContext(taskId);
    }

    /// @dev The task's requester of record; `manager` is who the remote vault charges.
    function _requesterOf(Commitment storage c) private view returns (address) {
        address requester = c.requester;
        return requester == address(0) ? c.manager : requester;
    }

    /// @dev Who a funded task charges: the account that actually created it.
    function _chargedManager(bytes32 taskId, address requester) private view returns (address) {
        try ITMPProject(diamond).taskCreatedBy(taskId) returns (address creator) {
            return creator == address(0) ? requester : creator;
        } catch {
            return requester;
        }
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
        return keccak256(
            abi.encode(
                SponsoredTaskTerms.TERMS_HASH_TYPEHASH,
                keccak256(abi.encode(SponsoredTaskTerms.TASK_TERMS_TYPEHASH, terms)),
                _settlementTermsHash(market, taskId)
            )
        );
    }

    /// @dev The second half of the terms commitment: the task's settlement policy as stored by the
    ///      Diamond. See `SponsoredTaskTerms.SETTLEMENT_TERMS_TYPEHASH`.
    function _settlementTermsHash(ITMPDiamond market, bytes32 taskId) private view returns (bytes32) {
        ITMPCore.TaskTerms memory t = market.getTaskTerms(taskId);
        SponsoredTaskTerms.SettlementTerms memory settlement = SponsoredTaskTerms.SettlementTerms({
            penaltyTo: uint8(t.penaltyTo),
            reviewWindowSecs: t.reviewWindowSecs,
            decisionWindowSecs: t.decisionWindowSecs,
            reopenExtensionSecs: t.reopenExtensionSecs,
            releaseAllowed: uint8(t.releaseAllowed),
            releaseGraceBps: t.releaseGraceBps,
            rejectOutcome: uint8(t.rejectOutcome),
            rejectFeeBps: t.rejectFeeBps,
            maxRevisions: t.maxRevisions,
            resolutionWindowSecs: t.resolutionWindowSecs,
            acceptWindowSecs: t.acceptWindowSecs
        });
        return keccak256(abi.encode(SponsoredTaskTerms.SETTLEMENT_TERMS_TYPEHASH, settlement));
    }

    // -------------------------------------------------------------------------
    // rev028 Task Hook V2 callbacks
    // -------------------------------------------------------------------------

    /// @notice beforeCreate (0), beforeEvaluate (11), beforeAccept (13), afterComplete (21),
    ///         afterCancel (22), afterExpire (23), afterForfeit (24). No result power.
    uint32 public constant CAPABILITIES = (uint32(1) << 0) | (uint32(1) << 11) | (uint32(1) << 13) | (uint32(1) << 21)
        | (uint32(1) << 22) | (uint32(1) << 23) | (uint32(1) << 24);

    function hookCapabilities() external pure override returns (uint32) {
        return CAPABILITIES;
    }

    /// @dev V1 checkFund: `config` is the V1 hookData.
    function beforeCreate(bytes32 taskId, TaskContextV2 calldata ctx, bytes calldata config, bytes calldata)
        external
        override
        onlyDiamond
        returns (bytes4)
    {
        _checkFund(taskId, _v1(taskId, ctx), config);
        return this.beforeCreate.selector;
    }

    /// @dev V1 checkEvaluate.
    function beforeEvaluate(bytes32 taskId, TaskContextV2 calldata ctx, ITMPCore.Verdict calldata, bytes calldata)
        external
        view
        override
        onlyDiamond
        returns (bytes4)
    {
        _checkEvaluate(taskId, _v1(taskId, ctx), ctx.actor);
        return this.beforeEvaluate.selector;
    }

    /// @dev V1 checkComplete. Also called, best effort, on dispute resolution and after expiry.
    function beforeAccept(bytes32 taskId, TaskContextV2 calldata ctx, ITMPCore.Verdict calldata verdict, bytes calldata)
        external
        override
        onlyDiamond
        returns (bytes4, SettlementDelta memory, ITMPCore.Award[] memory)
    {
        _checkComplete(taskId, _v1(taskId, ctx), verdict);
        return _allowAccept();
    }

    /// @dev V1 onComplete, with the diamond's verdict or the single award a single-payee settlement
    ///      pays (afterComplete carries no verdict).
    function afterComplete(bytes32 taskId, TaskContextV2 calldata ctx, SettlementAmounts calldata, uint64)
        external
        override
        onlyDiamond
    {
        _onComplete(taskId, _v1(taskId, ctx), _settledVerdict(taskId));
    }

    function afterCancel(bytes32 taskId, TaskContextV2 calldata ctx, SettlementAmounts calldata, uint64)
        external
        override
        onlyDiamond
    {
        _onCancel(taskId, _v1(taskId, ctx));
    }

    function afterExpire(bytes32 taskId, TaskContextV2 calldata ctx, SettlementAmounts calldata, uint64)
        external
        override
        onlyDiamond
    {
        _onExpire(taskId, _v1(taskId, ctx));
    }

    function afterForfeit(bytes32 taskId, TaskContextV2 calldata ctx, SettlementAmounts calldata, uint64)
        external
        override
        onlyDiamond
    {
        _onForfeit(taskId, _v1(taskId, ctx), ctx.worker);
    }

    function _v1(bytes32 taskId, TaskContextV2 calldata ctx) private view returns (ITMPCore.TaskContext memory c) {
        c = ITMPDiamond(diamond).getTaskContext(taskId);
        c.currentState = ctx.currentState;
    }

    function _settledVerdict(bytes32 taskId) private view returns (ITMPCore.Verdict memory v) {
        v = ITMPDiamond(diamond).getTaskVerdict(taskId);
        if (v.issued) return v;
        ITMPCore.Task memory task = ITMPCore(diamond).getTask(taskId);
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({
            worker: task.worker, amount: task.mode == TMP_AUCTION ? task.stakeAmount : task.reward, rank: 1
        });
        v.issued = true;
        v.verdictType = ITMPCore.VerdictType.APPROVE;
        v.score = 1000;
        v.confidence = 1000;
        v.awards = awards;
    }
}
