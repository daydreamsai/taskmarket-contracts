// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/TaskMarketForwarderV2.sol";
import "../src/interfaces/ITMPCore.sol";
import "../src/interfaces/ITMPDiamond.sol";
import { ITMPEscrow } from "../src/interfaces/ITMPEscrow.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { Rev026Upgrade } from "../script/upgrades/Rev026Upgrade.s.sol";
import { Rev026Backfill } from "../script/upgrades/Rev026Backfill.s.sol";
import { DeployTarget } from "../script/lib/DeployTarget.sol";
import { RegistryFacet } from "../src/facets/RegistryFacet.sol";
import { MockEscrowBugFacet } from "./mocks/MockEscrowBugFacet.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";

/// @title Rev026UpgradeTest
/// @dev Builds a diamond holding live tasks in several states, strips its escrow records and the
///      rev026 selectors to stand in for a rev025 diamond, then runs the cut, the backfill and the
///      completion, and settles every task through a payout path.
contract Rev026UpgradeTest is Test, DiamondTestHelper {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    uint256 internal constant REWARD = 100e6;
    uint256 internal constant STAKE = 10e6;

    address internal owner;
    address internal server = address(2);
    address internal requester = address(3);
    address internal worker = address(4);
    address internal evaluator = address(6);
    address internal feeRecipient = address(0xFEE0);

    ITMPDiamond internal market;
    MockEscrowBugFacet internal bug;
    TaskMarketForwarderV2 internal fwd;
    MockUSDC internal usdc;
    uint256 internal _n;

    bytes32 internal openTask;
    bytes32 internal claimedTask;
    bytes32 internal evaluatedTask;
    bytes32 internal cancelledTask;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, 500);
        fwd = new TaskMarketForwarderV2(address(usdc), address(market), server);
        market.addForwarder(address(fwd));
        MockEscrowBugFacet facet = new MockEscrowBugFacet();
        bytes4[] memory sels = new bytes4[](3);
        sels[0] = MockEscrowBugFacet.bugUnbook.selector;
        sels[1] = MockEscrowBugFacet.bugSetLiabilitiesInitialised.selector;
        sels[2] = MockEscrowBugFacet.bugSetReward.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(facet), IDiamondCut.FacetCutAction.Add, sels);
        IDiamondCut(address(market)).diamondCut(cuts, address(0), "");
        vm.stopPrank();
        bug = MockEscrowBugFacet(address(market));

        usdc.mint(server, 10_000e6);
        vm.prank(server);
        usdc.approve(address(fwd), type(uint256).max);

        openTask = _create(noEvaluatorConfig(), REWARD);
        claimedTask = _create(noEvaluatorConfig(), REWARD);
        _relay(worker, STAKE, abi.encodeCall(market.claimTask, (claimedTask, STAKE)));
        evaluatedTask = _create(_evalCfg(), REWARD + STAKE);
        cancelledTask = _create(noEvaluatorConfig(), REWARD);
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (cancelledTask, 0)));

        _makeRev025();
    }

    function _relay(address sender, uint256 amount, bytes memory data) internal {
        _n++;
        vm.prank(server);
        fwd.relay(sender, amount, block.timestamp + 5 minutes, bytes32(_n), data);
    }

    function _evalCfg() internal view returns (ITMPCore.TaskEvaluatorConfig memory) {
        return ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: STAKE,
            evaluatorFeeBps: 0,
            evaluationWindow: uint32(2 days),
            appealWindow: uint32(1 days),
            disputeResolver: address(0)
        });
    }

    function _create(ITMPCore.TaskEvaluatorConfig memory cfg, uint256 paid) internal returns (bytes32 taskId) {
        taskId = keccak256(abi.encode(block.chainid, address(market), requester, market.requesterNonce(requester)));
        _relay(
            requester,
            paid,
            abi.encodeCall(
                market.createTask,
                (
                    taskConfig(REWARD, 7 days, market.CLAIM(), 0, 0, bytes4(0)),
                    ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                    ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                    cfg,
                    stakeTerms(false, 0)
                )
            )
        );
    }

    /// @dev A rev025 diamond: no task booked, no rev026 selectors, version 25.
    function _makeRev025() internal {
        bug.bugUnbook(openTask);
        bug.bugUnbook(claimedTask);
        bug.bugUnbook(evaluatedTask);
        bug.bugUnbook(cancelledTask);
        bug.bugSetLiabilitiesInitialised(false);
        assertEq(market.totalLiabilities(), 0);

        bytes4[] memory admin = FacetSelectors.adminFacetSelectorsAddedRev026();
        bytes4[] memory registry = FacetSelectors.registryFacetSelectorsAddedRev026();
        bytes4[] memory gone = new bytes4[](admin.length + registry.length);
        for (uint256 i; i < admin.length; ++i) {
            gone[i] = admin[i];
        }
        for (uint256 i; i < registry.length; ++i) {
            gone[admin.length + i] = registry[i];
        }
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, gone);
        vm.prank(owner);
        IDiamondCut(address(market)).diamondCut(cuts, address(0), "");
        _routeRemovedRev026(address(market), owner);
        placeAtVersion(address(market), 25);

        vm.chainId(84532);
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_84532", vm.toString(address(market)));
    }

    function _upgradeAndBackfill() internal {
        address workerFacet = IDiamondLoupe(address(market)).facetAddress(ITMPDiamond.submitWork.selector);
        new Rev026Upgrade().run();
        _restoreWorkerRouting(workerFacet);
        bytes32[] memory ids = new bytes32[](6);
        ids[0] = openTask;
        ids[1] = claimedTask;
        ids[2] = evaluatedTask;
        ids[3] = cancelledTask;
        ids[4] = openTask;
        ids[5] = keccak256("unknown");
        vm.prank(owner);
        assertEq(market.backfillLiabilities(ids), 3, "books the three live tasks once each");
        vm.prank(owner);
        market.completeLiabilities();
    }

    /// @dev The rev026 step, run from this build, routes claimTask and the submit entrypoints to
    ///      today's CoreFacet, which no longer serves them (rev027 moved them to WorkerFacet). On
    ///      chain rev027 follows; here the moved selectors go back to the diamond's WorkerFacet.
    function _restoreWorkerRouting(address workerFacet) internal {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(
            workerFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.workerFacetSelectorsFromCore()
        );
        vm.prank(owner);
        IDiamondCut(address(market)).diamondCut(cuts, address(0), "");
    }

    function test_Upgrade_BumpsVersionWithoutPausing() public {
        new Rev026Upgrade().run();
        assertFalse(market.paused());
        assertEq(AdminFacet(address(market)).diamondVersion(), 26);
        assertFalse(market.liabilitiesInitialised());
    }

    function test_Upgrade_KeepsDefaultHookGasStipendWhenUnset() public {
        new Rev026Upgrade().run();
        assertEq(AdminFacet(address(market)).hookGasStipend(), 1_000_000, "unset stipend reads the default");
    }

    function test_Upgrade_SetsTempoHookGasStipend() public {
        uint256[2] memory tempoChains = [uint256(4217), uint256(42431)];
        vm.setEnv("FORGE_HOOK_GAS_STIPEND", "7000000");
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < tempoChains.length; i++) {
            vm.chainId(tempoChains[i]);
            vm.setEnv(
                string.concat("FORGE_DIAMOND_ADDRESS_", vm.toString(tempoChains[i])), vm.toString(address(market))
            );
            new Rev026Upgrade().run();
            assertEq(AdminFacet(address(market)).hookGasStipend(), 7_000_000, "Tempo stipend set in the upgrade");
            assertEq(AdminFacet(address(market)).diamondVersion(), 26);
            vm.revertToState(snap);
        }
        // vm.setEnv is process-wide; zero reads as unset for the other upgrade tests.
        vm.setEnv("FORGE_HOOK_GAS_STIPEND", "0");
    }

    /// @dev A run that stops after the first cut is finished by running the same script again.
    function test_Upgrade_ResumesAfterOnlyTheFirstCut() public {
        Rev026UpgradeFirstCutOnly firstOnly = new Rev026UpgradeFirstCutOnly();
        firstOnly.applyFirstCut();
        Rev026Upgrade step = new Rev026Upgrade();
        assertTrue(step.firstCutApplied(address(market)), "first cut detected");
        assertEq(AdminFacet(address(market)).diamondVersion(), 25, "still rev025 between the cuts");

        step.run();
        assertEq(AdminFacet(address(market)).diamondVersion(), 26);
        assertEq(
            IDiamondLoupe(address(market)).facetAddress(bytes4(0xe7056c4e)),
            address(0),
            "second cut removed normalizeTerms"
        );
        assertNotEq(
            IDiamondLoupe(address(market)).facetAddress(FacetSelectors.adminFacetSelectorsAddedRev026()[0]),
            address(0),
            "second cut added the AdminFacet selectors"
        );
    }

    function test_Upgrade_FreshRunSendsBothCuts() public {
        Rev026Upgrade step = new Rev026Upgrade();
        assertFalse(step.firstCutApplied(address(market)));
        step.run();
        assertTrue(step.firstCutApplied(address(market)));
        assertEq(AdminFacet(address(market)).diamondVersion(), 26);
    }

    /// @dev AuctionFacet dispatches hooks through LibHooks, so it must carry the stipend read too.
    function test_Upgrade_ReplacesAuctionFacet() public {
        IDiamondLoupe loupe = IDiamondLoupe(address(market));
        bytes4 sel = FacetSelectors.auctionFacetSelectors()[0];
        address before = loupe.facetAddress(sel);
        new Rev026Upgrade().run();
        assertNotEq(loupe.facetAddress(sel), before, "AuctionFacet replaced");
    }

    /// @dev Selectors written out: the rev018 createTask (0xa810726c) and normalizeTerms
    ///      (0xe7056c4e) must stop routing, and the terms-taking createTask must still create.
    function test_Upgrade_RemovesLegacyCreateTaskAndNormalizeTerms() public {
        IDiamondLoupe loupe = IDiamondLoupe(address(market));
        assertNotEq(loupe.facetAddress(bytes4(0xa810726c)), address(0), "legacy createTask routed at rev025");
        assertNotEq(loupe.facetAddress(bytes4(0xe7056c4e)), address(0), "normalizeTerms routed at rev025");

        new Rev026Upgrade().run();

        assertEq(loupe.facetAddress(bytes4(0xa810726c)), address(0), "legacy createTask removed");
        assertEq(loupe.facetAddress(bytes4(0xe7056c4e)), address(0), "normalizeTerms removed");
        (bool ok, bytes memory err) = address(market).call(abi.encodeWithSelector(bytes4(0xe7056c4e), new bytes32[](0)));
        assertFalse(ok, "normalizeTerms reverts");
        assertEq(err, abi.encodeWithSignature("Error(string)", "Diamond: function not found"));
        assertEq(market.getTask(_create(noEvaluatorConfig(), REWARD)).requester, requester, "createTask still creates");
    }

    function test_Backfill_BooksLiveTasksAndBalances() public {
        _upgradeAndBackfill();
        (uint256 booked, bool tracked) = market.escrowRecord(claimedTask);
        assertTrue(tracked);
        assertEq(booked, REWARD + STAKE);
        (booked,) = market.escrowRecord(evaluatedTask);
        assertEq(booked, REWARD + STAKE);
        (, tracked) = market.escrowRecord(cancelledTask);
        assertFalse(tracked, "a terminal task is never booked");
        assertEq(market.totalLiabilities(), 3 * REWARD + 2 * STAKE);
        assertEq(usdc.balanceOf(address(market)), market.totalLiabilities());
        assertTrue(market.liabilitiesInitialised());
    }

    function test_AfterBackfill_EveryPayoutReleases() public {
        _upgradeAndBackfill();
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (openTask, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (claimedTask, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (claimedTask, worker, keccak256("work"), 0)));
        vm.warp(block.timestamp + 8 days);
        market.refundExpired(evaluatedTask, 0);
        assertEq(market.totalLiabilities(), 0);
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    function test_RevertWhen_CompleteTwice() public {
        _upgradeAndBackfill();
        vm.expectRevert(ITMPEscrow.LiabilitiesAlreadyInitialised.selector);
        vm.prank(owner);
        market.completeLiabilities();
    }

    function test_MissedTask_SweptThenRecoveredByLateBackfill() public {
        new Rev026Upgrade().run();
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = claimedTask;
        ids[1] = evaluatedTask;
        vm.startPrank(owner);
        market.backfillLiabilities(ids);
        market.completeLiabilities();
        // The export missed openTask, so the sweep takes its escrow as surplus.
        market.sweepSurplus();
        vm.stopPrank();
        assertEq(usdc.balanceOf(feeRecipient), REWARD);

        bytes memory cancel = abi.encodeCall(market.cancelTask, (openTask, 0));
        vm.expectRevert();
        _relay(requester, 0, cancel);

        bytes32[] memory missed = new bytes32[](1);
        missed[0] = openTask;
        // Booking it before the escrow is back would leave the pool short, so it is refused.
        vm.expectRevert(
            abi.encodeWithSelector(
                ITMPEscrow.EscrowInsolvent.selector, market.totalLiabilities(), market.totalLiabilities() + REWARD
            )
        );
        vm.prank(owner);
        market.backfillLiabilities(missed);

        vm.prank(feeRecipient);
        usdc.transfer(address(market), REWARD);
        vm.prank(owner);
        assertEq(market.backfillLiabilities(missed), 1);
        _relay(requester, 0, cancel);
        (uint256 booked,) = market.escrowRecord(openTask);
        assertEq(booked, 0);
        assertEq(usdc.balanceOf(address(market)), market.totalLiabilities());
    }

    /// @dev completeLiabilities leaves backfillLiabilities open, so the script must run after it too.
    function test_BackfillScript_RunsAfterCompleteLiabilities() public {
        _upgradeAndBackfill();
        uint256 total = market.totalLiabilities();
        vm.setEnv("REV026_TASK_IDS_FILE", "script/upgrades/fixtures/rev026-unknown-task-id.json");
        new Rev026Backfill().run();
        assertTrue(market.liabilitiesInitialised());
        assertEq(market.totalLiabilities(), total, "an unknown id books nothing");
    }

    function test_AfterBackfill_EvaluatorPathsRelease() public {
        _upgradeAndBackfill();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (evaluatedTask, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (evaluatedTask, keccak256("work"))));
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: REWARD, rank: 1 });
        _relay(
            evaluator,
            0,
            abi.encodeCall(
                market.evaluate, (evaluatedTask, ITMPCore.VerdictType.APPROVE, 900, 1000, bytes32(0), awards)
            )
        );
        (uint256 booked,) = market.escrowRecord(evaluatedTask);
        assertEq(booked, REWARD, "evaluate releases the returned evaluator stake");

        vm.warp(block.timestamp + 1 days + 1);
        market.finalizeVerdict(evaluatedTask);
        (booked,) = market.escrowRecord(evaluatedTask);
        assertEq(booked, 0, "finalizeVerdict releases the reward");
        assertEq(market.totalLiabilities(), 2 * REWARD + STAKE, "only the open and claimed tasks stay booked");
        assertEq(usdc.balanceOf(address(market)), market.totalLiabilities());
    }

    function test_PayoutBetweenCutAndBackfill_ReleasesNothingAndIsSkipped() public {
        new Rev026Upgrade().run();
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (openTask, 0)));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = openTask;
        vm.prank(owner);
        assertEq(market.backfillLiabilities(ids), 0, "a task settled before its backfill is skipped");
        assertEq(market.totalLiabilities(), 0);
    }

    function test_Backfill_BooksALiveTaskOwingNothingAtZero() public {
        new Rev026Upgrade().run();
        // A live task whose reject fee took its whole reward owes nothing yet is not terminal.
        bug.bugSetReward(openTask, 0);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = openTask;
        vm.prank(owner);
        assertEq(market.backfillLiabilities(ids), 1);
        (uint256 booked, bool tracked) = market.escrowRecord(openTask);
        assertTrue(tracked, "booked so its later funding is booked too");
        assertEq(booked, 0);
    }

    function test_RevertWhen_BackfillByNonOwner() public {
        new Rev026Upgrade().run();
        vm.expectRevert();
        market.backfillLiabilities(new bytes32[](0));
    }

    function test_RevertWhen_NotAtRev025() public {
        placeAtVersion(address(market), 24);
        Rev026Upgrade step = new Rev026Upgrade();
        vm.expectRevert("Rev026Upgrade: diamond is not at rev025");
        step.run();
    }
}

/// @dev Sends only the first rev026 cut, to stand in for a run that stopped between the two.
contract Rev026UpgradeFirstCutOnly is Rev026Upgrade {
    function applyFirstCut() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = DeployTarget.diamondFor(vm);
        vm.startBroadcast(ownerKey);
        IDiamondCut(diamond).diamondCut(_firstCut(address(new RegistryFacet())), address(0), "");
        vm.stopBroadcast();
    }
}
