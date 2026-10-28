// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ISponsoredTasksVault } from "./interfaces/ISponsoredTasksVault.sol";
import { ISponsoredTaskSettlerAuthority } from "./interfaces/ISponsoredTaskSettlerAuthority.sol";

/// @title SponsoredTaskSettler
/// @notice The controller of a settler-mode `SponsoredTaskFactory` on an EVM chain that does not
///         run the Taskmarket Diamond. The task lives on Base; this contract reserves, releases and
///         settles the task's allocation in the remote vault on the signed word of a settler set.
/// @dev Specified in `docs/specs/sponsored-tasks/evm-attested-settler.md`.
///
///      Every state-changing call is authorized by EIP-712 signatures bound to this chain's id and
///      this contract's address, so anyone may relay it and a signature for one chain or settler
///      never verifies on another. `settle` only stores the award root as pending; `finalize`
///      installs it in the vault once `claimDelaySeconds` has passed, and until then the owner can
///      `revokeSettlement` it. The vault is unchanged: it opens claims the moment
///      `installSettlement` runs, so the delay lives here.
contract SponsoredTaskSettler is EIP712, Ownable2Step, Pausable, ReentrancyGuard {
    string public constant DOMAIN_NAME = "Taskmarket Sponsored Settler";
    string public constant DOMAIN_VERSION = "1";

    uint64 public constant DEFAULT_CLAIM_DELAY_SECONDS = 3600;
    uint64 public constant TIMELOCK_DELAY = 48 hours;
    uint256 public constant MAX_SETTLERS = 16;

    bytes32 public constant RESERVE_TYPEHASH = keccak256(
        "Reserve(address vault,bytes32 allocationId,uint256 baseChainId,bytes32 baseTaskId,uint64 commitmentNonce,address manager,uint256 grossAmount,uint64 epoch,uint16 feeBps,address feeRecipient,bytes32 termsHash)"
    );
    bytes32 public constant RELEASE_TYPEHASH = keccak256(
        "Release(address vault,bytes32 allocationId,uint256 baseChainId,bytes32 baseTaskId,uint64 commitmentNonce)"
    );
    bytes32 public constant SETTLE_TYPEHASH = keccak256(
        "Settle(address vault,bytes32 allocationId,uint256 baseChainId,bytes32 baseTaskId,uint64 commitmentNonce,uint64 epoch,bytes32 rewardsRoot,uint32 leafCount,uint256 sponsoredTaskTotal,uint256 feeTotal,uint256 distributedGross)"
    );

    enum AllocationState {
        None,
        Reserved,
        Pending,
        Settled,
        Released
    }

    /// @dev Field order matches `RESERVE_TYPEHASH`. Every field is static, so
    ///      `abi.encode(RESERVE_TYPEHASH, request)` is the EIP-712 struct encoding.
    struct ReserveRequest {
        address vault;
        bytes32 allocationId;
        uint256 baseChainId;
        bytes32 baseTaskId;
        uint64 commitmentNonce;
        address manager;
        uint256 grossAmount;
        uint64 epoch;
        uint16 feeBps;
        address feeRecipient;
        bytes32 termsHash;
    }

    struct ReleaseRequest {
        address vault;
        bytes32 allocationId;
        uint256 baseChainId;
        bytes32 baseTaskId;
        uint64 commitmentNonce;
    }

    struct SettleRequest {
        address vault;
        bytes32 allocationId;
        uint256 baseChainId;
        bytes32 baseTaskId;
        uint64 commitmentNonce;
        uint64 epoch;
        bytes32 rewardsRoot;
        uint32 leafCount;
        uint256 sponsoredTaskTotal;
        uint256 feeTotal;
        uint256 distributedGross;
    }

    struct Allocation {
        AllocationState state;
        uint64 commitmentNonce;
        uint64 epoch;
        uint16 feeBps;
        uint64 settledAt;
        uint32 leafCount;
        uint256 baseChainId;
        bytes32 baseTaskId;
        uint256 grossAmount;
        bytes32 rewardsRoot;
        uint256 sponsoredTaskTotal;
        uint256 feeTotal;
        uint256 distributedGross;
    }

    address[] private _settlers;
    mapping(address account => bool active) public isSettler;
    uint8 public threshold;

    ISponsoredTaskSettlerAuthority public authority;
    uint64 public claimDelaySeconds;

    mapping(address vault => mapping(bytes32 allocationId => Allocation record)) private _allocations;
    /// @notice Settle digests already accepted. A revoked root's signatures can never be replayed.
    mapping(bytes32 digest => bool used) public settleDigestUsed;

    bytes32 public pendingSettlersHash;
    uint64 public pendingSettlersEta;
    address public pendingAuthority;
    uint64 public pendingAuthorityEta;
    uint64 public pendingClaimDelay;
    uint64 public pendingClaimDelayEta;

    error ZeroAddress();
    error InvalidContract(address account);
    error InvalidSettlers();
    error InvalidThreshold(uint8 threshold, uint256 settlerCount);
    error InvalidClaimDelay(uint64 claimDelaySeconds);
    error InvalidSignature(uint256 index);
    error SignersNotSorted(uint256 index);
    error NotSettler(address signer);
    error SettlerThresholdNotMet(uint256 valid, uint8 threshold);
    error NotAuthorized();
    error InvalidAllocationId(bytes32 expected, bytes32 provided);
    error InvalidBaseTask();
    error VaultNotControlled(address vault);
    error AllocationWrongState(address vault, bytes32 allocationId, AllocationState state);
    error CommitmentMismatch(address vault, bytes32 allocationId);
    error EpochMismatch(uint64 expected, uint64 provided);
    error InvalidSettlementTotals();
    error SettlementExceedsAllocation(uint256 distributed, uint256 gross);
    error SettlementFeeTooHigh(uint256 provided, uint256 maximum);
    error SettlementAlreadyUsed(bytes32 digest);
    error ClaimDelayNotElapsed(uint256 claimableAt);
    error NothingScheduled();
    error ScheduledChangeMismatch();
    error TimelockNotElapsed(uint256 eta);
    error OwnershipRenunciationDisabled();

    event TaskReservationAuthorized(
        address indexed vault,
        bytes32 indexed allocationId,
        bytes32 indexed baseTaskId,
        uint256 baseChainId,
        uint64 commitmentNonce,
        address manager,
        uint256 grossAmount,
        uint64 epoch
    );
    event TaskReleaseAuthorized(
        address indexed vault,
        bytes32 indexed allocationId,
        bytes32 indexed baseTaskId,
        uint256 baseChainId,
        uint64 commitmentNonce
    );
    event SettlementPending(
        address indexed vault,
        bytes32 indexed allocationId,
        bytes32 indexed baseTaskId,
        uint256 baseChainId,
        uint64 commitmentNonce,
        bytes32 rewardsRoot,
        uint32 leafCount,
        uint256 sponsoredTaskTotal,
        uint256 feeTotal,
        uint256 distributedGross,
        uint256 claimableAt
    );
    event SettlementFinalized(
        address indexed vault, bytes32 indexed allocationId, bytes32 indexed baseTaskId, bytes32 rewardsRoot
    );
    event SettlementRevoked(
        address indexed vault,
        bytes32 indexed allocationId,
        bytes32 indexed baseTaskId,
        bytes32 rewardsRoot,
        uint256 sponsoredTaskTotal
    );
    event SettlersChangeScheduled(address[] settlers, uint8 threshold, uint64 eta);
    event SettlersChangeCancelled();
    event SettlersChanged(address[] settlers, uint8 threshold);
    event AuthorityChangeScheduled(address indexed authority, uint64 eta);
    event AuthorityChangeCancelled();
    event AuthorityChanged(address indexed authority);
    event ClaimDelayChangeScheduled(uint64 claimDelaySeconds, uint64 eta);
    event ClaimDelayChangeCancelled();
    event ClaimDelaySet(uint64 claimDelaySeconds);

    /// @param initialOwner The admin, normally a Safe. It pauses, revokes and schedules changes.
    /// @param initialSettlers Strictly ascending, nonzero settler addresses.
    /// @param initialThreshold How many of them must sign each authorization.
    constructor(address initialOwner, address[] memory initialSettlers, uint8 initialThreshold)
        EIP712(DOMAIN_NAME, DOMAIN_VERSION)
        Ownable(initialOwner)
    {
        _validateSettlers(initialSettlers, initialThreshold);
        _applySettlers(initialSettlers, initialThreshold);
        claimDelaySeconds = DEFAULT_CLAIM_DELAY_SECONDS;
        emit ClaimDelaySet(DEFAULT_CLAIM_DELAY_SECONDS);
    }

    // ---------------------------------------------------------------------------------------------
    // Settler-authorized actions (anyone may relay)
    // ---------------------------------------------------------------------------------------------

    /// @notice Reserves `grossAmount` in `vault` for a Base task. Blocked while paused.
    function reserve(ReserveRequest calldata request, bytes[] calldata signatures) external whenNotPaused nonReentrant {
        _authorize(keccak256(abi.encode(RESERVE_TYPEHASH, request)), signatures);
        _requireAllocationId(request.allocationId, request.baseChainId, request.baseTaskId);
        _requireControlledVault(request.vault);

        Allocation storage record = _allocations[request.vault][request.allocationId];
        if (record.state != AllocationState.None) {
            revert AllocationWrongState(request.vault, request.allocationId, record.state);
        }
        record.state = AllocationState.Reserved;
        record.commitmentNonce = request.commitmentNonce;
        record.epoch = request.epoch;
        record.feeBps = request.feeBps;
        record.baseChainId = request.baseChainId;
        record.baseTaskId = request.baseTaskId;
        record.grossAmount = request.grossAmount;

        ISponsoredTasksVault(request.vault)
            .reserveTask(
                request.allocationId,
                request.baseTaskId,
                request.manager,
                request.grossAmount,
                request.epoch,
                request.feeBps,
                request.feeRecipient,
                request.termsHash
            );
        emit TaskReservationAuthorized(
            request.vault,
            request.allocationId,
            request.baseTaskId,
            request.baseChainId,
            request.commitmentNonce,
            request.manager,
            request.grossAmount,
            request.epoch
        );
    }

    /// @notice Returns a reservation to the vault. Open while paused. Releasing an already released
    ///         allocation is a no-op. A pending root must be revoked before its allocation can be
    ///         released.
    function release(ReleaseRequest calldata request, bytes[] calldata signatures) external nonReentrant {
        _authorize(keccak256(abi.encode(RELEASE_TYPEHASH, request)), signatures);
        Allocation storage record = _allocations[request.vault][request.allocationId];
        _requireCommitment(record, request.vault, request.allocationId, request.baseChainId, request.baseTaskId);
        if (record.commitmentNonce != request.commitmentNonce) {
            revert CommitmentMismatch(request.vault, request.allocationId);
        }
        if (record.state == AllocationState.Released) return;
        if (record.state != AllocationState.Reserved) {
            revert AllocationWrongState(request.vault, request.allocationId, record.state);
        }
        record.state = AllocationState.Released;
        // `changed` is false only for an allocation the vault already released; this record was
        // Reserved, so the vault releases it now or reverts.
        // slither-disable-next-line unused-return
        ISponsoredTasksVault(request.vault).releaseTask(request.allocationId);
        emit TaskReleaseAuthorized(
            request.vault, request.allocationId, request.baseTaskId, request.baseChainId, request.commitmentNonce
        );
    }

    /// @notice Stores a signed award root as pending. It does not touch the vault: `finalize`
    ///         installs it once the claim delay has passed. Blocked while paused.
    function settle(SettleRequest calldata request, bytes[] calldata signatures) external whenNotPaused {
        bytes32 digest = _authorize(keccak256(abi.encode(SETTLE_TYPEHASH, request)), signatures);
        if (settleDigestUsed[digest]) revert SettlementAlreadyUsed(digest);

        Allocation storage record = _allocations[request.vault][request.allocationId];
        _requireCommitment(record, request.vault, request.allocationId, request.baseChainId, request.baseTaskId);
        if (record.commitmentNonce != request.commitmentNonce) {
            revert CommitmentMismatch(request.vault, request.allocationId);
        }
        if (record.state != AllocationState.Reserved) {
            revert AllocationWrongState(request.vault, request.allocationId, record.state);
        }
        if (record.epoch != request.epoch) revert EpochMismatch(record.epoch, request.epoch);
        _checkTotals(record, request);

        settleDigestUsed[digest] = true;
        record.state = AllocationState.Pending;
        record.settledAt = uint64(block.timestamp);
        record.rewardsRoot = request.rewardsRoot;
        record.leafCount = request.leafCount;
        record.sponsoredTaskTotal = request.sponsoredTaskTotal;
        record.feeTotal = request.feeTotal;
        record.distributedGross = request.distributedGross;

        emit SettlementPending(
            request.vault,
            request.allocationId,
            request.baseTaskId,
            request.baseChainId,
            request.commitmentNonce,
            request.rewardsRoot,
            request.leafCount,
            request.sponsoredTaskTotal,
            request.feeTotal,
            request.distributedGross,
            block.timestamp + claimDelaySeconds
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Permissionless and admin settlement steps
    // ---------------------------------------------------------------------------------------------

    /// @notice Installs a pending root in the vault once the claim delay has passed. Anyone may call
    ///         it. Blocked while paused.
    function finalize(address vault, bytes32 allocationId) external whenNotPaused nonReentrant {
        Allocation storage record = _allocations[vault][allocationId];
        if (record.state != AllocationState.Pending) revert AllocationWrongState(vault, allocationId, record.state);
        uint256 claimableAt = uint256(record.settledAt) + claimDelaySeconds;
        if (block.timestamp < claimableAt) revert ClaimDelayNotElapsed(claimableAt);

        record.state = AllocationState.Settled;
        // `changed` is false only for an identical settlement the vault already holds, which this
        // contract (the only controller) never installs twice.
        // slither-disable-next-line unused-return
        ISponsoredTasksVault(vault)
            .installSettlement(
                allocationId,
                record.baseTaskId,
                record.rewardsRoot,
                record.leafCount,
                record.sponsoredTaskTotal,
                record.feeTotal,
                record.distributedGross
            );
        emit SettlementFinalized(vault, allocationId, record.baseTaskId, record.rewardsRoot);
    }

    /// @notice Deletes a pending root so the settlers can sign a corrected one. Works whether or
    ///         not the settler is paused, since nothing in the vault has changed yet.
    function revokeSettlement(address vault, bytes32 allocationId) external onlyOwner {
        Allocation storage record = _allocations[vault][allocationId];
        if (record.state != AllocationState.Pending) revert AllocationWrongState(vault, allocationId, record.state);
        bytes32 root = record.rewardsRoot;
        uint256 total = record.sponsoredTaskTotal;
        record.state = AllocationState.Reserved;
        record.settledAt = 0;
        record.rewardsRoot = bytes32(0);
        record.leafCount = 0;
        record.sponsoredTaskTotal = 0;
        record.feeTotal = 0;
        record.distributedGross = 0;
        emit SettlementRevoked(vault, allocationId, record.baseTaskId, root, total);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ---------------------------------------------------------------------------------------------
    // Timelocked configuration
    // ---------------------------------------------------------------------------------------------

    /// @notice Schedules a new settler set and threshold. Takes effect through `applySettlers`
    ///         after `TIMELOCK_DELAY`. Pending roots are not affected by a change.
    function setSettlers(address[] calldata newSettlers, uint8 newThreshold) external onlyOwner {
        _validateSettlers(newSettlers, newThreshold);
        uint64 eta = uint64(block.timestamp) + TIMELOCK_DELAY;
        pendingSettlersHash = keccak256(abi.encode(newSettlers, newThreshold));
        pendingSettlersEta = eta;
        emit SettlersChangeScheduled(newSettlers, newThreshold, eta);
    }

    /// @notice Applies the scheduled settler set. Anyone may call it once the timelock has passed.
    function applySettlers(address[] calldata newSettlers, uint8 newThreshold) external {
        _requireElapsed(pendingSettlersEta);
        if (keccak256(abi.encode(newSettlers, newThreshold)) != pendingSettlersHash) revert ScheduledChangeMismatch();
        delete pendingSettlersHash;
        delete pendingSettlersEta;
        _applySettlers(newSettlers, newThreshold);
    }

    function cancelSettlers() external onlyOwner {
        if (pendingSettlersEta == 0) revert NothingScheduled();
        delete pendingSettlersHash;
        delete pendingSettlersEta;
        emit SettlersChangeCancelled();
    }

    /// @notice Schedules an authority swap. `address(0)` returns to this contract's settler set.
    function setAuthority(address newAuthority) external onlyOwner {
        if (newAuthority != address(0) && newAuthority.code.length == 0) revert InvalidContract(newAuthority);
        uint64 eta = uint64(block.timestamp) + TIMELOCK_DELAY;
        pendingAuthority = newAuthority;
        pendingAuthorityEta = eta;
        emit AuthorityChangeScheduled(newAuthority, eta);
    }

    function applyAuthority() external {
        _requireElapsed(pendingAuthorityEta);
        address newAuthority = pendingAuthority;
        delete pendingAuthority;
        delete pendingAuthorityEta;
        authority = ISponsoredTaskSettlerAuthority(newAuthority);
        emit AuthorityChanged(newAuthority);
    }

    function cancelAuthority() external onlyOwner {
        if (pendingAuthorityEta == 0) revert NothingScheduled();
        delete pendingAuthority;
        delete pendingAuthorityEta;
        emit AuthorityChangeCancelled();
    }

    /// @notice Raising the claim delay applies at once; lowering it waits `TIMELOCK_DELAY` and is
    ///         applied by `applyClaimDelay`. Zero is rejected so the root watcher always has a window.
    function setClaimDelay(uint64 newClaimDelaySeconds) external onlyOwner {
        if (newClaimDelaySeconds == 0 || newClaimDelaySeconds > type(uint32).max) {
            revert InvalidClaimDelay(newClaimDelaySeconds);
        }
        if (newClaimDelaySeconds >= claimDelaySeconds) {
            claimDelaySeconds = newClaimDelaySeconds;
            emit ClaimDelaySet(newClaimDelaySeconds);
            return;
        }
        uint64 eta = uint64(block.timestamp) + TIMELOCK_DELAY;
        pendingClaimDelay = newClaimDelaySeconds;
        pendingClaimDelayEta = eta;
        emit ClaimDelayChangeScheduled(newClaimDelaySeconds, eta);
    }

    function applyClaimDelay() external {
        _requireElapsed(pendingClaimDelayEta);
        uint64 newClaimDelaySeconds = pendingClaimDelay;
        delete pendingClaimDelay;
        delete pendingClaimDelayEta;
        claimDelaySeconds = newClaimDelaySeconds;
        emit ClaimDelaySet(newClaimDelaySeconds);
    }

    function cancelClaimDelay() external onlyOwner {
        if (pendingClaimDelayEta == 0) revert NothingScheduled();
        delete pendingClaimDelay;
        delete pendingClaimDelayEta;
        emit ClaimDelayChangeCancelled();
    }

    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    function settlers() external view returns (address[] memory) {
        return _settlers;
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function allocationIdFor(uint256 baseChainId, bytes32 baseTaskId) public pure returns (bytes32) {
        return keccak256(abi.encode(baseChainId, baseTaskId));
    }

    function reserveDigest(ReserveRequest calldata request) external view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(RESERVE_TYPEHASH, request)));
    }

    function releaseDigest(ReleaseRequest calldata request) external view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(RELEASE_TYPEHASH, request)));
    }

    function settleDigest(SettleRequest calldata request) external view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(SETTLE_TYPEHASH, request)));
    }

    function allocationCommitment(address vault, bytes32 allocationId)
        external
        view
        returns (
            AllocationState state,
            uint256 baseChainId,
            bytes32 baseTaskId,
            uint64 commitmentNonce,
            uint64 epoch,
            uint16 feeBps,
            uint256 grossAmount
        )
    {
        Allocation storage r = _allocations[vault][allocationId];
        return (r.state, r.baseChainId, r.baseTaskId, r.commitmentNonce, r.epoch, r.feeBps, r.grossAmount);
    }

    /// @dev `claimableAt` is zero unless the allocation holds a pending or finalized root.
    function allocationSettlement(address vault, bytes32 allocationId)
        external
        view
        returns (
            bytes32 rewardsRoot,
            uint32 leafCount,
            uint256 sponsoredTaskTotal,
            uint256 feeTotal,
            uint256 distributedGross,
            uint64 settledAt,
            uint256 claimableAt
        )
    {
        Allocation storage r = _allocations[vault][allocationId];
        claimableAt = r.settledAt == 0 ? 0 : uint256(r.settledAt) + claimDelaySeconds;
        return
            (r.rewardsRoot, r.leafCount, r.sponsoredTaskTotal, r.feeTotal, r.distributedGross, r.settledAt, claimableAt);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev Verifies `signatures` over the typed-data digest of `structHash`. With an authority set,
    ///      the authority decides; otherwise each signature must recover to a distinct current
    ///      settler, in strictly ascending signer order, and at least `threshold` must be present.
    function _authorize(bytes32 structHash, bytes[] calldata signatures) private view returns (bytes32 digest) {
        digest = _hashTypedDataV4(structHash);
        ISponsoredTaskSettlerAuthority current = authority;
        if (address(current) != address(0)) {
            if (!current.isAuthorized(digest, signatures)) revert NotAuthorized();
            return digest;
        }
        uint256 count = signatures.length;
        address previous = address(0);
        for (uint256 i; i < count; ++i) {
            (address signer, ECDSA.RecoverError err, bytes32 errArg) = ECDSA.tryRecover(digest, signatures[i]);
            if (err != ECDSA.RecoverError.NoError || errArg != bytes32(0)) revert InvalidSignature(i);
            if (signer <= previous) revert SignersNotSorted(i);
            if (!isSettler[signer]) revert NotSettler(signer);
            previous = signer;
        }
        if (count < threshold) revert SettlerThresholdNotMet(count, threshold);
    }

    function _requireAllocationId(bytes32 allocationId, uint256 baseChainId, bytes32 baseTaskId) private pure {
        if (baseChainId == 0 || baseTaskId == bytes32(0)) revert InvalidBaseTask();
        bytes32 expected = allocationIdFor(baseChainId, baseTaskId);
        if (allocationId != expected) revert InvalidAllocationId(expected, allocationId);
    }

    function _requireControlledVault(address vault) private view {
        if (vault.code.length == 0) revert InvalidContract(vault);
        if (ISponsoredTasksVault(vault).controller() != address(this)) revert VaultNotControlled(vault);
    }

    function _requireCommitment(
        Allocation storage record,
        address vault,
        bytes32 allocationId,
        uint256 baseChainId,
        bytes32 baseTaskId
    ) private view {
        if (record.state == AllocationState.None) {
            revert AllocationWrongState(vault, allocationId, record.state);
        }
        if (record.baseChainId != baseChainId || record.baseTaskId != baseTaskId) {
            revert CommitmentMismatch(vault, allocationId);
        }
    }

    /// @dev The same checks the vault's `installSettlement` makes, so a root that passes `settle`
    ///      only fails `finalize` if the vault itself changed (an owner exit).
    function _checkTotals(Allocation storage record, SettleRequest calldata request) private view {
        if (request.distributedGross > record.grossAmount) {
            revert SettlementExceedsAllocation(request.distributedGross, record.grossAmount);
        }
        if (request.sponsoredTaskTotal + request.feeTotal != request.distributedGross) {
            revert InvalidSettlementTotals();
        }
        uint256 maximumFee = Math.mulDiv(request.distributedGross, record.feeBps, 10_000);
        if (request.feeTotal > maximumFee) revert SettlementFeeTooHigh(request.feeTotal, maximumFee);
        bool hasAwards = request.sponsoredTaskTotal > 0;
        if (hasAwards != (request.rewardsRoot != bytes32(0)) || hasAwards != (request.leafCount > 0)) {
            revert InvalidSettlementTotals();
        }
    }

    function _requireElapsed(uint64 eta) private view {
        // An unscheduled change has a zero eta; scheduled etas are always >= 1.
        if (eta < 1) revert NothingScheduled();
        if (block.timestamp < eta) revert TimelockNotElapsed(eta);
    }

    function _validateSettlers(address[] memory newSettlers, uint8 newThreshold) private pure {
        uint256 count = newSettlers.length;
        if (count == 0 || count > MAX_SETTLERS) revert InvalidSettlers();
        if (newThreshold == 0 || newThreshold > count) revert InvalidThreshold(newThreshold, count);
        address previous = address(0);
        for (uint256 i; i < count; ++i) {
            // Strictly ascending: rejects the zero address and duplicates in one comparison.
            if (newSettlers[i] <= previous) revert InvalidSettlers();
            previous = newSettlers[i];
        }
    }

    function _applySettlers(address[] memory newSettlers, uint8 newThreshold) private {
        uint256 oldCount = _settlers.length;
        for (uint256 i; i < oldCount; ++i) {
            isSettler[_settlers[i]] = false;
        }
        delete _settlers;
        uint256 count = newSettlers.length;
        for (uint256 i; i < count; ++i) {
            isSettler[newSettlers[i]] = true;
            _settlers.push(newSettlers[i]);
        }
        threshold = newThreshold;
        emit SettlersChanged(newSettlers, newThreshold);
    }
}
