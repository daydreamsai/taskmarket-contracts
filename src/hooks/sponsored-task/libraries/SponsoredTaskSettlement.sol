// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ITMPCore } from "../../../interfaces/ITMPCore.sol";

/// @title SponsoredTaskSettlement
/// @notice Deterministically translates Taskmarket awards into project-token entitlements.
/// @dev Leaves and tree shape match OpenZeppelin StandardMerkleTree: double-hashed values,
///      sorted leaves, a complete 2N-1 binary tree, and commutative pair hashing.
library SponsoredTaskSettlement {
    using Math for uint256;

    bytes32 internal constant AWARDS_DIGEST_DOMAIN = keccak256("SponsoredTask.awards.v1");

    struct Result {
        bytes32 rewardsRoot;
        uint32 leafCount;
        uint256 sponsoredTaskTotal;
        uint256 feeTotal;
        uint256 distributedGross;
        uint256 releasedGross;
        Entitlement[] entitlements;
    }

    /// @dev Bundles the four identity fields `calculate`/`entitlementLeaf` always take together,
    ///      so both functions carry fewer simultaneously-live locals -- the unbundled 9-arg form
    ///      tripped `forge coverage --ir-minimum`'s stack-too-deep limit.
    struct SettlementIdentity {
        bytes32 vaultId;
        uint64 vaultEpoch;
        bytes32 allocationId;
        bytes32 taskId;
    }

    struct Entitlement {
        uint256 awardIndex;
        uint256 leafIndex;
        address worker;
        uint256 grossAmount;
        uint256 feeAmount;
        uint256 netAmount;
        bytes32 leaf;
    }

    error FeeBpsTooHigh(uint16 feeBps);
    error InvalidAwardRecipient(uint256 index);
    error TooManyAwards(uint256 count);
    error ZeroPayoutPool();

    /// @notice A compact, order-sensitive commitment suitable for Taskmarket's hook gas boundary.
    function awardsDigest(bytes32 taskId, ITMPCore.Verdict calldata verdict) internal pure returns (bytes32 digest) {
        uint256 count = verdict.awards.length;
        digest = keccak256(abi.encode(AWARDS_DIGEST_DOMAIN, taskId, verdict.verdictType, count));
        for (uint256 i; i < count; ++i) {
            ITMPCore.Award calldata award = verdict.awards[i];
            digest = keccak256(abi.encode(digest, i, award.worker, award.amount, award.rank));
        }
    }

    /// @notice The memory equivalent used by permissionless settlement and reconciliation.
    function awardsDigestMemory(bytes32 taskId, ITMPCore.VerdictType verdictType, ITMPCore.Award[] memory awards)
        internal
        pure
        returns (bytes32 digest)
    {
        uint256 count = awards.length;
        digest = keccak256(abi.encode(AWARDS_DIGEST_DOMAIN, taskId, verdictType, count));
        for (uint256 i; i < count; ++i) {
            ITMPCore.Award memory award = awards[i];
            digest = keccak256(abi.encode(digest, i, award.worker, award.amount, award.rank));
        }
    }

    /// @notice Computes the authoritative reward root and exact vault accounting.
    /// @param nativePayoutPool Taskmarket reward remaining after any evaluator fee.
    /// @dev APPROVE distributes the entire gross sponsor across nonzero awards. PARTIAL scales
    ///      gross by min(total awards, payout pool) / payout pool. REJECT distributes nothing.
    function calculate(
        SettlementIdentity memory identity,
        uint256 grossAmount,
        uint256 nativePayoutPool,
        uint16 feeBps,
        ITMPCore.VerdictType verdictType,
        ITMPCore.Award[] memory awards
    ) internal pure returns (Result memory result) {
        if (feeBps > 10_000) revert FeeBpsTooHigh(feeBps);
        uint256 awardLength = awards.length;
        if (awardLength > type(uint32).max) revert TooManyAwards(awardLength);

        uint256 totalAwardWeight;
        for (uint256 i; i < awardLength; ++i) {
            uint256 amount = awards[i].amount;
            if (amount == 0) continue;
            if (awards[i].worker == address(0)) revert InvalidAwardRecipient(i);
            totalAwardWeight += amount;
        }

        if (grossAmount == 0 || totalAwardWeight == 0 || verdictType == ITMPCore.VerdictType.REJECT) {
            result.releasedGross = grossAmount;
            return result;
        }

        uint256 targetGross;
        if (verdictType == ITMPCore.VerdictType.APPROVE) {
            targetGross = grossAmount;
        } else {
            if (nativePayoutPool == 0) revert ZeroPayoutPool();
            uint256 awarded = totalAwardWeight > nativePayoutPool ? nativePayoutPool : totalAwardWeight;
            targetGross = Math.mulDiv(grossAmount, awarded, nativePayoutPool);
        }

        uint256 claimableCount;
        for (uint256 i; i < awardLength; ++i) {
            if (awards[i].amount == 0) continue;
            uint256 winnerGross = Math.mulDiv(targetGross, awards[i].amount, totalAwardWeight);
            uint256 winnerFee = Math.mulDiv(winnerGross, feeBps, 10_000);
            if (winnerGross > winnerFee) ++claimableCount;
        }

        result.entitlements = new Entitlement[](claimableCount);
        bytes32[] memory leaves = new bytes32[](claimableCount);
        uint256 leafCursor;
        for (uint256 i; i < awardLength; ++i) {
            ITMPCore.Award memory award = awards[i];
            if (award.amount == 0) continue;

            uint256 winnerGross = Math.mulDiv(targetGross, award.amount, totalAwardWeight);
            uint256 winnerFee = Math.mulDiv(winnerGross, feeBps, 10_000);
            uint256 winnerNet = winnerGross - winnerFee;

            result.distributedGross += winnerGross;
            result.feeTotal += winnerFee;
            result.sponsoredTaskTotal += winnerNet;
            if (winnerNet > 0) {
                bytes32 leaf = entitlementLeaf(identity, leafCursor, award.worker, winnerNet);
                result.entitlements[leafCursor] = Entitlement({
                    awardIndex: i,
                    leafIndex: leafCursor,
                    worker: award.worker,
                    grossAmount: winnerGross,
                    feeAmount: winnerFee,
                    netAmount: winnerNet,
                    leaf: leaf
                });
                leaves[leafCursor++] = leaf;
            }
        }

        // Safe because awardLength was bounded by uint32 above and claimableCount <= awardLength.
        // forge-lint: disable-next-line(unsafe-typecast)
        result.leafCount = uint32(claimableCount);
        result.releasedGross = grossAmount - result.distributedGross;
        result.rewardsRoot = merkleRoot(leaves);
    }

    function entitlementLeaf(SettlementIdentity memory identity, uint256 leafIndex, address worker, uint256 netAmount)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        identity.vaultId,
                        identity.vaultEpoch,
                        identity.allocationId,
                        identity.taskId,
                        leafIndex,
                        worker,
                        netAmount
                    )
                )
            )
        );
    }

    function merkleRoot(bytes32[] memory nodes) internal pure returns (bytes32) {
        uint256 leafCount = nodes.length;
        if (leafCount == 0) return bytes32(0);

        // StandardMerkleTree sorts by leaf hash by default. N is bounded by the hook (8 in V1),
        // so an in-memory insertion sort keeps the implementation compact and deterministic.
        for (uint256 i = 1; i < leafCount; ++i) {
            bytes32 value = nodes[i];
            uint256 j = i;
            while (j > 0 && nodes[j - 1] > value) {
                nodes[j] = nodes[j - 1];
                --j;
            }
            nodes[j] = value;
        }
        if (leafCount == 1) return nodes[0];

        bytes32[] memory tree = new bytes32[](2 * leafCount - 1);
        uint256 treeLength = tree.length;
        for (uint256 i; i < leafCount; ++i) {
            tree[treeLength - 1 - i] = nodes[i];
        }
        uint256 parentsRemaining = leafCount - 1;
        while (parentsRemaining > 0) {
            uint256 i = --parentsRemaining;
            tree[i] = _hashPair(tree[2 * i + 1], tree[2 * i + 2]);
        }
        return tree[0];
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
