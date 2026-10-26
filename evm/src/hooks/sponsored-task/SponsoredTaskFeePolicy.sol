// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { SponsoredTaskTypes } from "./SponsoredTaskTypes.sol";
import { ISponsoredTaskFeePolicy } from "./interfaces/ISponsoredTaskFeePolicy.sol";

/// @title SponsoredTaskFeePolicy
/// @notice Daydreams-controlled fee terms snapshotted by a vault when it reserves a task.
contract SponsoredTaskFeePolicy is ISponsoredTaskFeePolicy, Ownable2Step {
    uint16 public constant MAX_BPS = 10_000;

    uint16 private _feeBps;
    address private _feeRecipient;

    error FeeBpsTooHigh(uint16 provided);
    error FeeRecipientRequired();

    event FeeTermsUpdated(uint16 feeBps, address indexed feeRecipient);

    constructor(address initialOwner, uint16 initialFeeBps, address initialFeeRecipient) Ownable(initialOwner) {
        _setFeeTerms(initialFeeBps, initialFeeRecipient);
    }

    function feeTerms() external view returns (SponsoredTaskTypes.FeeTerms memory) {
        return SponsoredTaskTypes.FeeTerms({ bps: _feeBps, recipient: _feeRecipient });
    }

    /// @notice Updates the fee for future reservations only. Existing allocations keep their snapshot.
    /// @dev A zero fee may use a zero recipient; any non-zero fee requires a recipient.
    function setFeeTerms(uint16 newFeeBps, address newFeeRecipient) external onlyOwner {
        _setFeeTerms(newFeeBps, newFeeRecipient);
    }

    function _setFeeTerms(uint16 newFeeBps, address newFeeRecipient) private {
        if (newFeeBps > MAX_BPS) revert FeeBpsTooHigh(newFeeBps);
        if (newFeeBps != 0 && newFeeRecipient == address(0)) revert FeeRecipientRequired();
        _feeBps = newFeeBps;
        _feeRecipient = newFeeRecipient;
        emit FeeTermsUpdated(newFeeBps, newFeeRecipient);
    }
}
