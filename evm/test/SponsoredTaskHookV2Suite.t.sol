// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Generated from SponsoredTaskHook.t.sol for the rev028 V2 port: the same cases, with the mock
// market driving the V2 callbacks the diamond maps the V1 ones to.

import { Test } from "forge-std/Test.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPHook } from "../src/interfaces/ITMPHook.sol";
import { TMP_AUCTION, TMP_BOUNTY, TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { SponsoredTaskTypes } from "../src/hooks/sponsored-task/SponsoredTaskTypes.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTaskFactoryV2 } from "../src/hooks/sponsored-task/SponsoredTaskFactoryV2.sol";
import { SponsoredTaskFeeConfig } from "./helpers/SponsoredTaskFeeConfig.sol";
import { SponsoredTasksVaultV2 } from "../src/hooks/sponsored-task/SponsoredTasksVaultV2.sol";
import { SponsoredTaskHookV2 } from "../src/hooks/sponsored-task/SponsoredTaskHookV2.sol";
import { ITMPHookV2 } from "../src/interfaces/ITMPHookV2.sol";
import { MockTaskmarketForSponsoredTask } from "./mocks/MockTaskmarketForSponsoredTask.sol";
import { MockSponsoredTasksVault } from "./mocks/MockSponsoredTasksVault.sol";

/// @dev The V1 mock market, also driving SponsoredTaskHookV2 through its V2 callbacks.
contract MockTaskmarketForSponsoredTaskV2 is MockTaskmarketForSponsoredTask {
    function _ctxV2(bytes32 taskId, address worker) internal view returns (ITMPHookV2.TaskContextV2 memory c) {
        ITMPCore.TaskContext memory v1 = this.getTaskContext(taskId);
        c.taskId = taskId;
        c.requester = v1.requester;
        c.worker = worker;
        c.paymentToken = v1.paymentToken;
        c.reward = v1.reward;
        c.mode = v1.mode;
        c.priorStatus = v1.currentState;
        c.currentState = v1.currentState;
    }

    function callCheckFundV2(ITMPHookV2 hook, bytes32 taskId, bytes calldata hookData) external returns (bool) {
        hook.beforeCreate(taskId, _ctxV2(taskId, address(0)), hookData, "");
        return true;
    }

    function callCheckCompleteV2(ITMPHookV2 hook, bytes32 taskId, ITMPCore.Verdict calldata verdict)
        external
        returns (bool)
    {
        hook.beforeAccept(taskId, _ctxV2(taskId, address(0)), verdict, "");
        return true;
    }

    function callCheckEvaluateV2(ITMPHookV2 hook, bytes32 taskId, address) external returns (bool) {
        ITMPCore.Verdict memory none;
        hook.beforeEvaluate(taskId, _ctxV2(taskId, address(0)), none, "");
        return true;
    }

    function callOnCompleteV2(ITMPHookV2 hook, bytes32 taskId, ITMPCore.Verdict calldata verdict) external {
        this.setVerdict(taskId, verdict);
        ITMPHookV2.SettlementAmounts memory none;
        hook.afterComplete(taskId, _ctxV2(taskId, address(0)), none, 0);
    }

    function callOnCancelV2(ITMPHookV2 hook, bytes32 taskId) external {
        ITMPHookV2.SettlementAmounts memory none;
        hook.afterCancel(taskId, _ctxV2(taskId, address(0)), none, 0);
    }

    function callOnExpireV2(ITMPHookV2 hook, bytes32 taskId) external {
        ITMPHookV2.SettlementAmounts memory none;
        hook.afterExpire(taskId, _ctxV2(taskId, address(0)), none, 0);
    }

    function callOnForfeitV2(ITMPHookV2 hook, bytes32 taskId, address worker) external {
        ITMPHookV2.SettlementAmounts memory none;
        hook.afterForfeit(taskId, _ctxV2(taskId, worker), none, 0);
    }
}

contract SponsoredTaskHookV2SuiteTest is Test {
    // taskAllocationSettlement returns a tuple, not the TaskAllocation struct -- the whole-struct
    // external getter tripped forge coverage --ir-minimum's stack-too-deep limit on its own ABI
    // encoding (see SponsoredTaskHookV2.taskAllocationSettlement's own doc comment).
    function _allocationStatus(SponsoredTaskHookV2 h, bytes32 taskId)
        private
        view
        returns (SponsoredTaskHookV2.HookStatus status)
    {
        (,,,,,,,, status) = h.taskAllocationSettlement(taskId);
    }

    function _allocationAwardCount(SponsoredTaskHookV2 h, bytes32 taskId) private view returns (uint32 awardCount) {
        (,, awardCount,,,,,,) = h.taskAllocationSettlement(taskId);
    }

    // Same split as above, for SponsoredTasksVaultV2.allocation -- reconstructs the full struct
    // from its two smaller getters so every existing field-access call site stays unchanged.
    function _vaultAllocation(SponsoredTasksVaultV2 v, bytes32 allocationId)
        private
        view
        returns (SponsoredTaskTypes.Allocation memory a)
    {
        (a.taskId, a.termsHash, a.manager, a.epoch, a.feeBps, a.feeRecipient, a.grossAmount, a.distributedGross) =
            v.allocationTerms(allocationId);
        (
            a.sponsoredTaskOutstanding,
            a.sponsoredTaskPaid,
            a.feeOutstanding,
            a.feePaid,
            a.releasedAmount,
            a.rewardsRoot,
            a.leafCount,
            a.status
        ) = v.allocationSettlement(allocationId);
    }

    bytes32 private constant TASK_ID = keccak256("task");
    uint256 private constant NATIVE_REWARD = 1_000_000;
    uint256 private constant GROSS = 10_000;
    uint16 private constant TOKEN_FEE_BPS = 50;

    address private constant MANAGER = address(0xCAFE);
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant TOKEN_FEE_RECIPIENT = address(0xFEE1);
    address private constant CREATION_FEE_RECIPIENT = address(0xFEE2);

    MockTaskmarketForSponsoredTaskV2 private market;
    MockERC20 private usdc;
    MockERC20 private projectToken;
    SponsoredTaskFeePolicy private feePolicy;
    SponsoredTaskRegistry private registry;
    SponsoredTaskFactoryV2 private factory;
    SponsoredTaskHookV2 private hook;
    SponsoredTasksVaultV2 private vault;

    function setUp() external {
        market = new MockTaskmarketForSponsoredTaskV2();
        usdc = new MockERC20("USD Coin", "USDC", 6, address(this));
        projectToken = new MockERC20("Project", "PROJECT", 18, address(this));
        feePolicy = new SponsoredTaskFeePolicy(address(this), TOKEN_FEE_BPS, TOKEN_FEE_RECIPIENT);
        registry = new SponsoredTaskRegistry(address(this));
        hook = new SponsoredTaskHookV2(address(market), IERC20(address(usdc)), registry);

        factory = new SponsoredTaskFactoryV2(
            address(hook), address(feePolicy), registry, SponsoredTaskFeeConfig.none(IERC20(address(usdc)))
        );
        registry.setFactory(address(factory), true);
        (address vaultAddress, bytes32 createdVaultId) =
            factory.createVault(address(projectToken), address(this), keccak256("hook-vault"));
        vault = SponsoredTasksVaultV2(vaultAddress);
        assertEq(createdVaultId, vault.vaultId());
        vault.configureManager(MANAGER, GROSS * 100, true);
        projectToken.mint(address(this), GROSS * 100);
        projectToken.approve(address(vault), type(uint256).max);
        vault.fund(GROSS * 100);

        usdc.mint(MANAGER, 10_000_000);

        market.primeTask(TASK_ID, MANAGER, address(usdc), NATIVE_REWARD, TMP_BOUNTY, address(hook));
    }

    function testLocalFundingAtomicallyReservesGrossAndChargesNoFee() external {
        _fundLocal();

        SponsoredTaskTypes.Allocation memory reserved = _vaultAllocation(vault, TASK_ID);
        assertEq(reserved.grossAmount, GROSS);
        assertEq(reserved.manager, MANAGER);
        assertEq(reserved.taskId, TASK_ID);
        assertEq(uint8(reserved.status), uint8(SponsoredTaskTypes.AllocationStatus.Reserved));
        // Task creation charges nothing; the one-time fee is paid when the vault is created.
        assertEq(usdc.balanceOf(MANAGER), 10_000_000);
        assertEq(usdc.balanceOf(CREATION_FEE_RECIPIENT), 0);
    }

    function testTaskTermsCommitmentBindsTaskmarketUsdcReward() external {
        bytes32 original = hook.currentTaskTermsHash(TASK_ID);
        market.setReward(TASK_ID, NATIVE_REWARD + 1);
        bytes32 changed = hook.currentTaskTermsHash(TASK_ID);
        assertTrue(original != changed);
    }

    function testManagerWithoutUsdcCanStillCreateATask() external {
        vm.prank(MANAGER);
        usdc.transfer(address(0xDEAD), 10_000_000);

        _fundLocal();
        assertEq(uint8(_vaultAllocation(vault, TASK_ID).status), uint8(SponsoredTaskTypes.AllocationStatus.Reserved));
    }

    function testUnregisteredLookalikeVaultCannotAdvertiseAnUnbackedSponsoredTask() external {
        bytes32 mockVault = keccak256("mock-vault");
        MockSponsoredTasksVault mock =
            new MockSponsoredTasksVault(mockVault, address(projectToken), address(this), address(hook));
        bytes32 termsHash = hook.currentTaskTermsHash(TASK_ID);
        SponsoredTaskHookV2.FundingRequest memory request = SponsoredTaskHookV2.FundingRequest({
            route: hook.ROUTE_BASE_LOCAL(),
            vault: address(mock),
            vaultId: mockVault,
            allocationId: bytes32(0),
            epoch: 1,
            feeBps: TOKEN_FEE_BPS,
            feeRecipient: TOKEN_FEE_RECIPIENT,
            grossAmount: GROSS,
            taskTermsHash: termsHash
        });
        bytes memory hookData = hook.encodeHookData(request);

        vm.expectRevert(SponsoredTaskHookV2.VaultMismatch.selector);
        market.callCheckFundV2(hook, TASK_ID, hookData);
        assertEq(uint8(_allocationStatus(hook, TASK_ID)), uint8(SponsoredTaskHookV2.HookStatus.None));
    }

    function testSeventyThirtyCompletionInstallsClaimsAndReturnsNoDust() external {
        _fundLocal();
        ITMPCore.Award[] memory awards = _twoAwards(700_000, 300_000);
        _commitAccepted(ITMPCore.VerdictType.APPROVE, awards);
        bytes32 root = hook.finalizeSettlement(TASK_ID, awards);

        SponsoredTaskTypes.Allocation memory settled = _vaultAllocation(vault, TASK_ID);
        assertEq(settled.rewardsRoot, root);
        assertEq(settled.distributedGross, GROSS);
        assertEq(settled.sponsoredTaskOutstanding, 9_950);
        assertEq(settled.feeOutstanding, 50);
        assertEq(settled.releasedAmount, 0);

        bytes32 aliceLeaf = vault.claimLeaf(TASK_ID, TASK_ID, 1, 0, ALICE, 6_965);
        bytes32 bobLeaf = vault.claimLeaf(TASK_ID, TASK_ID, 1, 1, BOB, 2_985);
        bytes32[] memory aliceProof = new bytes32[](1);
        aliceProof[0] = bobLeaf;
        bytes32[] memory bobProof = new bytes32[](1);
        bobProof[0] = aliceLeaf;

        vm.prank(BOB);
        vault.claim(TASK_ID, 1, 2_985, bobProof);
        vm.prank(ALICE);
        vault.claim(TASK_ID, 0, 6_965, aliceProof);
        assertEq(projectToken.balanceOf(ALICE), 6_965);
        assertEq(projectToken.balanceOf(BOB), 2_985);

        vm.prank(TOKEN_FEE_RECIPIENT);
        vault.claimFee(TASK_ID, TOKEN_FEE_RECIPIENT);
        assertEq(projectToken.balanceOf(TOKEN_FEE_RECIPIENT), 50);
    }

    function testPartialCompletionRestoresUnawardedCapacity() external {
        _fundLocal();
        ITMPCore.Award[] memory awards = _twoAwards(360_000, 240_000);
        _commitAccepted(ITMPCore.VerdictType.PARTIAL, awards);
        hook.finalizeSettlement(TASK_ID, awards);

        SponsoredTaskTypes.Allocation memory settled = _vaultAllocation(vault, TASK_ID);
        SponsoredTaskTypes.ManagerAccount memory manager = vault.managerAccount(MANAGER);
        assertEq(settled.distributedGross, 6_000);
        assertEq(settled.releasedAmount, 4_000);
        assertEq(manager.reserved, 0);
        assertEq(manager.spent, 6_000);
        assertEq(vault.managerRemaining(MANAGER), GROSS * 100 - 6_000);
    }

    function testCancellationReleasesOnce() external {
        _fundLocal();
        market.setStatus(TASK_ID, ITMPCore.TaskStatus.Cancelled);
        market.callOnCancelV2(hook, TASK_ID);

        assertEq(uint8(_vaultAllocation(vault, TASK_ID).status), uint8(SponsoredTaskTypes.AllocationStatus.Released));
        assertEq(vault.totalReserved(), 0);
        assertEq(uint8(_allocationStatus(hook, TASK_ID)), uint8(SponsoredTaskHookV2.HookStatus.Released));
        assertEq(uint8(hook.finalizeRelease(TASK_ID)), uint8(SponsoredTaskHookV2.HookStatus.Released));
    }

    function testMissedExpiryCallbackIsPermissionlesslyReconciled() external {
        _fundLocal();
        market.setStatus(TASK_ID, ITMPCore.TaskStatus.Expired);
        assertEq(uint8(hook.reconcile(TASK_ID)), uint8(SponsoredTaskHookV2.HookStatus.Released));
        assertEq(vault.totalReserved(), 0);
    }

    function testForfeitAndReopenRetainsOriginalReservation() external {
        market.primeTask(keccak256("claim"), MANAGER, address(usdc), 1, TMP_CLAIM, address(hook));
        bytes32 claimTaskId = keccak256("claim");
        _fundLocalTask(claimTaskId);
        market.callOnForfeitV2(hook, claimTaskId, ALICE);

        SponsoredTaskTypes.Allocation memory allocation = _vaultAllocation(vault, claimTaskId);
        assertEq(uint8(allocation.status), uint8(SponsoredTaskTypes.AllocationStatus.Reserved));
        assertEq(allocation.grossAmount, GROSS);
    }

    function testOwnerExitDefaultsSponsoredTaskWithoutBlockingTaskCompletion() external {
        _fundLocal();
        vault.emergencyExitVault(address(this));
        ITMPCore.Award[] memory awards = _twoAwards(700_000, 300_000);
        _commitAccepted(ITMPCore.VerdictType.APPROVE, awards);

        assertEq(hook.finalizeSettlement(TASK_ID, awards), bytes32(0));
        assertEq(uint8(_allocationStatus(hook, TASK_ID)), uint8(SponsoredTaskHookV2.HookStatus.DefaultedByOwner));
    }

    function testOwnerDefaultRefreshedBeforeCompletionDoesNotBlockTaskmarketCompletion() external {
        _fundLocal();
        vault.emergencyExitVault(address(this));
        assertTrue(hook.refreshOwnerDefault(TASK_ID));

        market.setStatus(TASK_ID, ITMPCore.TaskStatus.Accepted);
        ITMPCore.Award[] memory awards = _twoAwards(700_000, 300_000);
        ITMPCore.Verdict memory verdict = _verdict(ITMPCore.VerdictType.APPROVE, awards);

        assertTrue(market.callCheckCompleteV2(hook, TASK_ID, verdict));
        assertEq(hook.finalizeSettlement(TASK_ID, awards), bytes32(0));
        assertEq(uint8(_allocationStatus(hook, TASK_ID)), uint8(SponsoredTaskHookV2.HookStatus.DefaultedByOwner));
    }

    function testOwnerDefaultRefreshedBeforeEvaluationDoesNotBlockTaskmarketEvaluation() external {
        _fundLocal();
        vault.emergencyExitVault(address(this));
        assertTrue(hook.refreshOwnerDefault(TASK_ID));

        ITMPCore.Award[] memory awards = _twoAwards(700_000, 300_000);
        market.setVerdict(TASK_ID, _verdict(ITMPCore.VerdictType.APPROVE, awards));

        assertTrue(market.callCheckEvaluateV2(hook, TASK_ID, address(0xE1A1)));
        assertEq(uint8(_allocationStatus(hook, TASK_ID)), uint8(SponsoredTaskHookV2.HookStatus.DefaultedByOwner));
    }

    function testOwnerExitDefaultsInstalledButUnclaimedSponsoredTask() external {
        _fundLocal();
        ITMPCore.Award[] memory awards = _twoAwards(700_000, 300_000);
        _commitAccepted(ITMPCore.VerdictType.APPROVE, awards);
        hook.finalizeSettlement(TASK_ID, awards);

        vault.emergencyExitVault(address(this));
        assertTrue(hook.refreshOwnerDefault(TASK_ID));
        assertEq(uint8(_allocationStatus(hook, TASK_ID)), uint8(SponsoredTaskHookV2.HookStatus.DefaultedByOwner));
    }

    function testOwnerExitDoesNotRelabelFullyPaidSponsoredTaskAsDefaulted() external {
        _fundLocal();
        ITMPCore.Award[] memory awards = _twoAwards(700_000, 300_000);
        _commitAccepted(ITMPCore.VerdictType.APPROVE, awards);
        hook.finalizeSettlement(TASK_ID, awards);

        bytes32 aliceLeaf = vault.claimLeaf(TASK_ID, TASK_ID, 1, 0, ALICE, 6_965);
        bytes32 bobLeaf = vault.claimLeaf(TASK_ID, TASK_ID, 1, 1, BOB, 2_985);
        bytes32[] memory aliceProof = new bytes32[](1);
        aliceProof[0] = bobLeaf;
        bytes32[] memory bobProof = new bytes32[](1);
        bobProof[0] = aliceLeaf;
        vm.prank(ALICE);
        vault.claim(TASK_ID, 0, 6_965, aliceProof);
        vm.prank(BOB);
        vault.claim(TASK_ID, 1, 2_985, bobProof);
        vm.prank(TOKEN_FEE_RECIPIENT);
        vault.claimFee(TASK_ID, TOKEN_FEE_RECIPIENT);

        vault.emergencyExitVault(address(this));
        assertFalse(hook.refreshOwnerDefault(TASK_ID));
        assertEq(uint8(_allocationStatus(hook, TASK_ID)), uint8(SponsoredTaskHookV2.HookStatus.SettlementPrepared));
        assertEq(uint8(vault.effectiveAllocationStatus(TASK_ID)), uint8(SponsoredTaskTypes.AllocationStatus.Settled));
    }

    function testAuctionAcceptedWithoutCheckCompleteCanReconcileSoleWinner() external {
        bytes32 auctionTaskId = keccak256("auction");
        market.primeTask(auctionTaskId, MANAGER, address(usdc), NATIVE_REWARD, TMP_AUCTION, address(hook));
        _fundLocalTask(auctionTaskId);
        market.setWorkerAndStake(auctionTaskId, ALICE, 400_000, keccak256("delivered"));
        market.setStatus(auctionTaskId, ITMPCore.TaskStatus.Accepted);

        assertEq(uint8(hook.reconcile(auctionTaskId)), uint8(SponsoredTaskHookV2.HookStatus.SettlementPrepared));
        SponsoredTaskTypes.Allocation memory settled = _vaultAllocation(vault, auctionTaskId);
        assertEq(settled.distributedGross, GROSS);
        assertEq(settled.sponsoredTaskOutstanding, 9_950);
    }

    function _nativePayoutPoolOf(bytes32 taskId) private view returns (uint256 pool) {
        (,,,,,,,,, pool) = hook.taskAllocationFunding(taskId);
    }

    /// An auction escrows its price cap in `reward` but pays out of the accepted price, so a
    /// PARTIAL verdict that awards the whole accepted price (net of the evaluator fee) must
    /// unlock the whole sponsorship, not just price/cap of it.
    function testAuctionPartialScalesSponsorshipOnAcceptedPrice() external {
        bytes32 auctionTaskId = keccak256("auction-partial");
        market.primeTask(auctionTaskId, MANAGER, address(usdc), NATIVE_REWARD, TMP_AUCTION, address(hook));
        ITMPCore.TaskEvaluatorConfig memory config;
        config.evaluator = BOB;
        config.evaluatorFeeBps = 500;
        market.setEvaluator(auctionTaskId, config);
        _fundLocalTask(auctionTaskId);
        uint256 price = NATIVE_REWARD / 4;
        market.setWorkerAndStake(auctionTaskId, ALICE, price, keccak256("delivered"));
        market.setStatus(auctionTaskId, ITMPCore.TaskStatus.Accepted);

        uint256 pool = price - (price * 500) / 10_000;
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: ALICE, amount: pool, rank: 1 });
        market.callCheckCompleteV2(hook, auctionTaskId, _verdict(ITMPCore.VerdictType.PARTIAL, awards));
        assertEq(_nativePayoutPoolOf(auctionTaskId), pool, "pool is the accepted price net of the fee");

        hook.finalizeSettlement(auctionTaskId, awards);
        SponsoredTaskTypes.Allocation memory settled = _vaultAllocation(vault, auctionTaskId);
        assertEq(settled.distributedGross, GROSS);
        assertEq(settled.releasedAmount, 0);
    }

    function testAuctionReconcileBuildsPoolFromAcceptedPriceNetOfFee() external {
        bytes32 auctionTaskId = keccak256("auction-reconcile-fee");
        market.primeTask(auctionTaskId, MANAGER, address(usdc), NATIVE_REWARD, TMP_AUCTION, address(hook));
        ITMPCore.TaskEvaluatorConfig memory config;
        config.evaluator = BOB;
        config.evaluatorFeeBps = 500;
        market.setEvaluator(auctionTaskId, config);
        _fundLocalTask(auctionTaskId);
        market.setWorkerAndStake(auctionTaskId, ALICE, 400_000, keccak256("delivered"));
        market.setStatus(auctionTaskId, ITMPCore.TaskStatus.Accepted);

        assertEq(uint8(hook.reconcile(auctionTaskId)), uint8(SponsoredTaskHookV2.HookStatus.SettlementPrepared));
        assertEq(_nativePayoutPoolOf(auctionTaskId), 400_000 - 20_000);
    }

    function _primeAuction(bytes32 auctionTaskId, uint256 price) private {
        market.primeTask(auctionTaskId, MANAGER, address(usdc), NATIVE_REWARD, TMP_AUCTION, address(hook));
        _fundLocalTask(auctionTaskId);
        market.setWorkerAndStake(auctionTaskId, ALICE, price, keccak256("delivered"));
        market.setStatus(auctionTaskId, ITMPCore.TaskStatus.Accepted);
    }

    /// A PARTIAL verdict finalized after expiry skips checkComplete; reconcile must settle it on
    /// the stored verdict, scaled as checkComplete would have, not as a full APPROVE.
    function testAuctionPartialVerdictAfterExpiryReconcilesOnStoredVerdict() external {
        bytes32 auctionTaskId = keccak256("auction-partial-after-expiry");
        uint256 price = 400_000;
        _primeAuction(auctionTaskId, price);
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: ALICE, amount: price / 4, rank: 1 });
        market.setVerdict(auctionTaskId, _verdict(ITMPCore.VerdictType.PARTIAL, awards));

        assertEq(uint8(hook.reconcile(auctionTaskId)), uint8(SponsoredTaskHookV2.HookStatus.SettlementPrepared));
        SponsoredTaskTypes.Allocation memory settled = _vaultAllocation(vault, auctionTaskId);
        assertEq(settled.distributedGross, GROSS / 4, "a quarter award unlocks a quarter of the sponsorship");
        assertEq(settled.releasedAmount, GROSS - GROSS / 4);
    }

    /// Acceptance reports an auction's accepted price; reconcile's rebuilt award must match it, or
    /// an auction accepted below its cap could never settle.
    function testAuctionAcceptedBelowCapReconcilesCommittedCompletion() external {
        bytes32 auctionTaskId = keccak256("auction-below-cap");
        uint256 price = NATIVE_REWARD / 2;
        _primeAuction(auctionTaskId, price);
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: ALICE, amount: price, rank: 1 });
        market.callCheckCompleteV2(hook, auctionTaskId, _verdict(ITMPCore.VerdictType.APPROVE, awards));
        assertFalse(market.getTaskVerdict(auctionTaskId).issued);

        assertEq(uint8(hook.reconcile(auctionTaskId)), uint8(SponsoredTaskHookV2.HookStatus.SettlementPrepared));
        assertEq(_vaultAllocation(vault, auctionTaskId).distributedGross, GROSS);
    }

    /// A partial settlement whose vault call fails leaves the commitment in place; a later
    /// reconcile installs it and releases the unawarded part.
    function testAuctionPartialReleaseRecoversAfterVaultFailure() external {
        bytes32 auctionTaskId = keccak256("auction-partial-retry");
        uint256 price = 400_000;
        _primeAuction(auctionTaskId, price);
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: ALICE, amount: price / 2, rank: 1 });
        market.setVerdict(auctionTaskId, _verdict(ITMPCore.VerdictType.PARTIAL, awards));

        vm.mockCallRevert(address(vault), abi.encodeWithSelector(vault.installSettlement.selector), "vault down");
        vm.expectRevert(bytes("vault down"));
        hook.reconcile(auctionTaskId);
        assertEq(uint8(_allocationStatus(hook, auctionTaskId)), uint8(SponsoredTaskHookV2.HookStatus.Reserved));
        vm.clearMockedCalls();

        assertEq(uint8(hook.reconcile(auctionTaskId)), uint8(SponsoredTaskHookV2.HookStatus.SettlementPrepared));
        SponsoredTaskTypes.Allocation memory settled = _vaultAllocation(vault, auctionTaskId);
        assertEq(settled.distributedGross, GROSS / 2);
        assertEq(settled.releasedAmount, GROSS / 2);
    }

    function testEvaluatorApproveWithNoAwardsReleasesReservation() external {
        bytes32 claimTaskId = keccak256("claim-evaluated");
        market.primeTask(claimTaskId, MANAGER, address(usdc), NATIVE_REWARD, TMP_CLAIM, address(hook));
        ITMPCore.TaskEvaluatorConfig memory config;
        config.evaluator = BOB;
        config.evaluatorFeeBps = 500;
        market.setEvaluator(claimTaskId, config);
        uint256 availableBefore = vault.available();
        _fundLocalTask(claimTaskId);
        market.setWorkerAndStake(claimTaskId, ALICE, 0, keccak256("delivered"));
        market.setStatus(claimTaskId, ITMPCore.TaskStatus.Accepted);

        ITMPCore.Verdict memory verdict = _verdict(ITMPCore.VerdictType.APPROVE, new ITMPCore.Award[](0));
        market.callCheckCompleteV2(hook, claimTaskId, verdict);
        market.setVerdict(claimTaskId, verdict);
        assertEq(_allocationAwardCount(hook, claimTaskId), 0);

        assertEq(uint8(hook.reconcile(claimTaskId)), uint8(SponsoredTaskHookV2.HookStatus.SettlementPrepared));
        SponsoredTaskTypes.Allocation memory settled = _vaultAllocation(vault, claimTaskId);
        assertEq(uint8(settled.status), uint8(SponsoredTaskTypes.AllocationStatus.Settled));
        assertEq(settled.distributedGross, 0);
        assertEq(settled.releasedAmount, GROSS);
        assertEq(projectToken.balanceOf(ALICE), 0);
        assertEq(vault.available(), availableBefore);
    }

    function testAcceptedSubmissionWithSwallowedCallbackReconcilesFromTask() external {
        bytes32 claimTaskId = keccak256("claim-accepted");
        market.primeTask(claimTaskId, MANAGER, address(usdc), NATIVE_REWARD, TMP_CLAIM, address(hook));
        _fundLocalTask(claimTaskId);
        market.setWorkerAndStake(claimTaskId, ALICE, 0, keccak256("delivered"));
        market.setStatus(claimTaskId, ITMPCore.TaskStatus.Accepted);

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: ALICE, amount: NATIVE_REWARD, rank: 1 });
        market.callCheckCompleteV2(hook, claimTaskId, _verdict(ITMPCore.VerdictType.APPROVE, awards));
        assertFalse(market.getTaskVerdict(claimTaskId).issued);

        assertEq(uint8(hook.reconcile(claimTaskId)), uint8(SponsoredTaskHookV2.HookStatus.SettlementPrepared));
        SponsoredTaskTypes.Allocation memory settled = _vaultAllocation(vault, claimTaskId);
        assertEq(settled.distributedGross, GROSS);
        assertEq(settled.sponsoredTaskOutstanding, 9_950);
    }

    function testReconcileUncommittedClaimPaysSoleWorker() external {
        bytes32 claimTaskId = keccak256("claim-lapsed");
        market.primeTask(claimTaskId, MANAGER, address(usdc), NATIVE_REWARD, TMP_CLAIM, address(hook));
        _fundLocalTask(claimTaskId);
        market.setWorkerAndStake(claimTaskId, ALICE, 0, keccak256("delivered"));
        // A lapsed-review settlement whose hook callbacks were all swallowed: no commitment, no verdict.
        market.setStatus(claimTaskId, ITMPCore.TaskStatus.Accepted);
        assertFalse(market.getTaskVerdict(claimTaskId).issued);

        assertEq(uint8(hook.reconcile(claimTaskId)), uint8(SponsoredTaskHookV2.HookStatus.SettlementPrepared));
        assertEq(_vaultAllocation(vault, claimTaskId).distributedGross, GROSS);
    }

    function testEvaluatorAndTermsFrozenWhileSponsored() external {
        uint32 caps = hook.hookCapabilities();
        assertTrue(caps & (uint32(1) << 1) != 0 && caps & (uint32(1) << 2) != 0, "bits 1 and 2 declared");
        ITMPHookV2.TaskContextV2 memory ctx;

        // Before funding there is no sponsorship to protect.
        vm.startPrank(address(market));
        hook.beforeAssignEvaluator(TASK_ID, ctx, ALICE, "");
        hook.beforeUpdate(TASK_ID, ctx, "");
        vm.stopPrank();

        _fundLocal();
        vm.startPrank(address(market));
        vm.expectPartialRevert(SponsoredTaskHookV2.SponsorshipTermsFrozen.selector);
        hook.beforeAssignEvaluator(TASK_ID, ctx, ALICE, "");
        vm.expectPartialRevert(SponsoredTaskHookV2.SponsorshipTermsFrozen.selector);
        hook.beforeUpdate(TASK_ID, ctx, "");
        vm.stopPrank();

        // Once the sponsorship is released the terms are the requester's again.
        market.setStatus(TASK_ID, ITMPCore.TaskStatus.Expired);
        hook.reconcile(TASK_ID);
        vm.startPrank(address(market));
        hook.beforeAssignEvaluator(TASK_ID, ctx, ALICE, "");
        hook.beforeUpdate(TASK_ID, ctx, "");
        vm.stopPrank();
    }

    function testAcceptedMultiAwardWithoutStoredVerdictStillRequiresAwards() external {
        _fundLocal();
        _commitAccepted(ITMPCore.VerdictType.APPROVE, _twoAwards(700_000, 300_000));

        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskHookV2.AwardsRequired.selector, TASK_ID));
        hook.reconcile(TASK_ID);
    }

    function testWrongAwardsCannotReplaceMandatoryCommitment() external {
        _fundLocal();
        ITMPCore.Award[] memory awards = _twoAwards(700_000, 300_000);
        _commitAccepted(ITMPCore.VerdictType.APPROVE, awards);
        awards[0].amount = 600_000;
        awards[1].amount = 400_000;

        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskHookV2.VerdictCommitmentMismatch.selector, TASK_ID));
        hook.finalizeSettlement(TASK_ID, awards);
    }

    function testEvaluatorVerdictAboveMaximumDoesNotRevertCheckEvaluate() external {
        _fundLocal();
        uint256 tooMany = hook.MAX_AWARDS() + 1;
        ITMPCore.Award[] memory awards = _manyAwards(tooMany);
        ITMPCore.Verdict memory verdict = _verdict(ITMPCore.VerdictType.APPROVE, awards);
        market.setVerdict(TASK_ID, verdict);

        // checkEvaluate must never revert on award count -- overflow is handled at the mandatory
        // completion boundary instead, so Taskmarket's evaluate() call always succeeds.
        assertTrue(market.callCheckEvaluateV2(hook, TASK_ID, address(0xE1A1)));
    }

    function testAwardCountOverflowAtCompletionReleasesSponsoredTaskAndLetsUsdcSettle() external {
        _fundLocal();
        market.setStatus(TASK_ID, ITMPCore.TaskStatus.Accepted);
        uint256 tooMany = hook.MAX_AWARDS() + 1;
        ITMPCore.Award[] memory awards = _manyAwards(tooMany);
        ITMPCore.Verdict memory verdict = _verdict(ITMPCore.VerdictType.APPROVE, awards);

        uint256 availableBefore = vault.available();
        // The mandatory checkComplete callback must not revert -- Taskmarket's own USDC payout is
        // never blocked by this hook, even when the verdict exceeds the sponsor's award ceiling.
        assertTrue(market.callCheckCompleteV2(hook, TASK_ID, verdict));

        assertEq(uint8(_allocationStatus(hook, TASK_ID)), uint8(SponsoredTaskHookV2.HookStatus.AwardCountExceeded));
        assertEq(vault.available(), availableBefore + GROSS, "reservation must return to available");

        // Terminal and idempotent: a later finalizeSettlement/reconcile call is a graceful no-op,
        // never a revert.
        assertEq(hook.finalizeSettlement(TASK_ID, awards), bytes32(0));
    }

    function testV1AwardCeilingIsPinnedAtEight() external view {
        assertEq(hook.MAX_AWARDS(), 8);
    }

    function testMaximumAwardCommitmentStaysWellInsideHookStipend() external {
        _fundLocal();
        market.setStatus(TASK_ID, ITMPCore.TaskStatus.Accepted);
        uint256 maximum = hook.MAX_AWARDS();
        ITMPCore.Award[] memory awards = _manyAwards(maximum);
        ITMPCore.Verdict memory verdict = _verdict(ITMPCore.VerdictType.APPROVE, awards);

        uint256 gasBefore = gasleft();
        market.callCheckCompleteV2(hook, TASK_ID, verdict);
        uint256 used = gasBefore - gasleft();
        assertLt(used, 900_000, "leave at least 10% headroom under Taskmarket stipend");
        assertEq(_allocationAwardCount(hook, TASK_ID), maximum);
    }

    function _fundLocal() private {
        _fundLocalTask(TASK_ID);
    }

    function _fundLocalTask(bytes32 taskId) private {
        market.callCheckFundV2(hook, taskId, _localHookData(taskId));
    }

    function _localHookData(bytes32 taskId) private view returns (bytes memory) {
        bytes32 termsHash = hook.currentTaskTermsHash(taskId);
        SponsoredTaskHookV2.FundingRequest memory request = SponsoredTaskHookV2.FundingRequest({
            route: hook.ROUTE_BASE_LOCAL(),
            vault: address(vault),
            vaultId: vault.vaultId(),
            allocationId: bytes32(0),
            epoch: 1,
            feeBps: TOKEN_FEE_BPS,
            feeRecipient: TOKEN_FEE_RECIPIENT,
            grossAmount: GROSS,
            taskTermsHash: termsHash
        });
        return hook.encodeHookData(request);
    }

    function _commitAccepted(ITMPCore.VerdictType verdictType, ITMPCore.Award[] memory awards) private {
        market.setStatus(TASK_ID, ITMPCore.TaskStatus.Accepted);
        ITMPCore.Verdict memory verdict = _verdict(verdictType, awards);
        market.callCheckCompleteV2(hook, TASK_ID, verdict);
    }

    function _verdict(ITMPCore.VerdictType verdictType, ITMPCore.Award[] memory awards)
        private
        pure
        returns (ITMPCore.Verdict memory)
    {
        return ITMPCore.Verdict({
            issued: true,
            verdictType: verdictType,
            score: 1_000,
            confidence: 1_000,
            criteriaFlags: new bytes32[](0),
            evidenceHash: bytes32(0),
            awards: awards
        });
    }

    function _twoAwards(uint256 aliceAmount, uint256 bobAmount) private pure returns (ITMPCore.Award[] memory awards) {
        awards = new ITMPCore.Award[](2);
        awards[0] = ITMPCore.Award({ worker: ALICE, amount: aliceAmount, rank: 1 });
        awards[1] = ITMPCore.Award({ worker: BOB, amount: bobAmount, rank: 2 });
    }

    function _manyAwards(uint256 count) private pure returns (ITMPCore.Award[] memory awards) {
        awards = new ITMPCore.Award[](count);
        for (uint256 i; i < count; ++i) {
            awards[i] = ITMPCore.Award({ worker: address(uint160(0x1000 + i)), amount: 1, rank: uint16(i + 1) });
        }
    }
}
