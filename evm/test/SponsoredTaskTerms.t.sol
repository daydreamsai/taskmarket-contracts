// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SponsoredTaskTerms } from "../src/hooks/sponsored-task/libraries/SponsoredTaskTerms.sol";

/// @notice Pins one fixed `Terms` vector's hash to a literal constant.
/// @dev The backend's `computeSponsoredTaskTermsHash` (apps/backend/src/lib/
/// sponsored-task-terms-hash.ts) is tested against the exact same fixed inputs and the same
/// expected constant -- see apps/backend/test/unit/lib/sponsored-task-terms-hash.test.ts. A
/// mismatch between the two off-chain/on-chain implementations fails here or there before it
/// can fail silently on-chain as TaskTermsMismatch.
contract SponsoredTaskTermsTest is Test {
    function test_hash_matchesPinnedVector() external pure {
        SponsoredTaskTerms.Terms memory terms = SponsoredTaskTerms.Terms({
            reward: 5_000_000,
            duration: 86_400,
            mode: bytes4(0x11111111),
            pitchDuration: 0,
            bidDuration: 0,
            auctionSubtype: bytes4(0x00000000),
            stakeRequired: false,
            stakeBps: 0,
            feeBps: 750,
            evaluator: address(0),
            evaluatorStake: 0,
            evaluatorFeeBps: 0,
            evaluationWindow: 0,
            appealWindow: 0,
            disputeResolver: address(0),
            contentHash: bytes32(0),
            contentURIHash: keccak256(""),
            tagsHash: keccak256(abi.encode(new bytes32[](0))),
            hooksHash: keccak256(abi.encode(_fixedHooks()))
        });

        // The core half is the rev027 commitment, unchanged.
        bytes32 expectedCore = 0x1e08988d3ea6ba5b3e0cbfb9e8f195e5513e8f2d27a773856a8237564b1baf63;
        bytes32 core = keccak256(abi.encode(SponsoredTaskTerms.TASK_TERMS_TYPEHASH, terms));
        assertEq(core, expectedCore);

        // The settlement half and the combined commitment are new in rev028.
        SponsoredTaskTerms.SettlementTerms memory settlement = SponsoredTaskTerms.SettlementTerms({
            penaltyTo: 0,
            reviewWindowSecs: 259_200,
            decisionWindowSecs: 172_800,
            reopenExtensionSecs: 86_400,
            releaseAllowed: 1,
            releaseGraceBps: 1,
            rejectOutcome: 0,
            rejectFeeBps: 1,
            maxRevisions: 3,
            resolutionWindowSecs: 604_800,
            acceptWindowSecs: 0
        });
        bytes32 expectedSettlement = 0x954ac646ebd620b75895d9113a5dd86c362474c9f59abe611befdd327d393102;
        bytes32 settlementHash = keccak256(abi.encode(SponsoredTaskTerms.SETTLEMENT_TERMS_TYPEHASH, settlement));
        assertEq(settlementHash, expectedSettlement);

        bytes32 expectedCombined = 0x552aa98fc2dd909bf5f3123197d22d2647ab3d99fea357a6cf25aaf11ffcdb76;
        bytes32 combined = keccak256(abi.encode(SponsoredTaskTerms.TERMS_HASH_TYPEHASH, core, settlementHash));
        assertEq(combined, expectedCombined);
    }

    function _fixedHooks() private pure returns (address[] memory hooks) {
        hooks = new address[](1);
        hooks[0] = 0x1111111111111111111111111111111111100011;
    }
}
