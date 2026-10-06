// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { OwnableUpgradeable } from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ITMPCore } from "../../interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../../interfaces/ITMPDiamond.sol";
import { TMP_AUCTION } from "../../interfaces/ITMPModes.sol";
import { BaseTMPHook } from "../base/BaseTMPHook.sol";
import { SponsoredTaskTypes } from "./SponsoredTaskTypes.sol";
import { ISponsoredTasksVault } from "./interfaces/ISponsoredTasksVault.sol";
import { ISponsoredTaskFeeBank } from "./interfaces/ISponsoredTaskFeeBank.sol";
import { ISponsoredTaskRegistry } from "./interfaces/ISponsoredTaskRegistry.sol";
import { SponsoredTaskSettlement } from "./libraries/SponsoredTaskSettlement.sol";
import { SponsoredTaskTerms } from "./libraries/SponsoredTaskTerms.sol";

/// @title SponsoredTaskHook
/// @notice Binds a fixed vault-token allocation to a Taskmarket task on Base.
/// @dev Mandatory Taskmarket callbacks only reserve funds and commit compact outcome data.
///      Settlement installation remains a permissionless, resumable operation outside the hook gas
///      boundary. Taskmarket's independent USDC payout is never transferred by this contract.
///
///      V1 is Base-local only. This is the single canonical, protocol-owned deployment of this
///      hook -- UUPS-upgradeable so an in-place logic fix can ship without redeploying, the same
///      pattern already used by this protocol's default token reward hook. Vaults it talks
///      to are immutable EIP-1167 clones; this hook holds no upgrade authority over a vault
///      owner's tokens.
contract SponsoredTaskHook is BaseTMPHook, ReentrancyGuard, OwnableUpgradeable, UUPSUpgradeable {
    using Math for uint256;

    uint8 public constant HOOK_DATA_VERSION = 1;
    uint8 public constant ROUTE_BASE_LOCAL = 0;
    /// @dev Gas-safety threshold, not a product cap: `_commitCompletion` loops over awards to build
    /// `awardsDigest` inside the mandatory `checkComplete` callback, under the Diamond's fixed
    /// 1,000,000 gas hook stipend. Above this count, the sponsor reservation is released and the
    /// allocation is marked unsettleable rather than risking out-of-gas -- Taskmarket's own USDC
    /// settlement is never blocked by this hook. Shared ceiling with Taskmarket's default
    /// TaskTokenRewardHook: live-fork measurements with aged wallets and claimable writes used
    /// ~754k gas on Base Mainnet and ~765k on Base Sepolia for eight awards, leaving ~22% headroom.
    uint32 public constant MAX_AWARDS = 8;

    enum HookStatus {
        None,
        Reserved,
        CompletionCommitted,
        ReleaseCommitted,
        SettlementPrepared,
        Released,
        DefaultedByOwner,
        AwardCountExceeded
    }

    struct FundingRequest {
        uint8 route;
        address vault;
        bytes32 vaultId;
        bytes32 allocationId;
        uint64 epoch;
        uint16 feeBps;
        address feeRecipient;
        uint256 grossAmount;
        bytes32 taskTermsHash;
    }

    struct TaskAllocation {
        uint8 route;
        address vault;
        bytes32 vaultId;
        bytes32 allocationId;
        address manager;
        uint64 epoch;
        uint16 feeBps;
        address feeRecipient;
        uint256 grossAmount;
        uint256 nativePayoutPool;
        ITMPCore.VerdictType verdictType;
        bytes32 awardsDigest;
        uint32 awardCount;
        bytes32 rewardsRoot;
        uint32 leafCount;
        uint256 sponsoredTaskTotal;
        uint256 feeTotal;
        uint256 distributedGross;
        HookStatus status;
    }

    IERC20 public immutable usdc;
    ISponsoredTaskFeeBank public immutable feeBank;
    ISponsoredTaskRegistry public immutable registry;

    /// @dev Fixed-slot storage, the same pattern `TaskTokenRewardHook` uses and the Diamond's own
    ///      `AppStorage` established: this contract sits behind a proxy, so ordinary sequential
    ///      state variables would have their slots repointed by any later insertion above them.
    ///      Fields must only ever be APPENDED, never inserted, reordered, or removed.
    struct HookStorage {
        mapping(bytes32 taskId => TaskAllocation allocation) taskAllocations;
        mapping(address vault => mapping(bytes32 allocationId => bytes32 taskId)) taskByAllocation;
    }

    bytes32 private constant HOOK_STORAGE_SLOT = keccak256("taskmarket.sponsoredtaskhook.storage.v1");

    function _s() private pure returns (HookStorage storage hs) {
        bytes32 slot = HOOK_STORAGE_SLOT;
        assembly {
            hs.slot := slot
        }
    }

    error ZeroAddress();
    error InvalidContract(address account);
    error InvalidHookDataVersion(uint8 version);
    error InvalidRoute(uint8 route);
    error InvalidHookContext(bytes32 taskId);
    error InvalidFundingRequest();
    error WrongPaymentToken(address expected, address actual);
    error AllocationAlreadyExists(bytes32 taskId);
    error AllocationNotFound(bytes32 taskId);
    error AllocationBindingConflict(address vault, bytes32 allocationId, bytes32 taskId);
    error AllocationWrongStatus(bytes32 taskId, HookStatus status);
    error VaultMismatch();
    error VaultExited(bytes32 vaultId, uint64 epoch);
    error TaskTermsMismatch(bytes32 expected, bytes32 actual);
    error TaskNotTerminal(bytes32 taskId, ITMPCore.TaskStatus status);
    error VerdictNotIssued();
    error VerdictCommitmentMismatch(bytes32 taskId);
    error AwardsRequired(bytes32 taskId);
    error SettlementMismatch(bytes32 taskId);

    event SponsoredTaskFunded(
        bytes32 indexed taskId,
        bytes32 indexed vaultId,
        bytes32 indexed allocationId,
        address vault,
        address manager,
        uint8 route,
        uint64 epoch,
        uint256 grossAmount,
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
        uint8 route
    );
    event ReservationReleased(bytes32 indexed taskId, bytes32 indexed allocationId, uint8 route);
    event SponsoredTaskDefaultedByOwner(bytes32 indexed taskId, bytes32 indexed vaultId, bytes32 indexed allocationId);
    event SponsoredTaskUnsettleableAwardCount(bytes32 indexed taskId, bytes32 indexed allocationId, uint256 awardCount);

    /// @dev Immutable dependencies are fixed for the life of this implementation contract and are
    ///      shared by every proxy that ever points at it -- correct only because there is exactly
    ///      one canonical deployment of this hook. `_disableInitializers` prevents anyone from
    ///      calling `initialize` directly on the implementation, per the same pattern documented
    ///      on `TaskTokenRewardHook`.
    constructor(address taskmarket_, IERC20 usdc_, ISponsoredTaskFeeBank feeBank_, ISponsoredTaskRegistry registry_)
        BaseTMPHook(taskmarket_)
    {
        if (address(usdc_) == address(0) || address(feeBank_) == address(0) || address(registry_) == address(0)) {
            revert ZeroAddress();
        }
        if (address(usdc_).code.length == 0) revert InvalidContract(address(usdc_));
        if (address(feeBank_).code.length == 0) revert InvalidContract(address(feeBank_));
        if (address(registry_).code.length == 0) revert InvalidContract(address(registry_));
        if (address(feeBank_.feeToken()) != address(usdc_)) {
            revert WrongPaymentToken(address(usdc_), address(feeBank_.feeToken()));
        }
        usdc = usdc_;
        feeBank = feeBank_;
        registry = registry_;
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner { }

    /// @dev Split into two getters rather than one returning the full 19-field `TaskAllocation`
    ///      -- a single external function returning the whole struct trips `forge coverage
    ///      --ir-minimum`'s stack-too-deep limit purely on its own ABI-encoded return (the
    ///      unoptimized encoder cannot pack that many fields into available stack slots), a
    ///      failure this repo has already hit once for this exact struct (see
    ///      `_recordAllocation`'s own doc comment) but never before for a *return value* rather
    ///      than a local. Callers needing the full allocation combine both.
    function taskAllocationFunding(bytes32 taskId)
        external
        view
        returns (
            uint8 route,
            address vault,
            bytes32 vaultId,
            bytes32 allocationId,
            address manager,
            uint64 epoch,
            uint16 feeBps,
            address feeRecipient,
            uint256 grossAmount,
            uint256 nativePayoutPool
        )
    {
        TaskAllocation storage a = _s().taskAllocations[taskId];
        return (
            a.route,
            a.vault,
            a.vaultId,
            a.allocationId,
            a.manager,
            a.epoch,
            a.feeBps,
            a.feeRecipient,
            a.grossAmount,
            a.nativePayoutPool
        );
    }

    function taskAllocationSettlement(bytes32 taskId)
        external
        view
        returns (
            ITMPCore.VerdictType verdictType,
            bytes32 awardsDigest,
            uint32 awardCount,
            bytes32 rewardsRoot,
            uint32 leafCount,
            uint256 sponsoredTaskTotal,
            uint256 feeTotal,
            uint256 distributedGross,
            HookStatus status
        )
    {
        TaskAllocation storage a = _s().taskAllocations[taskId];
        return (
            a.verdictType,
            a.awardsDigest,
            a.awardCount,
            a.rewardsRoot,
            a.leafCount,
            a.sponsoredTaskTotal,
            a.feeTotal,
            a.distributedGross,
            a.status
        );
    }

    function taskByAllocation(address vault, bytes32 allocationId) external view returns (bytes32) {
        return _s().taskByAllocation[vault][allocationId];
    }

    function encodeHookData(FundingRequest calldata request) external pure returns (bytes memory) {
        return abi.encode(HOOK_DATA_VERSION, request);
    }

    function currentTaskTermsHash(bytes32 taskId) external view returns (bytes32) {
        ITMPCore.TaskContext memory context = ITMPDiamond(diamond).getTaskContext(taskId);
        return _currentTermsHash(taskId, context);
    }

    /// @notice Permissionlessly installs or queues the committed multi-winner settlement.
    function finalizeSettlement(bytes32 taskId, ITMPCore.Award[] calldata awards)
        external
        nonReentrant
        returns (bytes32 rewardsRoot)
    {
        TaskAllocation storage allocation = _requireAllocation(taskId);
        ITMPCore.Award[] memory awardsMemory = awards;
        rewardsRoot = _finalizeSettlement(taskId, allocation, awardsMemory);
    }

    /// @notice Permissionlessly resolves a terminal cancellation or expiry after a missed callback.
    function finalizeRelease(bytes32 taskId) external nonReentrant returns (HookStatus) {
        TaskAllocation storage allocation = _requireAllocation(taskId);
        ITMPCore.Task memory task = ITMPCore(diamond).getTask(taskId);
        if (task.status != ITMPCore.TaskStatus.Cancelled && task.status != ITMPCore.TaskStatus.Expired) {
            revert TaskNotTerminal(taskId, task.status);
        }
        if (allocation.status == HookStatus.Reserved) allocation.status = HookStatus.ReleaseCommitted;
        _executeRelease(taskId, allocation);
        return allocation.status;
    }

    /// @notice Repairs a swallowed after-hook using Taskmarket's authoritative terminal state.
    /// @dev Evaluator verdicts are persisted and can be finalized here. Manual split awards must be
    ///      supplied to `finalizeSettlement`; their mandatory checkComplete commitment proves them.
    function reconcile(bytes32 taskId) external nonReentrant returns (HookStatus) {
        TaskAllocation storage allocation = _requireAllocation(taskId);
        if (
            allocation.status == HookStatus.SettlementPrepared || allocation.status == HookStatus.Released
                || allocation.status == HookStatus.DefaultedByOwner
                || allocation.status == HookStatus.AwardCountExceeded
        ) return allocation.status;

        ITMPCore.Task memory task = ITMPCore(diamond).getTask(taskId);
        if (task.id != taskId || task.requester != allocation.manager) revert InvalidHookContext(taskId);

        if (task.status == ITMPCore.TaskStatus.Cancelled || task.status == ITMPCore.TaskStatus.Expired) {
            if (allocation.status == HookStatus.Reserved) allocation.status = HookStatus.ReleaseCommitted;
            _executeRelease(taskId, allocation);
            return allocation.status;
        }
        if (task.status != ITMPCore.TaskStatus.Accepted) revert TaskNotTerminal(taskId, task.status);

        if (allocation.status == HookStatus.CompletionCommitted) {
            HookStatus settled = _reconcileCommittedCompletion(taskId, allocation);
            if (settled != HookStatus.CompletionCommitted) return settled;
        }

        // The only current Taskmarket path that can accept without checkComplete is the auction
        // expiry auto-payment. Its sole worker and actual winning price remain reconstructible.
        if (allocation.status == HookStatus.Reserved && task.mode == TMP_AUCTION && task.worker != address(0)) {
            ITMPCore.Award[] memory auctionAwards = new ITMPCore.Award[](1);
            auctionAwards[0] = ITMPCore.Award({ worker: task.worker, amount: task.stakeAmount, rank: 1 });
            _commitCompletionMemory(taskId, allocation, ITMPCore.VerdictType.APPROVE, auctionAwards, task.reward, 0);
            _finalizeSettlement(taskId, allocation, auctionAwards);
            return allocation.status;
        }

        revert AwardsRequired(taskId);
    }

    /// @notice Updates local discovery state after an owner emergency exit.
    function refreshOwnerDefault(bytes32 taskId) external returns (bool changed) {
        TaskAllocation storage allocation = _requireAllocation(taskId);
        if (allocation.route != ROUTE_BASE_LOCAL) return false;
        if (allocation.status == HookStatus.Released || allocation.status == HookStatus.DefaultedByOwner) return false;
        ISponsoredTasksVault vault = ISponsoredTasksVault(allocation.vault);
        if (
            vault.effectiveAllocationStatus(allocation.allocationId)
                != SponsoredTaskTypes.AllocationStatus.DefaultedByOwner
        ) {
            return false;
        }
        allocation.status = HookStatus.DefaultedByOwner;
        emit SponsoredTaskDefaultedByOwner(taskId, allocation.vaultId, allocation.allocationId);
        return true;
    }

    function _checkFund(bytes32 taskId, ITMPCore.TaskContext calldata ctx, bytes calldata hookData)
        internal
        override
        returns (bool)
    {
        if (
            taskId == bytes32(0) || taskId != ctx.taskId || ctx.requester == address(0) || ctx.reward == 0
                || ctx.currentState != ITMPCore.TaskStatus.Open
        ) revert InvalidHookContext(taskId);
        if (ctx.paymentToken != address(usdc)) revert WrongPaymentToken(address(usdc), ctx.paymentToken);
        if (_s().taskAllocations[taskId].status != HookStatus.None) revert AllocationAlreadyExists(taskId);

        (uint8 version, FundingRequest memory request) = abi.decode(hookData, (uint8, FundingRequest));
        if (version != HOOK_DATA_VERSION) revert InvalidHookDataVersion(version);
        _validateFundingRequest(request);

        bytes32 termsHash = _currentTermsHash(taskId, ctx);
        if (request.taskTermsHash != termsHash) revert TaskTermsMismatch(request.taskTermsHash, termsHash);

        if (request.allocationId != bytes32(0)) revert InvalidFundingRequest();
        bytes32 allocationId = taskId;
        _reserveLocal(taskId, ctx.requester, request, termsHash);

        bytes32 existingTask = _s().taskByAllocation[request.vault][allocationId];
        if (existingTask != bytes32(0)) {
            revert AllocationBindingConflict(request.vault, allocationId, existingTask);
        }

        // Charge in the same transaction as Taskmarket creation. Any later revert rolls this back.
        // The receipt is only useful to a caller wanting the recorded values -- charge() reverts
        // on every real failure (InsufficientCredit etc.), so success never needs checking here.
        // slither-disable-next-line unused-return
        feeBank.charge(ctx.requester, taskId);

        _recordAllocation(taskId, allocationId, ctx.requester, request, termsHash);
        return true;
    }

    /// @dev Split out of `_checkFund` so the 19-field `TaskAllocation` struct literal doesn't
    ///      share a stack frame with `_checkFund`'s other locals -- the combined version tripped
    ///      `forge coverage --ir-minimum`'s stack-too-deep limit (unoptimized IR keeps every
    ///      local live, unlike the default optimized build).
    function _recordAllocation(
        bytes32 taskId,
        bytes32 allocationId,
        address manager,
        FundingRequest memory request,
        bytes32 termsHash
    ) private {
        _s().taskAllocations[taskId] = TaskAllocation({
            route: request.route,
            vault: request.vault,
            vaultId: request.vaultId,
            allocationId: allocationId,
            manager: manager,
            epoch: request.epoch,
            feeBps: request.feeBps,
            feeRecipient: request.feeRecipient,
            grossAmount: request.grossAmount,
            nativePayoutPool: 0,
            verdictType: ITMPCore.VerdictType.APPROVE,
            awardsDigest: bytes32(0),
            awardCount: 0,
            rewardsRoot: bytes32(0),
            leafCount: 0,
            sponsoredTaskTotal: 0,
            feeTotal: 0,
            distributedGross: 0,
            status: HookStatus.Reserved
        });
        _s().taskByAllocation[request.vault][allocationId] = taskId;

        emit SponsoredTaskFunded(
            taskId,
            request.vaultId,
            allocationId,
            request.vault,
            manager,
            request.route,
            request.epoch,
            request.grossAmount,
            request.feeBps,
            request.feeRecipient,
            termsHash
        );
    }

    function _checkComplete(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.Verdict calldata verdict)
        internal
        override
        returns (bool)
    {
        TaskAllocation storage allocation = _requireMatchingAllocation(taskId, ctx);
        // A full owner exit terminates only the project-token sponsor. Once its default has been
        // reflected locally, this mandatory hook must not block Taskmarket's independent USDC rail.
        if (allocation.status == HookStatus.DefaultedByOwner) return true;
        _commitCompletion(taskId, allocation, ctx, verdict);
        return true;
    }

    /// @dev Award-count overflow is handled at the mandatory completion boundary (`_commitCompletion`),
    ///      which releases the sponsor reservation and marks it unsettleable rather than reverting
    ///      `evaluate()` -- Taskmarket's own USDC lifecycle must never be blocked by this hook.
    function _checkEvaluate(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address)
        internal
        view
        override
        returns (bool)
    {
        TaskAllocation storage allocation = _requireMatchingAllocation(taskId, ctx);
        // Evaluation is part of Taskmarket's independent USDC lifecycle. There is no sponsor award
        // commitment left to protect after the owner has terminally defaulted the vault.
        if (allocation.status == HookStatus.DefaultedByOwner) return true;
        if (allocation.status != HookStatus.Reserved) revert AllocationWrongStatus(taskId, allocation.status);
        return true;
    }

    function _onComplete(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.Verdict calldata verdict)
        internal
        override
    {
        TaskAllocation storage allocation = _s().taskAllocations[taskId];
        if (allocation.status == HookStatus.None || allocation.manager != ctx.requester) return;
        if (allocation.status == HookStatus.Reserved) _commitCompletion(taskId, allocation, ctx, verdict);
    }

    function _onCancel(bytes32 taskId, ITMPCore.TaskContext calldata ctx) internal override {
        _commitAndTryRelease(taskId, ctx, ITMPCore.TaskStatus.Cancelled);
    }

    function _onExpire(bytes32 taskId, ITMPCore.TaskContext calldata ctx) internal override {
        _commitAndTryRelease(taskId, ctx, ITMPCore.TaskStatus.Expired);
    }

    function _onForfeit(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker) internal override {
        TaskAllocation storage allocation = _s().taskAllocations[taskId];
        if (allocation.status != HookStatus.Reserved || allocation.manager != ctx.requester) return;
        emit ForfeitReservationRetained(taskId, allocation.allocationId, worker);
    }

    function _commitCompletion(
        bytes32 taskId,
        TaskAllocation storage allocation,
        ITMPCore.TaskContext calldata ctx,
        ITMPCore.Verdict calldata verdict
    ) private {
        if (!verdict.issued) revert VerdictNotIssued();
        uint256 payoutPool = ctx.reward - Math.mulDiv(ctx.reward, ctx.evaluatorFeeBps, 10_000);
        ITMPCore.Award[] memory awards = verdict.awards;
        uint256 count = awards.length;
        if (count > MAX_AWARDS) {
            _releaseForAwardOverflow(taskId, allocation, count);
            return;
        }
        bytes32 digest = SponsoredTaskSettlement.awardsDigestMemory(taskId, verdict.verdictType, awards);

        if (allocation.status == HookStatus.CompletionCommitted) {
            if (
                allocation.verdictType != verdict.verdictType || allocation.awardsDigest != digest
                    || allocation.awardCount != uint32(count) || allocation.nativePayoutPool != payoutPool
            ) revert VerdictCommitmentMismatch(taskId);
            return;
        }
        if (allocation.status != HookStatus.Reserved) revert AllocationWrongStatus(taskId, allocation.status);

        allocation.verdictType = verdict.verdictType;
        allocation.awardsDigest = digest;
        allocation.awardCount = uint32(count);
        allocation.nativePayoutPool = payoutPool;
        allocation.status = HookStatus.CompletionCommitted;
        emit CompletionCommitted(
            taskId, allocation.allocationId, verdict.verdictType, digest, uint32(count), payoutPool
        );
    }

    /// @dev Split out of `reconcile` to stay under `forge coverage --ir-minimum`'s stack limit.
    ///      Requester `acceptSubmission` stores no verdict; its single award is rebuilt from the
    ///      task, and a wrong reconstruction reverts on the commitment digest. Returns the status
    ///      unchanged (`CompletionCommitted`) when nothing could be reconstructed.
    function _reconcileCommittedCompletion(bytes32 taskId, TaskAllocation storage allocation)
        private
        returns (HookStatus)
    {
        ITMPCore.Verdict memory verdict = ITMPDiamond(diamond).getTaskVerdict(taskId);
        ITMPCore.Award[] memory awards = verdict.awards;
        if (!verdict.issued) {
            if (allocation.awardCount != 1) return allocation.status;
            ITMPCore.Task memory task = ITMPCore(diamond).getTask(taskId);
            awards = new ITMPCore.Award[](1);
            awards[0] = ITMPCore.Award({ worker: task.worker, amount: task.reward, rank: 1 });
        }
        _finalizeSettlement(taskId, allocation, awards);
        return allocation.status;
    }

    function _commitCompletionMemory(
        bytes32 taskId,
        TaskAllocation storage allocation,
        ITMPCore.VerdictType verdictType,
        ITMPCore.Award[] memory awards,
        uint256 reward,
        uint16 evaluatorFeeBps
    ) private {
        uint256 count = awards.length;
        // Only ever called from `reconcile`'s auction-expiry path with a single reconstructed
        // award, so `count` can never exceed `MAX_AWARDS` here -- the overflow release path in
        // `_commitCompletion` is what handles evaluator-submitted multi-winner verdicts.
        allocation.verdictType = verdictType;
        allocation.awardsDigest = SponsoredTaskSettlement.awardsDigestMemory(taskId, verdictType, awards);
        allocation.awardCount = uint32(count);
        allocation.nativePayoutPool = reward - Math.mulDiv(reward, evaluatorFeeBps, 10_000);
        allocation.status = HookStatus.CompletionCommitted;
        emit CompletionCommitted(
            taskId,
            allocation.allocationId,
            verdictType,
            allocation.awardsDigest,
            uint32(count),
            allocation.nativePayoutPool
        );
    }

    function _finalizeSettlement(bytes32 taskId, TaskAllocation storage allocation, ITMPCore.Award[] memory awards)
        private
        returns (bytes32 rewardsRoot)
    {
        if (allocation.status == HookStatus.DefaultedByOwner || allocation.status == HookStatus.AwardCountExceeded) {
            return bytes32(0);
        }
        if (allocation.status == HookStatus.SettlementPrepared) {
            return allocation.rewardsRoot;
        }
        if (allocation.status != HookStatus.CompletionCommitted) {
            revert AllocationWrongStatus(taskId, allocation.status);
        }

        ITMPCore.Task memory task = ITMPCore(diamond).getTask(taskId);
        if (task.status != ITMPCore.TaskStatus.Accepted) revert TaskNotTerminal(taskId, task.status);
        bytes32 suppliedDigest = SponsoredTaskSettlement.awardsDigestMemory(taskId, allocation.verdictType, awards);
        if (suppliedDigest != allocation.awardsDigest || awards.length != allocation.awardCount) {
            revert VerdictCommitmentMismatch(taskId);
        }

        SponsoredTaskSettlement.Result memory result = SponsoredTaskSettlement.calculate(
            SponsoredTaskSettlement.SettlementIdentity({
                vaultId: allocation.vaultId,
                vaultEpoch: allocation.epoch,
                allocationId: allocation.allocationId,
                taskId: taskId
            }),
            allocation.grossAmount,
            allocation.nativePayoutPool,
            allocation.feeBps,
            allocation.verdictType,
            awards
        );

        ISponsoredTasksVault vault = ISponsoredTasksVault(allocation.vault);
        if (vault.status() == SponsoredTaskTypes.VaultStatus.Exited && vault.epoch() != allocation.epoch) {
            allocation.status = HookStatus.DefaultedByOwner;
            emit SponsoredTaskDefaultedByOwner(taskId, allocation.vaultId, allocation.allocationId);
            return bytes32(0);
        }

        return _installSettlementAndEmit(taskId, allocation, vault, result);
    }

    /// @dev Split out of `_finalizeSettlement` so each function holds fewer simultaneously-live
    ///      locals -- the combined version tripped `forge coverage --ir-minimum`'s stack-too-deep
    ///      limit (unoptimized IR keeps every local live, unlike the default optimized build).
    function _installSettlementAndEmit(
        bytes32 taskId,
        TaskAllocation storage allocation,
        ISponsoredTasksVault vault,
        SponsoredTaskSettlement.Result memory result
    ) private returns (bytes32 rewardsRoot) {
        // `changed` is false only when this exact settlement was already installed (idempotent
        // retry) -- installSettlement() reverts on every real conflict, so the flag needs no check.
        // slither-disable-next-line unused-return
        vault.installSettlement(
            allocation.allocationId,
            taskId,
            result.rewardsRoot,
            result.leafCount,
            result.sponsoredTaskTotal,
            result.feeTotal,
            result.distributedGross
        );

        allocation.rewardsRoot = result.rewardsRoot;
        allocation.leafCount = result.leafCount;
        allocation.sponsoredTaskTotal = result.sponsoredTaskTotal;
        allocation.feeTotal = result.feeTotal;
        allocation.distributedGross = result.distributedGross;
        allocation.status = HookStatus.SettlementPrepared;

        uint256 entitlementCount = result.entitlements.length;
        for (uint256 i; i < entitlementCount; ++i) {
            SponsoredTaskSettlement.Entitlement memory entitlement = result.entitlements[i];
            emit SponsoredTaskEntitlement(
                taskId,
                entitlement.leafIndex,
                entitlement.worker,
                entitlement.awardIndex,
                entitlement.grossAmount,
                entitlement.feeAmount,
                entitlement.netAmount,
                entitlement.leaf
            );
        }
        emit SettlementPrepared(
            taskId,
            allocation.allocationId,
            result.rewardsRoot,
            result.leafCount,
            result.sponsoredTaskTotal,
            result.feeTotal,
            result.distributedGross,
            result.releasedGross,
            allocation.route
        );
        return result.rewardsRoot;
    }

    /// @dev Called only from the mandatory `checkComplete` boundary via `_commitCompletion`, so it
    ///      must never revert: an oversized verdict releases the reservation back to `available`
    ///      and marks the sponsor terminally unsettleable, while Taskmarket's own USDC settlement
    ///      proceeds unaffected in the same transaction.
    function _releaseForAwardOverflow(bytes32 taskId, TaskAllocation storage allocation, uint256 count) private {
        if (
            allocation.status == HookStatus.AwardCountExceeded || allocation.status == HookStatus.DefaultedByOwner
                || allocation.status == HookStatus.Released
        ) return;
        if (allocation.status != HookStatus.Reserved) revert AllocationWrongStatus(taskId, allocation.status);

        ISponsoredTasksVault vault = ISponsoredTasksVault(allocation.vault);
        if (vault.status() == SponsoredTaskTypes.VaultStatus.Exited && vault.epoch() != allocation.epoch) {
            allocation.status = HookStatus.DefaultedByOwner;
            emit SponsoredTaskDefaultedByOwner(taskId, allocation.vaultId, allocation.allocationId);
            return;
        }
        // `changed` is false only when this allocation was already released (idempotent retry) --
        // safe to ignore, the caller only needs the release to have happened by return.
        // slither-disable-next-line unused-return
        vault.releaseTask(allocation.allocationId);
        allocation.status = HookStatus.AwardCountExceeded;
        emit SponsoredTaskUnsettleableAwardCount(taskId, allocation.allocationId, count);
    }

    function _commitAndTryRelease(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.TaskStatus expected)
        private
    {
        TaskAllocation storage allocation = _s().taskAllocations[taskId];
        if (
            allocation.status == HookStatus.None || allocation.manager != ctx.requester || ctx.taskId != taskId
                || ctx.currentState != expected
        ) return;
        if (allocation.status == HookStatus.Released || allocation.status == HookStatus.DefaultedByOwner) return;
        if (allocation.status != HookStatus.Reserved && allocation.status != HookStatus.ReleaseCommitted) return;
        allocation.status = HookStatus.ReleaseCommitted;
        emit TerminalReleaseCommitted(taskId, allocation.allocationId);
        _executeRelease(taskId, allocation);
    }

    function _executeRelease(bytes32 taskId, TaskAllocation storage allocation) private {
        if (allocation.status == HookStatus.Released || allocation.status == HookStatus.DefaultedByOwner) return;
        if (allocation.status != HookStatus.ReleaseCommitted) {
            revert AllocationWrongStatus(taskId, allocation.status);
        }

        ISponsoredTasksVault vault = ISponsoredTasksVault(allocation.vault);
        if (vault.status() == SponsoredTaskTypes.VaultStatus.Exited && vault.epoch() != allocation.epoch) {
            allocation.status = HookStatus.DefaultedByOwner;
            emit SponsoredTaskDefaultedByOwner(taskId, allocation.vaultId, allocation.allocationId);
            return;
        }
        // `changed` is false only when this allocation was already released (idempotent retry) --
        // safe to ignore, the caller only needs the release to have happened by return.
        // slither-disable-next-line unused-return
        vault.releaseTask(allocation.allocationId);
        allocation.status = HookStatus.Released;
        emit ReservationReleased(taskId, allocation.allocationId, allocation.route);
    }

    /// @dev Sequential single-condition checks rather than one large OR-chain, and the vault
    ///      re-derived per check rather than held live throughout -- the combined form tripped
    ///      `forge coverage --ir-minimum`'s stack-too-deep limit (unoptimized IR keeps every one
    ///      of six external-call return values plus the request/termsHash locals live at once).
    function _reserveLocal(bytes32 taskId, address manager, FundingRequest memory request, bytes32 termsHash) private {
        if (request.vault.code.length == 0) revert InvalidContract(request.vault);
        _requireMatchingVault(request);
        ISponsoredTasksVault(request.vault)
            .reserveTask(
                taskId,
                taskId,
                manager,
                request.grossAmount,
                request.epoch,
                request.feeBps,
                request.feeRecipient,
                termsHash
            );
    }

    function _requireMatchingVault(FundingRequest memory request) private view {
        if (!registry.isVault(request.vault)) revert VaultMismatch();
        if (registry.vaultIdOf(request.vault) != request.vaultId) revert VaultMismatch();
        ISponsoredTasksVault vault = ISponsoredTasksVault(request.vault);
        if (vault.vaultId() != request.vaultId) revert VaultMismatch();
        if (vault.settlementChain() != block.chainid) revert VaultMismatch();
        if (vault.epoch() != request.epoch) revert VaultMismatch();
        if (vault.status() != SponsoredTaskTypes.VaultStatus.Active) revert VaultMismatch();
        if (vault.controller() != address(this)) revert VaultMismatch();
    }

    function _validateFundingRequest(FundingRequest memory request) private pure {
        if (request.route != ROUTE_BASE_LOCAL) revert InvalidRoute(request.route);
        if (
            request.vault == address(0) || request.vaultId == bytes32(0) || request.epoch == 0
                || request.grossAmount == 0 || request.feeBps > 10_000 || request.taskTermsHash == bytes32(0)
                || (request.feeBps != 0 && request.feeRecipient == address(0))
        ) revert InvalidFundingRequest();
    }

    function _requireAllocation(bytes32 taskId) private view returns (TaskAllocation storage allocation) {
        allocation = _s().taskAllocations[taskId];
        if (allocation.status == HookStatus.None) revert AllocationNotFound(taskId);
    }

    function _requireMatchingAllocation(bytes32 taskId, ITMPCore.TaskContext calldata ctx)
        private
        view
        returns (TaskAllocation storage allocation)
    {
        allocation = _requireAllocation(taskId);
        if (ctx.taskId != taskId || ctx.requester != allocation.manager) revert InvalidHookContext(taskId);
    }

    /// @dev Inlines what `SponsoredTaskTerms.currentHash`/`.hash` used to do, rather than calling
    ///      them as library functions -- an internal call across the library boundary, however
    ///      trivial the callee, tripped `forge coverage --ir-minimum`'s stack-too-deep limit for
    ///      every caller tried (this contract's full hook dispatcher, a bare wrapper with no other
    ///      code, the library's own test contract). Confirmed by isolating the two variants
    ///      against solc directly: swapping only the call-vs-inline boundary was the entire
    ///      difference between crashing and compiling clean. Neither library function exists
    ///      anymore; `test/SponsoredTaskTerms.t.sol`'s pinned cross-language vector check computes
    ///      the same `keccak256(abi.encode(TASK_TERMS_TYPEHASH, terms))` inline too.
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
