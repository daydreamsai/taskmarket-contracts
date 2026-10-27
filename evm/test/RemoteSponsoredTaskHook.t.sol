// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { TMP_AUCTION, TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { SponsoredTaskTypes } from "../src/hooks/sponsored-task/SponsoredTaskTypes.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTaskFactory } from "../src/hooks/sponsored-task/SponsoredTaskFactory.sol";
import { SponsoredTaskFeeConfig } from "./helpers/SponsoredTaskFeeConfig.sol";
import { SponsoredTasksVault } from "../src/hooks/sponsored-task/SponsoredTasksVault.sol";
import { SponsoredTaskSettler } from "../src/hooks/sponsored-task/SponsoredTaskSettler.sol";
import { RemoteSponsoredTaskHook } from "../src/hooks/sponsored-task/RemoteSponsoredTaskHook.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockTaskmarketForSponsoredTask } from "./SponsoredTaskHook.t.sol";

contract RemoteSponsoredTaskHookTest is Test {
    uint256 private constant BASE_CHAIN_ID = 8453;
    uint256 private constant REMOTE_CHAIN_ID = 46_630;
    bytes32 private constant TASK_ID = keccak256("remote-task");
    uint256 private constant NATIVE_REWARD = 1_000_000;
    uint256 private constant GROSS = 10_000;
    uint16 private constant FEE_BPS = 750;
    uint64 private constant NONCE = 1;
    address private constant FEE_RECIPIENT = address(0xFEE);
    address private constant MANAGER = address(0xCAFE);
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    uint256 private constant SETTLER_KEY = 0x5E771E;

    MockTaskmarketForSponsoredTask private market;
    RemoteSponsoredTaskHook private hook;
    MockERC20 private token;
    SponsoredTaskSettler private settler;
    SponsoredTasksVault private vault;
    MockERC20 private usdc;

    /// @dev The one-time vault creation fee the settler-mode factory takes.
    uint256 private constant CREATION_FEE = 1_000_000;
    uint256 private constant MANAGER_USDC = 10_000_000;
    address private constant CREATION_FEE_RECIPIENT = address(0xC0FFEE);

    function setUp() public {
        // Remote chain: settler-mode factory and a funded vault.
        vm.chainId(REMOTE_CHAIN_ID);
        token = new MockERC20("Project", "PROJECT", 18, address(this));
        usdc = new MockERC20("USD Coin", "USDC", 6, address(this));
        SponsoredTaskFeePolicy feePolicy = new SponsoredTaskFeePolicy(address(this), FEE_BPS, FEE_RECIPIENT);
        SponsoredTaskRegistry registry = new SponsoredTaskRegistry(address(this));
        address[] memory settlers = new address[](1);
        settlers[0] = vm.addr(SETTLER_KEY);
        settler = new SponsoredTaskSettler(address(this), settlers, 1);
        SponsoredTaskFactory factory = new SponsoredTaskFactory(
            address(settler),
            address(feePolicy),
            registry,
            SponsoredTaskFeeConfig.charging(IERC20(address(usdc)), CREATION_FEE, CREATION_FEE_RECIPIENT)
        );
        registry.setFactory(address(factory), true);
        usdc.mint(address(this), CREATION_FEE);
        usdc.approve(address(factory), CREATION_FEE);
        (address v,) = factory.createVault(address(token), address(this), keccak256("remote"));
        vault = SponsoredTasksVault(v);
        vault.configureManager(MANAGER, GROSS * 10, true);
        token.mint(address(this), GROSS * 10);
        token.approve(address(vault), type(uint256).max);
        vault.fund(GROSS * 10);

        // Base: the remote hook behind its proxy.
        vm.chainId(BASE_CHAIN_ID);
        market = new MockTaskmarketForSponsoredTask();
        address implementation = address(new RemoteSponsoredTaskHook(address(market)));
        hook = RemoteSponsoredTaskHook(
            address(
                new ERC1967Proxy(implementation, abi.encodeCall(RemoteSponsoredTaskHook.initialize, (address(this))))
            )
        );
        usdc.mint(MANAGER, MANAGER_USDC);
        market.primeTask(TASK_ID, MANAGER, address(0x05DC), NATIVE_REWARD, TMP_BOUNTY, address(hook));
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _request() private view returns (RemoteSponsoredTaskHook.FundingRequest memory) {
        return RemoteSponsoredTaskHook.FundingRequest({
            remoteChainId: REMOTE_CHAIN_ID,
            vault: address(vault),
            vaultId: vault.vaultId(),
            token: address(token),
            grossAmount: GROSS,
            commitmentNonce: NONCE,
            epoch: 1,
            feeBps: FEE_BPS,
            feeRecipient: FEE_RECIPIENT,
            taskTermsHash: hook.currentTaskTermsHash(TASK_ID)
        });
    }

    function _fund() private {
        market.callCheckFund(hook, TASK_ID, hook.encodeHookData(_request()));
    }

    function _status() private view returns (RemoteSponsoredTaskHook.HookStatus) {
        return hook.outcome(TASK_ID).status;
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

    function _twoAwards() private pure returns (ITMPCore.Award[] memory awards) {
        awards = new ITMPCore.Award[](2);
        awards[0] = ITMPCore.Award({ worker: ALICE, amount: 700_000, rank: 1 });
        awards[1] = ITMPCore.Award({ worker: BOB, amount: 300_000, rank: 2 });
    }

    function _commitAccepted(ITMPCore.Award[] memory awards) private {
        market.setStatus(TASK_ID, ITMPCore.TaskStatus.Accepted);
        market.callCheckComplete(hook, TASK_ID, _verdict(ITMPCore.VerdictType.APPROVE, awards));
    }

    function _sign(bytes32 digest) private pure returns (bytes[] memory sigs) {
        sigs = new bytes[](1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SETTLER_KEY, digest);
        sigs[0] = abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------------------------------------
    // Funding commitment
    // ---------------------------------------------------------------------------------------------

    function testFundingRecordsCommitmentAndMovesNoVaultTokens() public {
        _fund();
        RemoteSponsoredTaskHook.Commitment memory c = hook.commitment(TASK_ID);
        assertEq(c.remoteChainId, REMOTE_CHAIN_ID);
        assertEq(c.vault, address(vault));
        assertEq(c.token, address(token));
        assertEq(c.grossAmount, GROSS);
        assertEq(c.commitmentNonce, NONCE);
        assertEq(c.manager, MANAGER);
        assertEq(c.allocationId, keccak256(abi.encode(BASE_CHAIN_ID, TASK_ID)));
        assertEq(c.allocationId, hook.allocationIdFor(BASE_CHAIN_ID, TASK_ID));
        assertEq(uint8(_status()), uint8(RemoteSponsoredTaskHook.HookStatus.Committed));
        assertEq(hook.taskByCommitment(REMOTE_CHAIN_ID, address(vault), NONCE), TASK_ID);
        assertEq(hook.reservationReleaseAfter(TASK_ID), block.timestamp + 3 days + 7 days);
    }

    function testFundingRejectsInvalidRequests() public {
        RemoteSponsoredTaskHook.FundingRequest memory r = _request();
        r.remoteChainId = BASE_CHAIN_ID;
        bytes memory data = hook.encodeHookData(r);
        vm.expectRevert(RemoteSponsoredTaskHook.InvalidFundingRequest.selector);
        market.callCheckFund(hook, TASK_ID, data);

        r = _request();
        r.grossAmount = 0;
        data = hook.encodeHookData(r);
        vm.expectRevert(RemoteSponsoredTaskHook.InvalidFundingRequest.selector);
        market.callCheckFund(hook, TASK_ID, data);

        r = _request();
        r.feeRecipient = address(0);
        data = hook.encodeHookData(r);
        vm.expectRevert(RemoteSponsoredTaskHook.InvalidFundingRequest.selector);
        market.callCheckFund(hook, TASK_ID, data);

        r = _request();
        r.taskTermsHash = keccak256("wrong");
        data = hook.encodeHookData(r);
        vm.expectPartialRevert(RemoteSponsoredTaskHook.TaskTermsMismatch.selector);
        market.callCheckFund(hook, TASK_ID, data);

        data = abi.encode(uint8(2), _request());
        vm.expectRevert(abi.encodeWithSelector(RemoteSponsoredTaskHook.InvalidHookDataVersion.selector, uint8(2)));
        market.callCheckFund(hook, TASK_ID, data);
    }

    function testFundingRejectsDuplicateTaskAndReusedNonce() public {
        _fund();
        bytes memory data = hook.encodeHookData(_request());
        vm.expectRevert(abi.encodeWithSelector(RemoteSponsoredTaskHook.CommitmentAlreadyExists.selector, TASK_ID));
        market.callCheckFund(hook, TASK_ID, data);

        bytes32 otherTask = keccak256("other-task");
        market.primeTask(otherTask, MANAGER, address(0x05DC), NATIVE_REWARD, TMP_BOUNTY, address(hook));
        RemoteSponsoredTaskHook.FundingRequest memory r = _request();
        r.taskTermsHash = hook.currentTaskTermsHash(otherTask);
        data = hook.encodeHookData(r);
        vm.expectRevert(
            abi.encodeWithSelector(
                RemoteSponsoredTaskHook.CommitmentNonceUsed.selector, REMOTE_CHAIN_ID, address(vault), NONCE, TASK_ID
            )
        );
        market.callCheckFund(hook, otherTask, data);
    }

    function testOnlyDiamondMayCallHook() public {
        bytes memory data = hook.encodeHookData(_request());
        ITMPCore.TaskContext memory ctx = market.getTaskContext(TASK_ID);
        vm.expectRevert();
        hook.checkFund(TASK_ID, ctx, data);
    }

    // ---------------------------------------------------------------------------------------------
    // Creation fee: paid once by the vault creator, never per task
    // ---------------------------------------------------------------------------------------------

    function testVaultCreationPaidTheFeeOnce() public view {
        assertEq(usdc.balanceOf(CREATION_FEE_RECIPIENT), CREATION_FEE);
        assertEq(usdc.balanceOf(address(this)), 0);
    }

    function testRemoteTasksChargeNoFee() public {
        _fund();
        bytes32 otherTask = keccak256("other-task");
        market.primeTask(otherTask, MANAGER, address(0x05DC), NATIVE_REWARD, TMP_BOUNTY, address(hook));
        RemoteSponsoredTaskHook.FundingRequest memory r = _request();
        r.commitmentNonce = NONCE + 1;
        r.taskTermsHash = hook.currentTaskTermsHash(otherTask);
        market.callCheckFund(hook, otherTask, hook.encodeHookData(r));

        // Completion and settlement charge nothing either.
        ITMPCore.Award[] memory awards = _twoAwards();
        _commitAccepted(awards);
        hook.finalizeSettlement(TASK_ID, awards);
        hook.reconcile(TASK_ID);
        assertEq(usdc.balanceOf(MANAGER), MANAGER_USDC);
        assertEq(usdc.balanceOf(CREATION_FEE_RECIPIENT), CREATION_FEE);
    }

    function testCancelReleasesTheReservationAndRefundsNoFee() public {
        _fund();
        RemoteSponsoredTaskHook.Commitment memory c = hook.commitment(TASK_ID);

        vm.chainId(REMOTE_CHAIN_ID);
        SponsoredTaskSettler.ReserveRequest memory r = SponsoredTaskSettler.ReserveRequest({
            vault: c.vault,
            allocationId: c.allocationId,
            baseChainId: BASE_CHAIN_ID,
            baseTaskId: TASK_ID,
            commitmentNonce: c.commitmentNonce,
            manager: c.manager,
            grossAmount: c.grossAmount,
            epoch: c.epoch,
            feeBps: c.feeBps,
            feeRecipient: c.feeRecipient,
            termsHash: c.termsHash
        });
        settler.reserve(r, _sign(settler.reserveDigest(r)));
        assertEq(vault.totalReserved(), GROSS);

        vm.chainId(BASE_CHAIN_ID);
        market.setStatus(TASK_ID, ITMPCore.TaskStatus.Cancelled);
        market.callOnCancel(hook, TASK_ID);
        assertEq(uint8(_status()), uint8(RemoteSponsoredTaskHook.HookStatus.ReleaseCommitted));

        vm.chainId(REMOTE_CHAIN_ID);
        SponsoredTaskSettler.ReleaseRequest memory rel = SponsoredTaskSettler.ReleaseRequest({
            vault: c.vault,
            allocationId: c.allocationId,
            baseChainId: BASE_CHAIN_ID,
            baseTaskId: TASK_ID,
            commitmentNonce: c.commitmentNonce
        });
        settler.release(rel, _sign(settler.releaseDigest(rel)));
        assertEq(vault.totalReserved(), 0);

        // The vault creation fee is never refunded, and the task itself was free.
        assertEq(usdc.balanceOf(CREATION_FEE_RECIPIENT), CREATION_FEE);
        assertEq(usdc.balanceOf(MANAGER), MANAGER_USDC);
    }

    // ---------------------------------------------------------------------------------------------
    // Completion, release and repair
    // ---------------------------------------------------------------------------------------------

    function testCancelCommitsReleaseOnce() public {
        _fund();
        market.setStatus(TASK_ID, ITMPCore.TaskStatus.Cancelled);
        market.callOnCancel(hook, TASK_ID);
        assertEq(uint8(_status()), uint8(RemoteSponsoredTaskHook.HookStatus.ReleaseCommitted));
        assertEq(uint8(hook.finalizeRelease(TASK_ID)), uint8(RemoteSponsoredTaskHook.HookStatus.ReleaseCommitted));
        assertEq(uint8(hook.reconcile(TASK_ID)), uint8(RemoteSponsoredTaskHook.HookStatus.ReleaseCommitted));
    }

    function testFinalizeReleaseRepairsMissedExpiry() public {
        _fund();
        vm.expectPartialRevert(RemoteSponsoredTaskHook.TaskNotTerminal.selector);
        hook.finalizeRelease(TASK_ID);
        market.setStatus(TASK_ID, ITMPCore.TaskStatus.Expired);
        assertEq(uint8(hook.finalizeRelease(TASK_ID)), uint8(RemoteSponsoredTaskHook.HookStatus.ReleaseCommitted));
    }

    function testFinalizeSettlementRequiresCommittedAwards() public {
        vm.expectRevert(abi.encodeWithSelector(RemoteSponsoredTaskHook.CommitmentNotFound.selector, TASK_ID));
        hook.finalizeSettlement(TASK_ID, _twoAwards());

        _fund();
        vm.expectPartialRevert(RemoteSponsoredTaskHook.CommitmentWrongStatus.selector);
        hook.finalizeSettlement(TASK_ID, _twoAwards());

        _commitAccepted(_twoAwards());
        ITMPCore.Award[] memory tampered = _twoAwards();
        tampered[1].amount += 1;
        vm.expectRevert(abi.encodeWithSelector(RemoteSponsoredTaskHook.VerdictCommitmentMismatch.selector, TASK_ID));
        hook.finalizeSettlement(TASK_ID, tampered);
    }

    function testOversizedVerdictIsUnsettleableWithoutBlockingCompletion() public {
        _fund();
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](9);
        for (uint256 i; i < 9; ++i) {
            awards[i] = ITMPCore.Award({ worker: address(uint160(0x1000 + i)), amount: 1, rank: uint16(i + 1) });
        }
        market.setStatus(TASK_ID, ITMPCore.TaskStatus.Accepted);
        assertTrue(market.callCheckComplete(hook, TASK_ID, _verdict(ITMPCore.VerdictType.APPROVE, awards)));
        assertEq(uint8(_status()), uint8(RemoteSponsoredTaskHook.HookStatus.AwardCountExceeded));
        assertEq(hook.finalizeSettlement(TASK_ID, awards), bytes32(0));
    }

    function testReconcileUsesStoredVerdict() public {
        _fund();
        ITMPCore.Award[] memory awards = _twoAwards();
        _commitAccepted(awards);
        market.setVerdict(TASK_ID, _verdict(ITMPCore.VerdictType.APPROVE, awards));
        assertEq(uint8(hook.reconcile(TASK_ID)), uint8(RemoteSponsoredTaskHook.HookStatus.SettlementPrepared));
    }

    function testReconcileUncommittedAuction() public {
        bytes32 auctionTask = keccak256("auction");
        market.primeTask(auctionTask, MANAGER, address(0x05DC), NATIVE_REWARD, TMP_AUCTION, address(hook));
        RemoteSponsoredTaskHook.FundingRequest memory r = _request();
        r.taskTermsHash = hook.currentTaskTermsHash(auctionTask);
        market.callCheckFund(hook, auctionTask, hook.encodeHookData(r));
        market.setWorkerAndStake(auctionTask, ALICE, 500_000, keccak256("deliverable"));
        market.setStatus(auctionTask, ITMPCore.TaskStatus.Accepted);
        assertEq(uint8(hook.reconcile(auctionTask)), uint8(RemoteSponsoredTaskHook.HookStatus.SettlementPrepared));
        assertEq(hook.outcome(auctionTask).sponsoredTaskTotal, 9_250);
    }

    function testReconcileRequiresAwardsForUncommittedBounty() public {
        _fund();
        market.setStatus(TASK_ID, ITMPCore.TaskStatus.Accepted);
        vm.expectRevert(abi.encodeWithSelector(RemoteSponsoredTaskHook.AwardsRequired.selector, TASK_ID));
        hook.reconcile(TASK_ID);
    }

    // ---------------------------------------------------------------------------------------------
    // End to end: Base root, remote settle, finalize and claim
    // ---------------------------------------------------------------------------------------------

    function testBaseRootSettlesOnRemoteChainAndWorkersClaim() public {
        _fund();
        RemoteSponsoredTaskHook.Commitment memory c = hook.commitment(TASK_ID);
        ITMPCore.Award[] memory awards = _twoAwards();
        _commitAccepted(awards);
        bytes32 root = hook.finalizeSettlement(TASK_ID, awards);
        RemoteSponsoredTaskHook.Outcome memory o = hook.outcome(TASK_ID);
        assertEq(uint8(o.status), uint8(RemoteSponsoredTaskHook.HookStatus.SettlementPrepared));
        assertEq(o.sponsoredTaskTotal, 9_250);
        assertEq(o.feeTotal, 750);
        assertEq(o.leafCount, 2);
        // Idempotent.
        assertEq(hook.finalizeSettlement(TASK_ID, awards), root);

        // The settler service reads the Base commitment and outcome and drives the remote chain.
        vm.chainId(REMOTE_CHAIN_ID);
        SponsoredTaskSettler.ReserveRequest memory r = SponsoredTaskSettler.ReserveRequest({
            vault: c.vault,
            allocationId: c.allocationId,
            baseChainId: BASE_CHAIN_ID,
            baseTaskId: TASK_ID,
            commitmentNonce: c.commitmentNonce,
            manager: c.manager,
            grossAmount: c.grossAmount,
            epoch: c.epoch,
            feeBps: c.feeBps,
            feeRecipient: c.feeRecipient,
            termsHash: c.termsHash
        });
        settler.reserve(r, _sign(settler.reserveDigest(r)));

        SponsoredTaskSettler.SettleRequest memory s = SponsoredTaskSettler.SettleRequest({
            vault: c.vault,
            allocationId: c.allocationId,
            baseChainId: BASE_CHAIN_ID,
            baseTaskId: TASK_ID,
            commitmentNonce: c.commitmentNonce,
            epoch: c.epoch,
            rewardsRoot: o.rewardsRoot,
            leafCount: o.leafCount,
            sponsoredTaskTotal: o.sponsoredTaskTotal,
            feeTotal: o.feeTotal,
            distributedGross: o.distributedGross
        });
        settler.settle(s, _sign(settler.settleDigest(s)));
        vm.warp(block.timestamp + settler.claimDelaySeconds());
        settler.finalize(c.vault, c.allocationId);

        bytes32 aliceLeaf = vault.claimLeaf(c.allocationId, TASK_ID, 1, 0, ALICE, 6_475);
        bytes32 bobLeaf = vault.claimLeaf(c.allocationId, TASK_ID, 1, 1, BOB, 2_775);
        bytes32[] memory aliceProof = new bytes32[](1);
        aliceProof[0] = bobLeaf;
        bytes32[] memory bobProof = new bytes32[](1);
        bobProof[0] = aliceLeaf;
        vm.prank(ALICE);
        vault.claim(c.allocationId, 0, 6_475, aliceProof);
        vm.prank(BOB);
        vault.claim(c.allocationId, 1, 2_775, bobProof);
        vm.prank(FEE_RECIPIENT);
        vault.claimFee(c.allocationId, FEE_RECIPIENT);
        assertEq(token.balanceOf(ALICE), 6_475);
        assertEq(token.balanceOf(BOB), 2_775);
        assertEq(token.balanceOf(FEE_RECIPIENT), 750);
        (,,,,,,, SponsoredTaskTypes.AllocationStatus status) = vault.allocationSettlement(c.allocationId);
        assertEq(uint8(status), uint8(SponsoredTaskTypes.AllocationStatus.Settled));
    }
}
