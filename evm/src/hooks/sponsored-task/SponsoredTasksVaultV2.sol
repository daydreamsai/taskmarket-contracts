// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    EIP712Upgradeable
} from "openzeppelin-contracts-upgradeable/contracts/utils/cryptography/EIP712Upgradeable.sol";
import { OwnableUpgradeable } from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {
    Ownable2StepUpgradeable
} from "openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import { SponsoredTaskTypes } from "./SponsoredTaskTypes.sol";
import { ISponsoredTaskFeePolicy } from "./interfaces/ISponsoredTaskFeePolicy.sol";
import { IERC3009Receive } from "./interfaces/IERC3009Receive.sol";
import { ISponsoredTasksVault } from "./interfaces/ISponsoredTasksVault.sol";

/// @title SponsoredTasksVaultV2
/// @notice Project-owned, one-token vault reserve used by an authorized Taskmarket controller.
///         Owner actions can be authorized by the owner's signature and funding by the funder's
///         EIP-3009 signature, so anyone (a relayer) can submit them and pay the gas.
/// @dev Designed to be deployed as a non-upgradeable minimal clone. The vault owner can always
///      withdraw available tokens or terminally exit the whole vault. Exit invalidates every old
///      reservation, claim, signature, and cross-chain message by advancing `epoch`.
/// @dev Signed owner actions are EIP-712 typed data in this vault's own domain (the vault is the
///      verifying contract), checked against the current `owner()` with `SignatureChecker`, so an
///      ERC-1271 owner such as a Safe signs too. Each carries the vault's sequential `ownerNonce`
///      and a `deadline`: a signature works once, only on this vault and chain, only before its
///      deadline, and only while its signer is still the owner. Completing an ownership transfer
///      also advances the nonce. Advancing the nonce with
///      `cancelOwnerSignatures` revokes every outstanding signed action.
/// @dev A relayer that submits one of these calls only pays its gas. It cannot change what was
///      signed, and every token movement pays the recipient or the vault the signer named.
contract SponsoredTasksVaultV2 is ISponsoredTasksVault, Ownable2StepUpgradeable, EIP712Upgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant CLAIM_TO_TYPEHASH = keccak256(
        "ClaimTo(bytes32 vaultId,uint64 epoch,bytes32 allocationId,bytes32 taskId,uint256 index,address worker,address destination,uint256 amount,uint256 nonce,uint256 deadline)"
    );
    uint32 public constant VAULT_VERSION = 2;

    bytes32 public constant CONFIGURE_MANAGER_TYPEHASH = keccak256(
        "ConfigureManager(bytes32 vaultId,address manager,uint256 cap,bool active,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant WITHDRAW_AVAILABLE_TYPEHASH = keccak256(
        "WithdrawAvailable(bytes32 vaultId,address recipient,uint256 amount,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant EMERGENCY_EXIT_TYPEHASH =
        keccak256("EmergencyExitVault(bytes32 vaultId,address recipient,uint256 nonce,uint256 deadline)");

    bytes32 public override vaultId;
    IERC20 public projectToken;
    /// @notice EIP-155 chain ID where this vault settles project-token accounting (not a CCIP selector).
    uint256 public override settlementChain;
    address public override controller;
    ISponsoredTaskFeePolicy public feePolicy;
    SponsoredTaskTypes.VaultStatus public vaultStatus;
    uint64 public override epoch;

    uint256 public totalFunded;
    uint256 public totalReserved;
    uint256 public totalClaimable;
    uint256 public totalSponsoredTaskPaid;
    uint256 public totalFeesPaid;
    uint256 public totalWithdrawn;
    uint256 public totalDefaultedReserved;
    uint256 public totalDefaultedClaimable;

    mapping(address manager => SponsoredTaskTypes.ManagerAccount account) private _managers;
    mapping(bytes32 allocationId => SponsoredTaskTypes.Allocation allocation) private _allocations;
    mapping(bytes32 allocationId => mapping(uint256 word => uint256 bitmap)) private _claimedBitmaps;
    mapping(address worker => uint256 nonce) public claimNonces;
    /// @notice The nonce the owner's next signed action must carry.
    uint256 public ownerNonce;

    error AlreadyInitialized();
    error ZeroAddress();
    error InvalidContract(address account);
    error InvalidVaultId();
    error VaultNotActive();
    error OnlyController(address caller);
    error InvalidManagerCap(uint256 minimum, uint256 provided);
    error ManagerNotActive(address manager);
    error ManagerAllowanceExceeded(address manager, uint256 requested, uint256 remaining);
    error AllocationIdRequired();
    error TaskIdRequired();
    error TermsHashRequired();
    error GrossAmountRequired();
    error AllocationAlreadyExists(bytes32 allocationId);
    error AllocationNotFound(bytes32 allocationId);
    error AllocationWrongStatus(bytes32 allocationId, SponsoredTaskTypes.AllocationStatus status);
    error AllocationEpochMismatch(uint64 expected, uint64 actual);
    error TaskBindingConflict(bytes32 allocationId, bytes32 expected, bytes32 provided);
    error FeeTermsMismatch(uint16 expectedBps, address expectedRecipient, uint16 actualBps, address actualRecipient);
    error InsufficientAvailable(uint256 requested, uint256 availableAmount);
    error Insolvent(uint256 balance, uint256 liabilities);
    error TokenTransferAmountMismatch(uint256 expected, uint256 received);
    error TokenSenderAmountMismatch(uint256 expected, uint256 sent);
    error TokenRecipientAmountMismatch(uint256 expected, uint256 received);
    error InvalidSettlementTotals();
    error SettlementExceedsAllocation(uint256 distributed, uint256 gross);
    error SettlementFeeTooHigh(uint256 provided, uint256 maximum);
    error SettlementCommitmentRequired();
    error UnexpectedSettlementCommitment();
    error ConflictingSettlement(bytes32 allocationId);
    error ClaimExpired(uint256 deadline);
    error InvalidClaimNonce(address worker, uint256 expected, uint256 provided);
    error InvalidClaimSignature();
    error InvalidClaimProof();
    error ClaimAlreadyPaid(bytes32 allocationId, uint256 index);
    error ClaimIndexOutOfBounds(uint256 index, uint256 leafCount);
    error NothingToClaim();
    error NotFeeRecipient(address caller, address expected);
    error OwnershipRenunciationDisabled();
    error OwnerSignatureExpired(uint256 deadline);
    error InvalidOwnerSignature();

    event VaultInitialized(
        bytes32 indexed vaultId,
        address indexed projectToken,
        address indexed vaultOwner,
        address controller,
        address feePolicy,
        uint64 epoch
    );
    event VaultFunded(address indexed funder, uint256 amount);
    event AvailableWithdrawn(address indexed owner, address indexed recipient, uint256 amount);
    event ManagerConfigured(address indexed manager, uint256 cap, uint256 reserved, uint256 spent, bool active);
    event TaskReserved(
        bytes32 indexed allocationId,
        bytes32 indexed taskId,
        address indexed manager,
        uint64 epoch,
        uint256 grossAmount,
        uint16 feeBps,
        address feeRecipient,
        bytes32 termsHash
    );
    event TaskBound(bytes32 indexed allocationId, bytes32 indexed taskId);
    event TaskReleased(bytes32 indexed allocationId, bytes32 indexed taskId, address indexed manager, uint256 amount);
    event SettlementInstalled(
        bytes32 indexed allocationId,
        bytes32 indexed taskId,
        bytes32 rewardsRoot,
        uint32 leafCount,
        uint256 distributedGross,
        uint256 sponsoredTaskTotal,
        uint256 feeTotal,
        uint256 releasedAmount
    );
    event SponsoredTaskClaimed(
        bytes32 indexed allocationId,
        bytes32 indexed taskId,
        uint256 indexed index,
        address worker,
        address destination,
        uint256 amount
    );
    event FeeClaimed(
        bytes32 indexed allocationId,
        bytes32 indexed taskId,
        address indexed feeRecipient,
        address destination,
        uint256 amount
    );
    event VaultEmergencyExited(
        bytes32 indexed vaultId,
        address indexed owner,
        address indexed recipient,
        uint64 closedEpoch,
        uint64 newEpoch,
        uint256 amountWithdrawn,
        uint256 affectedReserved,
        uint256 affectedClaimable
    );
    event OwnerSignatureUsed(address indexed owner, uint256 indexed nonce);

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController(msg.sender);
        _;
    }

    modifier onlyActive() {
        if (vaultStatus != SponsoredTaskTypes.VaultStatus.Active) revert VaultNotActive();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(bytes32 vaultId_, address token_, address vaultOwner_, address controller_, address feePolicy_)
        external
        override
        initializer
    {
        if (vaultStatus != SponsoredTaskTypes.VaultStatus.Uninitialized) {
            revert AlreadyInitialized();
        }
        if (vaultId_ == bytes32(0)) revert InvalidVaultId();
        if (token_ == address(0) || vaultOwner_ == address(0) || controller_ == address(0) || feePolicy_ == address(0)) revert ZeroAddress();
        if (token_.code.length == 0) revert InvalidContract(token_);
        if (feePolicy_.code.length == 0) revert InvalidContract(feePolicy_);

        __Ownable_init(vaultOwner_);
        __Ownable2Step_init();
        __EIP712_init("SponsoredTasksVault", "1");

        vaultId = vaultId_;
        projectToken = IERC20(token_);
        settlementChain = block.chainid;
        controller = controller_;
        feePolicy = ISponsoredTaskFeePolicy(feePolicy_);
        vaultStatus = SponsoredTaskTypes.VaultStatus.Active;
        epoch = 1;

        emit VaultInitialized(vaultId_, token_, vaultOwner_, controller_, feePolicy_, 1);
    }

    /// @notice Fund the vault with an exact amount of a conventional ERC-20.
    /// @dev Fee-on-transfer and otherwise inexact incoming transfers are rejected atomically.
    function fund(uint256 amount) external onlyActive nonReentrant {
        (uint256 balanceBefore, uint256 funderBalanceBefore) = _fundingSnapshot(msg.sender, amount);
        projectToken.safeTransferFrom(msg.sender, address(this), amount);
        _recordFunding(msg.sender, amount, balanceBefore, funderBalanceBefore);
    }

    /// @dev The vault's and the funder's balances before a funding pull. Every funding path takes
    ///      this snapshot and then `_recordFunding`, so each keeps the exact sent/received checks
    ///      and the `totalFunded`/`VaultFunded` accounting.
    function _fundingSnapshot(address funder, uint256 amount)
        internal
        view
        returns (uint256 balanceBefore, uint256 funderBalanceBefore)
    {
        if (amount == 0) revert GrossAmountRequired();
        balanceBefore = projectToken.balanceOf(address(this));
        funderBalanceBefore = projectToken.balanceOf(funder);
    }

    function _recordFunding(address funder, uint256 amount, uint256 balanceBefore, uint256 funderBalanceBefore)
        internal
    {
        uint256 balanceAfter = projectToken.balanceOf(address(this));
        uint256 funderBalanceAfter = projectToken.balanceOf(funder);
        uint256 received = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        uint256 sent = funderBalanceBefore >= funderBalanceAfter ? funderBalanceBefore - funderBalanceAfter : 0;
        if (sent != amount) revert TokenSenderAmountMismatch(amount, sent);
        if (received != amount) revert TokenTransferAmountMismatch(amount, received);
        totalFunded += amount;
        emit VaultFunded(funder, amount);
    }

    /// @notice Balance not backing a live reservation or earned-but-unclaimed payout.
    function available() public view returns (uint256) {
        uint256 balance = projectToken.balanceOf(address(this));
        uint256 liabilities = totalReserved + totalClaimable;
        if (balance < liabilities) revert Insolvent(balance, liabilities);
        return balance - liabilities;
    }

    function managerAccount(address manager) external view returns (SponsoredTaskTypes.ManagerAccount memory account) {
        account = _managers[manager];
        if (vaultStatus == SponsoredTaskTypes.VaultStatus.Exited) account.active = false;
    }

    /// @notice Canonical ERC-20 address, exposed under the compact integration ABI.
    function token() external view override returns (address) {
        return address(projectToken);
    }

    /// @notice Canonical vault lifecycle state, exposed under the compact integration ABI.
    function status() external view override returns (SponsoredTaskTypes.VaultStatus) {
        return vaultStatus;
    }

    function owner() public view override(ISponsoredTasksVault, OwnableUpgradeable) returns (address) {
        return super.owner();
    }

    function managerRemaining(address manager) public view returns (uint256) {
        if (vaultStatus != SponsoredTaskTypes.VaultStatus.Active) return 0;
        SponsoredTaskTypes.ManagerAccount storage account = _managers[manager];
        uint256 used = account.reserved + account.spent;
        return account.cap > used ? account.cap - used : 0;
    }

    /// @dev Split into two getters rather than one returning the full 16-field `Allocation` --
    ///      a single external function returning the whole struct trips `forge coverage
    ///      --ir-minimum`'s stack-too-deep limit purely on its own ABI-encoded return (the
    ///      unoptimized encoder cannot pack that many fields into available stack slots). Same
    ///      class of failure as `SponsoredTaskHook.taskAllocationSettlement`'s own doc comment.
    function allocationTerms(bytes32 allocationId)
        external
        view
        override
        returns (
            bytes32 taskId,
            bytes32 termsHash,
            address manager,
            uint64 epoch,
            uint16 feeBps,
            address feeRecipient,
            uint256 grossAmount,
            uint256 distributedGross
        )
    {
        SponsoredTaskTypes.Allocation storage a = _allocations[allocationId];
        return (a.taskId, a.termsHash, a.manager, a.epoch, a.feeBps, a.feeRecipient, a.grossAmount, a.distributedGross);
    }

    function allocationSettlement(bytes32 allocationId)
        external
        view
        override
        returns (
            uint256 sponsoredTaskOutstanding,
            uint256 sponsoredTaskPaid,
            uint256 feeOutstanding,
            uint256 feePaid,
            uint256 releasedAmount,
            bytes32 rewardsRoot,
            uint32 leafCount,
            SponsoredTaskTypes.AllocationStatus status
        )
    {
        SponsoredTaskTypes.Allocation storage a = _allocations[allocationId];
        return (
            a.sponsoredTaskOutstanding,
            a.sponsoredTaskPaid,
            a.feeOutstanding,
            a.feePaid,
            a.releasedAmount,
            a.rewardsRoot,
            a.leafCount,
            a.status
        );
    }

    function effectiveAllocationStatus(bytes32 allocationId)
        public
        view
        override
        returns (SponsoredTaskTypes.AllocationStatus)
    {
        SponsoredTaskTypes.Allocation storage item = _allocations[allocationId];
        SponsoredTaskTypes.AllocationStatus raw = item.status;
        if (
            vaultStatus == SponsoredTaskTypes.VaultStatus.Exited && item.epoch != epoch
                && (raw == SponsoredTaskTypes.AllocationStatus.Reserved
                    || raw == SponsoredTaskTypes.AllocationStatus.Claimable)
        ) return SponsoredTaskTypes.AllocationStatus.DefaultedByOwner;
        return raw;
    }

    function isClaimed(bytes32 allocationId, uint256 index) public view returns (bool) {
        uint256 word = _claimedBitmaps[allocationId][index >> 8];
        return word & (uint256(1) << (index & 255)) != 0;
    }

    /// @notice Grant, increase, reduce, revoke, or reactivate a manager's lifetime token allowance.
    function configureManager(address manager, uint256 newCap, bool active) external onlyOwner onlyActive {
        _configureManager(manager, newCap, active);
    }

    function _configureManager(address manager, uint256 newCap, bool active) internal {
        if (manager == address(0)) revert ZeroAddress();
        SponsoredTaskTypes.ManagerAccount storage account = _managers[manager];
        uint256 minimum = account.reserved + account.spent;
        if (newCap < minimum) revert InvalidManagerCap(minimum, newCap);
        account.cap = newCap;
        account.active = active;
        emit ManagerConfigured(manager, newCap, account.reserved, account.spent, active);
    }

    function withdrawAvailable(address recipient, uint256 amount) external onlyOwner onlyActive nonReentrant {
        _withdrawAvailable(msg.sender, recipient, amount);
    }

    /// @dev `vaultOwner` is the owner who authorized the withdrawal, named in the event.
    function _withdrawAvailable(address vaultOwner, address recipient, uint256 amount) internal {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 availableAmount = available();
        if (amount > availableAmount) revert InsufficientAvailable(amount, availableAmount);
        totalWithdrawn += amount;
        _transferExact(recipient, amount);
        emit AvailableWithdrawn(vaultOwner, recipient, amount);
    }

    /// @inheritdoc ISponsoredTasksVault
    function reserveTask(
        bytes32 allocationId,
        bytes32 taskId,
        address manager,
        uint256 grossAmount,
        uint64 expectedEpoch,
        uint16 expectedFeeBps,
        address expectedFeeRecipient,
        bytes32 termsHash
    ) external override onlyController onlyActive nonReentrant {
        if (allocationId == bytes32(0)) revert AllocationIdRequired();
        if (manager == address(0)) revert ZeroAddress();
        if (grossAmount == 0) revert GrossAmountRequired();
        if (termsHash == bytes32(0)) revert TermsHashRequired();
        if (expectedEpoch != epoch) revert AllocationEpochMismatch(expectedEpoch, epoch);
        if (_allocations[allocationId].status != SponsoredTaskTypes.AllocationStatus.None) {
            revert AllocationAlreadyExists(allocationId);
        }

        (uint16 feeBps, address feeRecipient) =
            _checkReservation(manager, grossAmount, expectedFeeBps, expectedFeeRecipient);
        _recordReservation(allocationId, taskId, manager, grossAmount, feeBps, feeRecipient, termsHash);
    }

    /// @dev Split out of `reserveTask` so this validation's locals (the manager account, the two
    ///      allowance checks, the live fee terms) don't share a stack frame with the 16-field
    ///      `Allocation` struct literal `_recordReservation` builds -- the combined version
    ///      tripped `forge coverage --ir-minimum`'s stack-too-deep limit (unoptimized IR keeps
    ///      every local live, unlike the default optimized build). Same reasoning as
    ///      `SponsoredTaskHook._checkFund`/`_reserveLocal`'s own split.
    function _checkReservation(
        address manager,
        uint256 grossAmount,
        uint16 expectedFeeBps,
        address expectedFeeRecipient
    ) private view returns (uint16 feeBps, address feeRecipient) {
        SponsoredTaskTypes.ManagerAccount storage account = _managers[manager];
        if (!account.active) revert ManagerNotActive(manager);
        uint256 remaining = managerRemaining(manager);
        if (grossAmount > remaining) revert ManagerAllowanceExceeded(manager, grossAmount, remaining);

        uint256 availableAmount = available();
        if (grossAmount > availableAmount) revert InsufficientAvailable(grossAmount, availableAmount);

        SponsoredTaskTypes.FeeTerms memory current = feePolicy.feeTerms();
        if (current.bps != expectedFeeBps || current.recipient != expectedFeeRecipient) {
            revert FeeTermsMismatch(expectedFeeBps, expectedFeeRecipient, current.bps, current.recipient);
        }
        return (current.bps, current.recipient);
    }

    function _recordReservation(
        bytes32 allocationId,
        bytes32 taskId,
        address manager,
        uint256 grossAmount,
        uint16 feeBps,
        address feeRecipient,
        bytes32 termsHash
    ) private {
        _managers[manager].reserved += grossAmount;
        totalReserved += grossAmount;
        _allocations[allocationId] = SponsoredTaskTypes.Allocation({
            taskId: taskId,
            termsHash: termsHash,
            manager: manager,
            epoch: epoch,
            feeBps: feeBps,
            feeRecipient: feeRecipient,
            grossAmount: grossAmount,
            distributedGross: 0,
            sponsoredTaskOutstanding: 0,
            sponsoredTaskPaid: 0,
            feeOutstanding: 0,
            feePaid: 0,
            releasedAmount: 0,
            rewardsRoot: bytes32(0),
            leafCount: 0,
            status: SponsoredTaskTypes.AllocationStatus.Reserved
        });

        emit TaskReserved(allocationId, taskId, manager, epoch, grossAmount, feeBps, feeRecipient, termsHash);
    }

    /// @inheritdoc ISponsoredTasksVault
    function bindTask(bytes32 allocationId, bytes32 taskId)
        external
        override
        onlyController
        onlyActive
        returns (bool changed)
    {
        if (taskId == bytes32(0)) revert TaskIdRequired();
        SponsoredTaskTypes.Allocation storage item = _requireCurrentAllocation(allocationId);
        if (item.status != SponsoredTaskTypes.AllocationStatus.Reserved) {
            revert AllocationWrongStatus(allocationId, item.status);
        }
        if (item.taskId == taskId) return false;
        if (item.taskId != bytes32(0)) revert TaskBindingConflict(allocationId, item.taskId, taskId);
        item.taskId = taskId;
        emit TaskBound(allocationId, taskId);
        return true;
    }

    /// @inheritdoc ISponsoredTasksVault
    function releaseTask(bytes32 allocationId) external override onlyController onlyActive returns (bool changed) {
        SponsoredTaskTypes.Allocation storage item = _requireCurrentAllocation(allocationId);
        if (item.status == SponsoredTaskTypes.AllocationStatus.Released) return false;
        if (item.status != SponsoredTaskTypes.AllocationStatus.Reserved) {
            revert AllocationWrongStatus(allocationId, item.status);
        }

        SponsoredTaskTypes.ManagerAccount storage account = _managers[item.manager];
        account.reserved -= item.grossAmount;
        totalReserved -= item.grossAmount;
        item.releasedAmount = item.grossAmount;
        item.status = SponsoredTaskTypes.AllocationStatus.Released;
        emit TaskReleased(allocationId, item.taskId, item.manager, item.grossAmount);
        return true;
    }

    /// @inheritdoc ISponsoredTasksVault
    function installSettlement(
        bytes32 allocationId,
        bytes32 taskId,
        bytes32 rewardsRoot,
        uint32 leafCount,
        uint256 sponsoredTaskTotal,
        uint256 feeTotal,
        uint256 distributedGross
    ) external override onlyController onlyActive returns (bool changed) {
        SponsoredTaskTypes.Allocation storage item = _requireCurrentAllocation(allocationId);
        if (
            item.status == SponsoredTaskTypes.AllocationStatus.Claimable
                || item.status == SponsoredTaskTypes.AllocationStatus.Settled
        ) {
            if (
                item.taskId == taskId && item.rewardsRoot == rewardsRoot && item.leafCount == leafCount
                    && item.sponsoredTaskOutstanding + item.sponsoredTaskPaid == sponsoredTaskTotal
                    && item.feeOutstanding + item.feePaid == feeTotal && item.distributedGross == distributedGross
            ) return false;
            revert ConflictingSettlement(allocationId);
        }
        if (item.status != SponsoredTaskTypes.AllocationStatus.Reserved) {
            revert AllocationWrongStatus(allocationId, item.status);
        }
        if (taskId == bytes32(0)) revert TaskIdRequired();
        if (item.taskId != bytes32(0) && item.taskId != taskId) {
            revert TaskBindingConflict(allocationId, item.taskId, taskId);
        }
        if (distributedGross > item.grossAmount) {
            revert SettlementExceedsAllocation(distributedGross, item.grossAmount);
        }
        if (sponsoredTaskTotal + feeTotal != distributedGross) revert InvalidSettlementTotals();

        uint256 maximumFee = Math.mulDiv(distributedGross, item.feeBps, 10_000);
        if (feeTotal > maximumFee) revert SettlementFeeTooHigh(feeTotal, maximumFee);
        if (sponsoredTaskTotal > 0) {
            if (rewardsRoot == bytes32(0) || leafCount == 0) revert SettlementCommitmentRequired();
        } else if (rewardsRoot != bytes32(0) || leafCount != 0) {
            revert UnexpectedSettlementCommitment();
        }

        SponsoredTaskTypes.ManagerAccount storage account = _managers[item.manager];
        account.reserved -= item.grossAmount;
        account.spent += distributedGross;
        totalReserved -= item.grossAmount;
        totalClaimable += sponsoredTaskTotal + feeTotal;

        item.taskId = taskId;
        item.distributedGross = distributedGross;
        item.sponsoredTaskOutstanding = sponsoredTaskTotal;
        item.feeOutstanding = feeTotal;
        item.releasedAmount = item.grossAmount - distributedGross;
        item.rewardsRoot = rewardsRoot;
        item.leafCount = leafCount;
        item.status = sponsoredTaskTotal + feeTotal == 0
            ? SponsoredTaskTypes.AllocationStatus.Settled
            : SponsoredTaskTypes.AllocationStatus.Claimable;

        emit SettlementInstalled(
            allocationId,
            taskId,
            rewardsRoot,
            leafCount,
            distributedGross,
            sponsoredTaskTotal,
            feeTotal,
            item.releasedAmount
        );
        return true;
    }

    /// @notice Claim an earned Merkle leaf directly to the worker wallet.
    function claim(bytes32 allocationId, uint256 index, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        _claim(allocationId, index, msg.sender, msg.sender, amount, proof);
    }

    /// @notice Relay a worker-authorized, gasless claim to an arbitrary destination.
    function claimTo(
        bytes32 allocationId,
        uint256 index,
        address worker,
        address destination,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature,
        bytes32[] calldata proof
    ) external nonReentrant {
        if (block.timestamp > deadline) revert ClaimExpired(deadline);
        uint256 expectedNonce = claimNonces[worker];
        if (nonce != expectedNonce) revert InvalidClaimNonce(worker, expectedNonce, nonce);

        SponsoredTaskTypes.Allocation storage item = _allocations[allocationId];
        bytes32 digest =
            _claimDigest(allocationId, item.taskId, item.epoch, index, worker, destination, amount, nonce, deadline);
        if (!SignatureChecker.isValidSignatureNow(worker, digest, signature)) revert InvalidClaimSignature();
        claimNonces[worker] = expectedNonce + 1;
        _claim(allocationId, index, worker, destination, amount, proof);
    }

    function claimDigest(
        bytes32 allocationId,
        uint256 index,
        address worker,
        address destination,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        SponsoredTaskTypes.Allocation storage item = _allocations[allocationId];
        return _claimDigest(allocationId, item.taskId, item.epoch, index, worker, destination, amount, nonce, deadline);
    }

    /// @notice Standard double-hashed leaf compatible with OpenZeppelin StandardMerkleTree proofs.
    function claimLeaf(
        bytes32 allocationId,
        bytes32 taskId,
        uint64 allocationEpoch,
        uint256 index,
        address worker,
        uint256 amount
    ) public view returns (bytes32) {
        return keccak256(
            bytes.concat(keccak256(abi.encode(vaultId, allocationEpoch, allocationId, taskId, index, worker, amount)))
        );
    }

    /// @notice The snapshotted fee recipient pulls its task fee after settlement.
    function claimFee(bytes32 allocationId, address destination) external nonReentrant returns (uint256 amount) {
        if (vaultStatus != SponsoredTaskTypes.VaultStatus.Active) revert VaultNotActive();
        if (destination == address(0)) revert ZeroAddress();
        SponsoredTaskTypes.Allocation storage item = _requireCurrentAllocation(allocationId);
        if (msg.sender != item.feeRecipient) revert NotFeeRecipient(msg.sender, item.feeRecipient);
        amount = item.feeOutstanding;
        if (amount == 0) revert NothingToClaim();

        item.feeOutstanding = 0;
        item.feePaid += amount;
        totalClaimable -= amount;
        totalFeesPaid += amount;
        _markSettledIfEmpty(item);
        _transferExact(destination, amount);
        emit FeeClaimed(allocationId, item.taskId, msg.sender, destination, amount);
    }

    /// @notice Terminally close the vault and recover every token still in the vault.
    /// @dev This deliberately defaults live sponsors. It cannot selectively revoke one task while
    ///      the vault continues, and Taskmarket's independent USDC settlement is unaffected.
    /// @dev Unlike every other outgoing path, the exit accepts an inexact delivery (rev026): a token
    ///      that starts charging a transfer fee after funding makes every exact transfer revert, and
    ///      the exit is the only path left that can move the balance. It still reverts when the
    ///      recipient receives nothing, so a redirecting token cannot send the balance elsewhere.
    function emergencyExitVault(address recipient) external onlyOwner onlyActive nonReentrant returns (uint256 amount) {
        return _emergencyExitVault(msg.sender, recipient);
    }

    /// @dev `vaultOwner` is the owner who authorized the exit, named in the event.
    function _emergencyExitVault(address vaultOwner, address recipient) internal returns (uint256 amount) {
        if (recipient == address(0)) revert ZeroAddress();

        uint64 closedEpoch = epoch;
        uint256 affectedReserved = totalReserved;
        uint256 affectedClaimable = totalClaimable;
        amount = projectToken.balanceOf(address(this));

        vaultStatus = SponsoredTaskTypes.VaultStatus.Exited;
        epoch = closedEpoch + 1;
        totalDefaultedReserved += affectedReserved;
        totalDefaultedClaimable += affectedClaimable;
        totalReserved = 0;
        totalClaimable = 0;
        totalWithdrawn += amount;

        _transferExit(recipient, amount);
        emit VaultEmergencyExited(
            vaultId, vaultOwner, recipient, closedEpoch, epoch, amount, affectedReserved, affectedClaimable
        );
    }

    /// @dev Renouncing would remove the only terminal recovery authority and can permanently lock funds.
    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    function _claim(
        bytes32 allocationId,
        uint256 index,
        address worker,
        address destination,
        uint256 amount,
        bytes32[] calldata proof
    ) private {
        if (vaultStatus != SponsoredTaskTypes.VaultStatus.Active) {
            revert VaultNotActive();
        }
        if (worker == address(0) || destination == address(0)) revert ZeroAddress();
        if (amount == 0) revert NothingToClaim();

        SponsoredTaskTypes.Allocation storage item = _requireCurrentAllocation(allocationId);
        if (item.status != SponsoredTaskTypes.AllocationStatus.Claimable) {
            revert AllocationWrongStatus(allocationId, item.status);
        }
        if (index >= item.leafCount) revert ClaimIndexOutOfBounds(index, item.leafCount);
        if (isClaimed(allocationId, index)) revert ClaimAlreadyPaid(allocationId, index);

        bytes32 leaf = claimLeaf(allocationId, item.taskId, item.epoch, index, worker, amount);
        if (!MerkleProof.verifyCalldata(proof, item.rewardsRoot, leaf)) revert InvalidClaimProof();
        if (amount > item.sponsoredTaskOutstanding) revert InvalidSettlementTotals();

        _claimedBitmaps[allocationId][index >> 8] |= uint256(1) << (index & 255);
        item.sponsoredTaskOutstanding -= amount;
        item.sponsoredTaskPaid += amount;
        totalClaimable -= amount;
        totalSponsoredTaskPaid += amount;
        _markSettledIfEmpty(item);

        _transferExact(destination, amount);
        emit SponsoredTaskClaimed(allocationId, item.taskId, index, worker, destination, amount);
    }

    function _claimDigest(
        bytes32 allocationId,
        bytes32 taskId,
        uint64 allocationEpoch,
        uint256 index,
        address worker,
        address destination,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) private view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    CLAIM_TO_TYPEHASH,
                    vaultId,
                    allocationEpoch,
                    allocationId,
                    taskId,
                    index,
                    worker,
                    destination,
                    amount,
                    nonce,
                    deadline
                )
            )
        );
    }

    function _requireCurrentAllocation(bytes32 allocationId)
        private
        view
        returns (SponsoredTaskTypes.Allocation storage item)
    {
        item = _allocations[allocationId];
        if (item.status == SponsoredTaskTypes.AllocationStatus.None) revert AllocationNotFound(allocationId);
        if (item.epoch != epoch) revert AllocationEpochMismatch(item.epoch, epoch);
    }

    function _markSettledIfEmpty(SponsoredTaskTypes.Allocation storage item) private {
        if (item.sponsoredTaskOutstanding == 0 && item.feeOutstanding == 0) {
            item.status = SponsoredTaskTypes.AllocationStatus.Settled;
        }
    }

    /// @dev Rejects tokens that debit this vault or credit the recipient by anything other than
    ///      the exact accounted amount. This also rejects self-transfers and transfer-tax behavior.
    /// @dev The exit's transfer: the vault must not lose more than it sends, and the recipient must
    ///      receive something, but a token's fee may take part of it.
    function _transferExit(address recipient, uint256 amount) private {
        uint256 vaultBalanceBefore = projectToken.balanceOf(address(this));
        uint256 recipientBalanceBefore = projectToken.balanceOf(recipient);

        projectToken.safeTransfer(recipient, amount);

        uint256 vaultBalanceAfter = projectToken.balanceOf(address(this));
        uint256 recipientBalanceAfter = projectToken.balanceOf(recipient);
        uint256 sent = vaultBalanceBefore >= vaultBalanceAfter ? vaultBalanceBefore - vaultBalanceAfter : 0;
        uint256 received =
            recipientBalanceAfter >= recipientBalanceBefore ? recipientBalanceAfter - recipientBalanceBefore : 0;
        // The zero checks are deliberate: a balance delta of exactly zero means nothing moved, which
        // the exit refuses, while any positive delta is accepted as a fee-reduced delivery.
        // slither-disable-next-line incorrect-equality
        if (sent > amount || (amount != 0 && sent == 0)) revert TokenSenderAmountMismatch(amount, sent);
        // slither-disable-next-line incorrect-equality
        if (amount != 0 && received == 0) revert TokenRecipientAmountMismatch(amount, received);
    }

    function _transferExact(address recipient, uint256 amount) private {
        uint256 vaultBalanceBefore = projectToken.balanceOf(address(this));
        uint256 recipientBalanceBefore = projectToken.balanceOf(recipient);

        projectToken.safeTransfer(recipient, amount);

        uint256 vaultBalanceAfter = projectToken.balanceOf(address(this));
        uint256 recipientBalanceAfter = projectToken.balanceOf(recipient);
        uint256 sent = vaultBalanceBefore >= vaultBalanceAfter ? vaultBalanceBefore - vaultBalanceAfter : 0;
        uint256 received =
            recipientBalanceAfter >= recipientBalanceBefore ? recipientBalanceAfter - recipientBalanceBefore : 0;
        if (sent != amount) revert TokenSenderAmountMismatch(amount, sent);
        if (received != amount) revert TokenRecipientAmountMismatch(amount, received);
    }

    /// @notice `configureManager`, authorized by the owner's signature instead of the caller.
    function configureManagerBySig(
        address manager,
        uint256 newCap,
        bool active,
        uint256 deadline,
        bytes calldata signature
    ) external onlyActive {
        uint256 nonce = ownerNonce;
        _useOwnerSignature(
            keccak256(abi.encode(CONFIGURE_MANAGER_TYPEHASH, vaultId, manager, newCap, active, nonce, deadline)),
            deadline,
            signature
        );
        _configureManager(manager, newCap, active);
    }

    /// @notice `withdrawAvailable`, authorized by the owner's signature instead of the caller.
    function withdrawAvailableBySig(address recipient, uint256 amount, uint256 deadline, bytes calldata signature)
        external
        onlyActive
        nonReentrant
    {
        uint256 nonce = ownerNonce;
        address vaultOwner = _useOwnerSignature(
            keccak256(abi.encode(WITHDRAW_AVAILABLE_TYPEHASH, vaultId, recipient, amount, nonce, deadline)),
            deadline,
            signature
        );
        _withdrawAvailable(vaultOwner, recipient, amount);
    }

    /// @notice `emergencyExitVault`, authorized by the owner's signature instead of the caller.
    function emergencyExitVaultBySig(address recipient, uint256 deadline, bytes calldata signature)
        external
        onlyActive
        nonReentrant
        returns (uint256 amount)
    {
        uint256 nonce = ownerNonce;
        address vaultOwner = _useOwnerSignature(
            keccak256(abi.encode(EMERGENCY_EXIT_TYPEHASH, vaultId, recipient, nonce, deadline)), deadline, signature
        );
        return _emergencyExitVault(vaultOwner, recipient);
    }

    /// @notice Revokes every outstanding signed owner action by advancing the nonce.
    function cancelOwnerSignatures() external onlyOwner {
        uint256 nonce = ownerNonce;
        ownerNonce = nonce + 1;
        emit OwnerSignatureUsed(msg.sender, nonce);
    }

    /// @dev Every completed ownership transfer advances `ownerNonce`, so a signature an earlier
    ///      owner made cannot become valid again if ownership later returns to them. Setting the
    ///      first owner at initialization leaves the nonce at zero. Only `acceptOwnership` reaches
    ///      here after initialization; starting a two-step transfer does not.
    function _transferOwnership(address newOwner) internal override {
        address previousOwner = owner();
        super._transferOwnership(newOwner);
        if (previousOwner != address(0)) {
            uint256 nonce = ownerNonce;
            ownerNonce = nonce + 1;
            emit OwnerSignatureUsed(previousOwner, nonce);
        }
    }

    /// @notice Fund the vault straight from `funder` with their EIP-3009 authorization, so a
    ///         relayer can submit it. Only a token that implements `receiveWithAuthorization`
    ///         supports it. `totalFunded` and `VaultFunded` record `funder`, exactly as `fund`
    ///         would for a funder that sent the transaction itself.
    /// @dev The token refuses the authorization unless this vault is its `to`, so it cannot be
    ///      redirected; replay is the token's own nonce check.
    function fundWithAuthorization(
        address funder,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external onlyActive nonReentrant {
        if (funder == address(0)) revert ZeroAddress();
        (uint256 balanceBefore, uint256 funderBalanceBefore) = _fundingSnapshot(funder, amount);
        IERC3009Receive(address(projectToken))
            .receiveWithAuthorization(funder, address(this), amount, validAfter, validBefore, nonce, signature);
        _recordFunding(funder, amount, balanceBefore, funderBalanceBefore);
    }

    /// @notice The EIP-712 digest the owner signs for a struct hash, for clients and tests.
    function ownerActionDigest(bytes32 structHash) external view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }

    /// @dev Checks the current owner signed `structHash` before `deadline` and spends the nonce.
    function _useOwnerSignature(bytes32 structHash, uint256 deadline, bytes calldata signature)
        private
        returns (address vaultOwner)
    {
        if (block.timestamp > deadline) revert OwnerSignatureExpired(deadline);
        vaultOwner = owner();
        if (!SignatureChecker.isValidSignatureNow(vaultOwner, _hashTypedDataV4(structHash), signature)) {
            revert InvalidOwnerSignature();
        }
        uint256 nonce = ownerNonce;
        ownerNonce = nonce + 1;
        emit OwnerSignatureUsed(vaultOwner, nonce);
    }
}
