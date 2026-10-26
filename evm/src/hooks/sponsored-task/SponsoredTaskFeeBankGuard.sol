// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { SponsoredTaskFeeBank } from "./SponsoredTaskFeeBank.sol";
import { ISponsoredTaskFeeBank } from "./interfaces/ISponsoredTaskFeeBank.sol";

/// @notice Minimal link asserted by the FeeBank guard before it can accept administration.
interface ISponsoredTaskFeeBankLinkedHook {
    function feeBank() external view returns (ISponsoredTaskFeeBank);
}

/// @title SponsoredTaskFeeBankGuard
/// @notice Permanently narrows administration of one exact Sponsored Task FeeBank.
/// @dev This contract is intentionally non-upgradeable and has no arbitrary-call or charger-
///      authorization path. Its owner must be a deployed contract, such as a Safe or timelock.
contract SponsoredTaskFeeBankGuard is Ownable2Step {
    SponsoredTaskFeeBank public immutable feeBank;
    address public immutable hook;
    uint256 public immutable feeCeiling;

    bool public feeBankOwnershipAccepted;

    error AdminMustBeContract(address admin);
    error AlreadyAcceptedFeeBankOwnership();
    error FeeBankNotControlled(address observedOwner);
    error FeeBankPendingOwnerMismatch(address expected, address observed);
    error FeeBankRequired();
    error FeeCeilingExceeded(uint256 requested, uint256 ceiling);
    error HookFeeBankMismatch(address expected, address observed);
    error HookFeeBankQueryFailed(address hook);
    error HookNotAuthorized(address hook);
    error HookRequired();
    error OwnershipRenunciationDisabled();

    event ChargerRevoked(address indexed charger);
    event FeeBankOwnershipAccepted(address indexed feeBank, address indexed hook);
    event FutureFeeConfigUpdated(uint256 amount, address indexed recipient);

    modifier onlyWhileControllingFeeBank() {
        address observedOwner = feeBank.owner();
        if (!feeBankOwnershipAccepted || observedOwner != address(this)) {
            revert FeeBankNotControlled(observedOwner);
        }
        _;
    }

    constructor(address initialAdmin, SponsoredTaskFeeBank feeBank_, address hook_, uint256 feeCeiling_)
        Ownable(initialAdmin)
    {
        if (initialAdmin.code.length == 0) revert AdminMustBeContract(initialAdmin);
        if (address(feeBank_) == address(0) || address(feeBank_).code.length == 0) revert FeeBankRequired();
        if (hook_ == address(0) || hook_.code.length == 0) revert HookRequired();

        feeBank = feeBank_;
        hook = hook_;
        feeCeiling = feeCeiling_;
        _assertHookLinksFeeBank();
    }

    /// @notice Permissionlessly accepts the FeeBank transfer after validating every commitment.
    /// @dev The current FeeBank owner must first commit by calling `transferOwnership(address(this))`.
    ///      Permissionless acceptance removes a Safe-signing availability window and grants the
    ///      caller no authority. The guard cannot prove that no other chargers were authorized before
    ///      transfer because the FeeBank mapping is not enumerable; deployment must prove that from
    ///      the transaction log.
    function acceptFeeBankOwnership() external {
        if (feeBankOwnershipAccepted) revert AlreadyAcceptedFeeBankOwnership();

        address observedPendingOwner = feeBank.pendingOwner();
        if (observedPendingOwner != address(this)) {
            revert FeeBankPendingOwnerMismatch(address(this), observedPendingOwner);
        }
        _assertHookLinksFeeBank();
        if (!feeBank.authorizedChargers(hook)) revert HookNotAuthorized(hook);

        uint256 currentFee = feeBank.feeAmount();
        if (currentFee > feeCeiling) revert FeeCeilingExceeded(currentFee, feeCeiling);

        // slither-disable-next-line reentrancy-no-eth
        feeBank.acceptOwnership();
        address observedOwner = feeBank.owner();
        if (observedOwner != address(this)) revert FeeBankNotControlled(observedOwner);

        // Must follow the acceptOwnership() call above -- this flag can only be set once the
        // transfer is confirmed, and feeBank is the immutable, constructor-fixed FeeBank this
        // guard exists to control (OZ Ownable2Step, no callback surface).
        feeBankOwnershipAccepted = true;
        emit FeeBankOwnershipAccepted(address(feeBank), hook);
    }

    /// @notice Updates only future task-creation fees, bounded by the immutable ceiling.
    /// @dev The FeeBank enforces its existing recipient rules: a non-zero fee requires a non-zero
    ///      recipient and cannot name the FeeBank itself.
    function setFutureFeeConfig(uint256 newAmount, address newRecipient)
        external
        onlyOwner
        onlyWhileControllingFeeBank
    {
        if (newAmount > feeCeiling) revert FeeCeilingExceeded(newAmount, feeCeiling);
        feeBank.setFeeConfig(newAmount, newRecipient);
        emit FutureFeeConfigUpdated(newAmount, newRecipient);
    }

    /// @notice Permanently revokes any known charger, including the exact Hook.
    /// @dev There is deliberately no inverse authorization function in this contract.
    function revokeCharger(address charger) external onlyOwner onlyWhileControllingFeeBank {
        feeBank.setCharger(charger, false);
        emit ChargerRevoked(charger);
    }

    /// @dev Preserve a Safe/timelock admin throughout two-step ownership rotation. Passing zero
    ///      remains available to cancel an accidentally-started transfer, as in Ownable2Step.
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner != address(0) && newOwner.code.length == 0) revert AdminMustBeContract(newOwner);
        super.transferOwnership(newOwner);
    }

    /// @dev Recheck the pending administrator at acceptance, not only when it is proposed.
    function acceptOwnership() public override {
        address successor = _msgSender();
        if (successor.code.length == 0) revert AdminMustBeContract(successor);
        super.acceptOwnership();
    }

    /// @dev Renunciation would strand the guard as FeeBank owner without a recovery authority.
    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    function _assertHookLinksFeeBank() private view {
        (bool success, bytes memory returndata) =
            hook.staticcall(abi.encodeCall(ISponsoredTaskFeeBankLinkedHook.feeBank, ()));
        if (!success || returndata.length != 32) revert HookFeeBankQueryFailed(hook);

        ISponsoredTaskFeeBank observedBank = abi.decode(returndata, (ISponsoredTaskFeeBank));
        if (address(observedBank) != address(feeBank)) {
            revert HookFeeBankMismatch(address(feeBank), address(observedBank));
        }
    }
}
