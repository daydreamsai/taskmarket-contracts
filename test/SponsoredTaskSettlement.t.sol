// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { SponsoredTaskSettlement } from "../src/hooks/sponsored-task/libraries/SponsoredTaskSettlement.sol";

contract SponsoredTaskSettlementHarness {
    function calculate(
        bytes32 vaultId,
        uint64 vaultEpoch,
        bytes32 allocationId,
        bytes32 taskId,
        uint256 grossAmount,
        uint256 nativePayoutPool,
        uint16 feeBps,
        ITMPCore.VerdictType verdictType,
        ITMPCore.Award[] memory awards
    ) external pure returns (SponsoredTaskSettlement.Result memory) {
        return SponsoredTaskSettlement.calculate(
            SponsoredTaskSettlement.SettlementIdentity({
                vaultId: vaultId, vaultEpoch: vaultEpoch, allocationId: allocationId, taskId: taskId
            }),
            grossAmount,
            nativePayoutPool,
            feeBps,
            verdictType,
            awards
        );
    }
}

contract SponsoredTaskSettlementTest is Test {
    SponsoredTaskSettlementHarness private harness;

    bytes32 private constant VAULT_ID = keccak256("vault");
    bytes32 private constant ALLOCATION_ID = keccak256("allocation");
    bytes32 private constant TASK_ID = keccak256("task");
    uint64 private constant EPOCH = 7;

    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() external {
        harness = new SponsoredTaskSettlementHarness();
    }

    function testSingleWinnerReceivesFullGrossLessPerAwardFee() external view {
        ITMPCore.Award[] memory awards = _awards(1);
        awards[0] = ITMPCore.Award({ worker: ALICE, amount: 1, rank: 1 });

        SponsoredTaskSettlement.Result memory result = _calculate(1_000, 1, 50, ITMPCore.VerdictType.APPROVE, awards);

        assertEq(result.distributedGross, 1_000);
        assertEq(result.sponsoredTaskTotal, 995);
        assertEq(result.feeTotal, 5);
        assertEq(result.releasedGross, 0);
        assertEq(result.leafCount, 1);
        assertEq(result.entitlements[0].netAmount, 995);
        assertEq(result.rewardsRoot, result.entitlements[0].leaf);
    }

    function testSeventyThirtyUsesCanonicalAwardProportions() external view {
        ITMPCore.Award[] memory awards = _awards(2);
        awards[0] = ITMPCore.Award({ worker: ALICE, amount: 700_000, rank: 1 });
        awards[1] = ITMPCore.Award({ worker: BOB, amount: 300_000, rank: 2 });

        SponsoredTaskSettlement.Result memory result =
            _calculate(10_000, 1_000_000, 50, ITMPCore.VerdictType.APPROVE, awards);

        assertEq(result.entitlements[0].grossAmount, 7_000);
        assertEq(result.entitlements[0].feeAmount, 35);
        assertEq(result.entitlements[0].netAmount, 6_965);
        assertEq(result.entitlements[1].grossAmount, 3_000);
        assertEq(result.entitlements[1].feeAmount, 15);
        assertEq(result.entitlements[1].netAmount, 2_985);
        assertEq(result.sponsoredTaskTotal + result.feeTotal + result.releasedGross, 10_000);
        assertEq(result.rewardsRoot, _hashPair(result.entitlements[0].leaf, result.entitlements[1].leaf));
    }

    function testAwardOrderingChangesIndexesButNotWorkerProportionsOrConservation() external view {
        ITMPCore.Award[] memory aliceFirst = _awards(2);
        aliceFirst[0] = ITMPCore.Award({ worker: ALICE, amount: 700_000, rank: 1 });
        aliceFirst[1] = ITMPCore.Award({ worker: BOB, amount: 300_000, rank: 2 });

        ITMPCore.Award[] memory bobFirst = _awards(2);
        bobFirst[0] = ITMPCore.Award({ worker: BOB, amount: 300_000, rank: 2 });
        bobFirst[1] = ITMPCore.Award({ worker: ALICE, amount: 700_000, rank: 1 });

        SponsoredTaskSettlement.Result memory original =
            _calculate(10_000, 1_000_000, 50, ITMPCore.VerdictType.APPROVE, aliceFirst);
        SponsoredTaskSettlement.Result memory reordered =
            _calculate(10_000, 1_000_000, 50, ITMPCore.VerdictType.APPROVE, bobFirst);

        assertEq(original.entitlements[0].worker, ALICE);
        assertEq(original.entitlements[0].grossAmount, 7_000);
        assertEq(original.entitlements[1].worker, BOB);
        assertEq(original.entitlements[1].grossAmount, 3_000);

        assertEq(reordered.entitlements[0].worker, BOB);
        assertEq(reordered.entitlements[0].grossAmount, 3_000);
        assertEq(reordered.entitlements[1].worker, ALICE);
        assertEq(reordered.entitlements[1].grossAmount, 7_000);

        assertEq(original.distributedGross, reordered.distributedGross);
        assertEq(original.sponsoredTaskTotal, reordered.sponsoredTaskTotal);
        assertEq(original.feeTotal, reordered.feeTotal);
        assertEq(original.releasedGross, reordered.releasedGross);
        assertEq(original.distributedGross + original.releasedGross, 10_000);
        assertEq(reordered.distributedGross + reordered.releasedGross, 10_000);
        assertTrue(original.rewardsRoot != reordered.rewardsRoot, "leaf indexes intentionally commit ordering");
    }

    function testPartialScalesGrossAndRestoresUnawardedAmount() external view {
        ITMPCore.Award[] memory awards = _awards(2);
        awards[0] = ITMPCore.Award({ worker: ALICE, amount: 360_000, rank: 1 });
        awards[1] = ITMPCore.Award({ worker: BOB, amount: 240_000, rank: 2 });

        SponsoredTaskSettlement.Result memory result =
            _calculate(10_000, 1_000_000, 50, ITMPCore.VerdictType.PARTIAL, awards);

        assertEq(result.distributedGross, 6_000);
        assertEq(result.releasedGross, 4_000);
        assertEq(result.entitlements[0].grossAmount, 3_600);
        assertEq(result.entitlements[1].grossAmount, 2_400);
        assertEq(result.feeTotal, 30);
        assertEq(result.sponsoredTaskTotal, 5_970);
    }

    function testRoundingDustReturnsAvailable() external view {
        ITMPCore.Award[] memory awards = _awards(3);
        awards[0] = ITMPCore.Award({ worker: ALICE, amount: 1, rank: 1 });
        awards[1] = ITMPCore.Award({ worker: BOB, amount: 1, rank: 2 });
        awards[2] = ITMPCore.Award({ worker: address(0xCAFE), amount: 1, rank: 3 });

        SponsoredTaskSettlement.Result memory result = _calculate(100, 3, 50, ITMPCore.VerdictType.APPROVE, awards);

        assertEq(result.distributedGross, 99);
        assertEq(result.releasedGross, 1);
        assertEq(result.feeTotal, 0);
        assertEq(result.sponsoredTaskTotal, 99);
    }

    function testZeroAwardsAreSkippedAndLeafIndexesStayContiguous() external view {
        ITMPCore.Award[] memory awards = _awards(3);
        awards[0] = ITMPCore.Award({ worker: address(0), amount: 0, rank: 1 });
        awards[1] = ITMPCore.Award({ worker: ALICE, amount: 2, rank: 2 });
        awards[2] = ITMPCore.Award({ worker: BOB, amount: 1, rank: 3 });

        SponsoredTaskSettlement.Result memory result = _calculate(300, 3, 0, ITMPCore.VerdictType.APPROVE, awards);

        assertEq(result.leafCount, 2);
        assertEq(result.entitlements[0].awardIndex, 1);
        assertEq(result.entitlements[0].leafIndex, 0);
        assertEq(result.entitlements[1].awardIndex, 2);
        assertEq(result.entitlements[1].leafIndex, 1);
    }

    function testRejectOrNoAwardsReleasesEntireReservation() external view {
        ITMPCore.Award[] memory awards = _awards(1);
        awards[0] = ITMPCore.Award({ worker: ALICE, amount: 1, rank: 1 });
        SponsoredTaskSettlement.Result memory rejected = _calculate(500, 1, 50, ITMPCore.VerdictType.REJECT, awards);
        assertEq(rejected.distributedGross, 0);
        assertEq(rejected.releasedGross, 500);
        assertEq(rejected.rewardsRoot, bytes32(0));

        ITMPCore.Award[] memory empty = _awards(0);
        SponsoredTaskSettlement.Result memory noAwards = _calculate(500, 1, 50, ITMPCore.VerdictType.APPROVE, empty);
        assertEq(noAwards.releasedGross, 500);
    }

    function testRepeatedWorkerEntriesRemainIndependentLeaves() external view {
        ITMPCore.Award[] memory awards = _awards(2);
        awards[0] = ITMPCore.Award({ worker: ALICE, amount: 1, rank: 1 });
        awards[1] = ITMPCore.Award({ worker: ALICE, amount: 1, rank: 2 });
        SponsoredTaskSettlement.Result memory result = _calculate(200, 2, 0, ITMPCore.VerdictType.APPROVE, awards);

        assertEq(result.entitlements[0].worker, ALICE);
        assertEq(result.entitlements[1].worker, ALICE);
        assertTrue(result.entitlements[0].leaf != result.entitlements[1].leaf);
    }

    function testPartialCapsOverAwardAtFullGross() external view {
        ITMPCore.Award[] memory awards = _awards(1);
        awards[0] = ITMPCore.Award({ worker: ALICE, amount: 2_000, rank: 1 });
        SponsoredTaskSettlement.Result memory result = _calculate(1_000, 1_000, 0, ITMPCore.VerdictType.PARTIAL, awards);
        assertEq(result.distributedGross, 1_000);
        assertEq(result.releasedGross, 0);
    }

    function testTinyGrossDoesNotCreateZeroValueClaimLeaves() external view {
        ITMPCore.Award[] memory awards = _awards(2);
        awards[0] = ITMPCore.Award({ worker: ALICE, amount: 1, rank: 1 });
        awards[1] = ITMPCore.Award({ worker: BOB, amount: 1, rank: 2 });
        SponsoredTaskSettlement.Result memory result = _calculate(1, 2, 50, ITMPCore.VerdictType.APPROVE, awards);

        assertEq(result.distributedGross, 0);
        assertEq(result.releasedGross, 1);
        assertEq(result.sponsoredTaskTotal, 0);
        assertEq(result.feeTotal, 0);
        assertEq(result.leafCount, 0);
        assertEq(result.rewardsRoot, bytes32(0));
    }

    function testOneHundredPercentFeeCreatesNoBuilderLeaves() external view {
        ITMPCore.Award[] memory awards = _awards(1);
        awards[0] = ITMPCore.Award({ worker: ALICE, amount: 1, rank: 1 });
        SponsoredTaskSettlement.Result memory result =
            _calculate(1_000, 1, 10_000, ITMPCore.VerdictType.APPROVE, awards);

        assertEq(result.distributedGross, 1_000);
        assertEq(result.sponsoredTaskTotal, 0);
        assertEq(result.feeTotal, 1_000);
        assertEq(result.leafCount, 0);
        assertEq(result.rewardsRoot, bytes32(0));
    }

    function testThreeLeafRootAndOfficialProofMatchOpenZeppelinStandardMerkleTree() external pure {
        bytes32[] memory leaves = _officialFixtureLeaves(3);
        bytes32 root = SponsoredTaskSettlement.merkleRoot(leaves);
        assertEq(root, 0x3030e444bfbd5b19d46111b0a5c3a68e43dd8bd8eb5b2f9bf25d6c0109a37f48);

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = 0x75bb0b2ec87c8381ba6c6909b3df4f4df7747ab081e8b134e2d4752bb2e31bd5;
        proof[1] = 0xfa52d89104034343188abe37a8cb8d44467a73c3a956d5a2724576ebbb6018dc;
        assertTrue(MerkleProof.verify(proof, root, _officialFixtureLeaf(0)));
    }

    function testFiveLeafRootAndOfficialProofMatchOpenZeppelinStandardMerkleTree() external pure {
        bytes32[] memory leaves = _officialFixtureLeaves(5);
        bytes32 root = SponsoredTaskSettlement.merkleRoot(leaves);
        assertEq(root, 0x626dd42aaf1c07acf66148d14115371acf09d33968493311ecb74f4ed9e8cac7);

        bytes32[] memory proof = new bytes32[](3);
        proof[0] = 0x75bb0b2ec87c8381ba6c6909b3df4f4df7747ab081e8b134e2d4752bb2e31bd5;
        proof[1] = 0xfa52d89104034343188abe37a8cb8d44467a73c3a956d5a2724576ebbb6018dc;
        proof[2] = 0x90aca1e055e8ea97ba428f87fbb74a916160e5a25e11172b43ab6cc82aed5eaf;
        assertTrue(MerkleProof.verify(proof, root, _officialFixtureLeaf(4)));
    }

    function testSixLeafRootAndOfficialProofMatchOpenZeppelinStandardMerkleTree() external pure {
        bytes32[] memory leaves = _officialFixtureLeaves(6);
        bytes32 root = SponsoredTaskSettlement.merkleRoot(leaves);
        assertEq(root, 0x6bf96ac1ec053c16aa16b565986e95f190894325542b32c859672c89997e4f5c);

        bytes32[] memory proof = new bytes32[](3);
        proof[0] = 0x0ec7368a1197866bf88fa7f49bad4e5863e9c1a2fa704a0b6fc58a3f9d97f541;
        proof[1] = 0x477452a1c1e70ced297bb4b5c4b2997b57e58ba0563497bf6ef01305e9d3bdab;
        proof[2] = 0x30a3c2c3b9aaa6b2be948aa5be300a98bfa8dd43e7ac6f661427201d8b9aeee1;
        assertTrue(MerkleProof.verify(proof, root, _officialFixtureLeaf(5)));
    }

    function _calculate(
        uint256 gross,
        uint256 payoutPool,
        uint16 feeBps,
        ITMPCore.VerdictType verdictType,
        ITMPCore.Award[] memory awards
    ) private view returns (SponsoredTaskSettlement.Result memory) {
        return harness.calculate(
            VAULT_ID, EPOCH, ALLOCATION_ID, TASK_ID, gross, payoutPool, feeBps, verdictType, awards
        );
    }

    function _awards(uint256 length) private pure returns (ITMPCore.Award[] memory) {
        return new ITMPCore.Award[](length);
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _officialFixtureLeaves(uint256 count) private pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            leaves[i] = _officialFixtureLeaf(i);
        }
    }

    function _officialFixtureLeaf(uint256 index) private pure returns (bytes32) {
        return SponsoredTaskSettlement.entitlementLeaf(
            SponsoredTaskSettlement.SettlementIdentity({
                vaultId: 0x1111111111111111111111111111111111111111111111111111111111111111,
                vaultEpoch: 7,
                allocationId: 0x2222222222222222222222222222222222222222222222222222222222222222,
                taskId: 0x3333333333333333333333333333333333333333333333333333333333333333
            }),
            index,
            address(uint160(0x1000 + index)),
            1_000 + index
        );
    }
}
