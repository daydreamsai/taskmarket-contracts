// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPProject } from "../../src/interfaces/ITMPProject.sol";

/// @dev A grant with no limits: zero in every field.
function noGrantLimits() pure returns (ITMPProject.GrantLimitsInput memory l) { }

/// @dev The hash acceptGrant takes for `terms` with no limits.
function grantHash(ITMPProject.GrantTerms memory terms) pure returns (bytes32) {
    return keccak256(abi.encode(terms, noGrantLimits()));
}

/// @dev The hash acceptGrant takes for `terms` and `limits`.
function grantHash(ITMPProject.GrantTerms memory terms, ITMPProject.GrantLimitsInput memory limits)
    pure
    returns (bytes32)
{
    return keccak256(abi.encode(terms, limits));
}

/// @dev The hash acceptGrant takes for the grant as stored: its terms and the input fields of its limits.
function storedGrantHash(ITMPProject projects, uint256 projectId, address operator) view returns (bytes32) {
    ITMPProject.GrantLimits memory l = projects.getGrantLimits(projectId, operator);
    return grantHash(
        projects.getGrant(projectId, operator).terms,
        ITMPProject.GrantLimitsInput({
            expiresAt: l.expiresAt,
            allowedModesMask: l.allowedModesMask,
            maxRewardPerTask: l.maxRewardPerTask,
            periodSecs: l.periodSecs,
            periodCap: l.periodCap
        })
    );
}
