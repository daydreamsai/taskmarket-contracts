// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The per-chain submission winner cap (`AdminFacet.setMaxSubmissionWinners`), shared by the
///         fresh deploy and the rev030 upgrade so a new diamond and an upgraded one get the same cap.
library WinnerCap {
    /// @notice The winner cap on Tempo: a Bounty payout to fresh recipients costs about 0.78M gas
    ///         per winner there, so 30 settles well inside the 30M transaction cap.
    uint16 internal constant TEMPO_MAX_SUBMISSION_WINNERS = 30;

    /// @notice The winner cap to set on `chainId`, or 0 to keep the default of 50.
    function forChain(uint256 chainId) internal pure returns (uint16) {
        if (chainId == 4217 || chainId == 42431) return TEMPO_MAX_SUBMISSION_WINNERS;
        return 0;
    }
}
