// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
import { ITMPHookDispatch } from "../src/interfaces/ITMPHookDispatch.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { Rev028Upgrade } from "../script/upgrades/Rev028Upgrade.s.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { MockTaskHook } from "./mocks/MockTaskHook.sol";
import { MockTaskHookV2 } from "./mocks/MockTaskHookV2.sol";
import { ITMPHook } from "../src/interfaces/ITMPHook.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";

/// @title Rev028UpgradeTest
/// @dev Builds a diamond holding a live V1 task with a V1 hook, strips the rev028 selectors to
///      stand in for a rev027 diamond, runs the cut, and checks the routing, the version, that the
///      pre-cut task keeps V1 dispatch to its end and is recorded, and that new tasks are V2.
/// @dev A V1 hook whose onExpire burns the gas it is given.
contract ExpireGasBurnerV1 is MockTaskHook {
    function onExpire(bytes32 taskId, ITMPCore.TaskContext calldata ctx) external override {
        taskId;
        ctx;
        uint256 stop = gasleft() - 900_000;
        while (gasleft() > stop) { }
    }
}

contract Rev028UpgradeTest is Test, DiamondTestHelper {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    uint256 internal constant REWARD = 100e6;
    bytes32 internal constant WORK = keccak256("work");

    address internal owner;
    address internal requester = address(3);
    address internal worker = address(4);

    ITMPDiamond internal market;
    MockPGTRForwarder internal forwarder;
    MockUSDC internal usdc;
    MockTaskHook internal v1Hook;
    bytes32 internal preCutTask;
    bytes32 internal preCutBurnerTask;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), address(0xFEE0), 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 10_000e6);

        // A task created on the rev027 diamond: V1 hooks.
        placeAtVersion(address(market), 27);
        v1Hook = new MockTaskHook();
        address[] memory hooks = new address[](1);
        hooks[0] = address(v1Hook);
        preCutTask = _create(hooks);
        address[] memory burners = new address[](4);
        for (uint256 i; i < burners.length; ++i) {
            burners[i] = address(new ExpireGasBurnerV1());
        }
        preCutBurnerTask = _create(burners);

        // rev027 routing: no rev028 Adds, and settleLapsedReview and the settlement views on
        // SettlementFacet, where rev027 served them.
        address settlementFacet = IDiamondLoupe(address(market)).facetAddress(ITMPDiamond.refundExpired.selector);
        address projectFacetBefore = IDiamondLoupe(address(market)).facetAddress(ITMPProject.createProject.selector);
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] =
            IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, FacetSelectors.selectorsAddedRev028());
        cuts[1] = IDiamondCut.FacetCut(
            settlementFacet,
            IDiamondCut.FacetCutAction.Replace,
            FacetSelectors.settlementSelectorsMovedToAcceptanceRev028()
        );
        cuts[2] = IDiamondCut.FacetCut(
            settlementFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.settlementViewSelectorsMovedRev028()
        );
        // rev027 routed acceptGrant(uint256), which rev028 replaces with acceptGrant(uint256,bytes32).
        bytes4[] memory oldAcceptGrant = new bytes4[](1);
        oldAcceptGrant[0] = FacetSelectors.acceptGrantSelectorRev027();
        cuts[3] = IDiamondCut.FacetCut(projectFacetBefore, IDiamondCut.FacetCutAction.Add, oldAcceptGrant);
        vm.prank(owner);
        IDiamondCut(address(market)).diamondCut(cuts, address(0), "");

        vm.chainId(84532);
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_84532", vm.toString(address(market)));
    }

    function _relay(address sender, uint256 amount, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, amount, data);
    }

    function _create(address[] memory hooks) internal returns (bytes32) {
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                taskConfig(REWARD, 7 days, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                stakeTerms(false, 0)
            )
        );
        return abi.decode(_relay(requester, REWARD, data), (bytes32));
    }

    function test_Upgrade_RoutesRev028AndBumpsVersion() public {
        IDiamondLoupe loupe = IDiamondLoupe(address(market));
        bytes4[] memory added = FacetSelectors.selectorsAddedRev028();
        for (uint256 i; i < added.length; ++i) {
            assertEq(loupe.facetAddress(added[i]), address(0), "unrouted at rev027");
        }
        address evaluatorBefore = loupe.facetAddress(ITMPDiamond.resolveDispute.selector);
        address registryBefore = loupe.facetAddress(ITMPDiamond.getTaskHooks.selector);
        address adminBefore = loupe.facetAddress(AdminFacet.diamondVersion.selector);

        new Rev028Upgrade().run();

        assertEq(AdminFacet(address(market)).diamondVersion(), 28, "diamondVersion 28");
        address dispatch = loupe.facetAddress(ITMPHookDispatch.hookAcceptV2.selector);
        assertNotEq(dispatch, address(0), "HookDispatchFacet routed");
        bytes4[] memory d = FacetSelectors.hookDispatchFacetSelectors();
        for (uint256 i; i < d.length; ++i) {
            assertEq(loupe.facetAddress(d[i]), dispatch, "dispatch selector");
        }
        address v2Facet = loupe.facetAddress(ITMPHooksV2.getTaskSettlement.selector);
        assertNotEq(v2Facet, address(0), "HooksV2Facet routed");
        assertNotEq(loupe.facetAddress(ITMPDiamond.resolveDispute.selector), evaluatorBefore, "EvaluatorFacet replaced");
        assertNotEq(loupe.facetAddress(ITMPDiamond.getTaskHooks.selector), registryBefore, "RegistryFacet replaced");
        assertNotEq(loupe.facetAddress(AdminFacet.diamondVersion.selector), adminBefore, "AdminFacet replaced");
    }

    function test_Upgrade_SwapsTheAcceptGrantSelector() public {
        IDiamondLoupe loupe = IDiamondLoupe(address(market));
        assertNotEq(loupe.facetAddress(FacetSelectors.acceptGrantSelectorRev027()), address(0), "rev027 routes it");
        assertEq(loupe.facetAddress(ITMPProject.acceptGrant.selector), address(0), "new selector unrouted at rev027");

        new Rev028Upgrade().run();

        assertEq(loupe.facetAddress(FacetSelectors.acceptGrantSelectorRev027()), address(0), "old selector removed");
        assertEq(
            loupe.facetAddress(ITMPProject.acceptGrant.selector),
            loupe.facetAddress(ITMPProject.createProject.selector),
            "new selector routed to ProjectFacet"
        );
    }

    function test_PreCutTask_ExpiryRefundIsNotBlockedByAggregateHookGas() public {
        new Rev028Upgrade().run();
        assertEq(ITMPHooksV2(address(market)).getTaskHookVersion(preCutBurnerTask), 0, "still V1");
        vm.warp(block.timestamp + 8 days);
        // Four hooks each burn about a stipend; supplying less than all four need still refunds.
        market.refundExpired{ gas: 3_400_000 }(preCutBurnerTask, 0);
        assertEq(uint8(market.getTaskState(preCutBurnerTask)), uint8(ITMPCore.TaskStatus.Expired));
    }

    function test_PreCutTaskKeepsV1DispatchAndIsRecorded() public {
        new Rev028Upgrade().run();
        assertEq(ITMPHooksV2(address(market)).getTaskHookVersion(preCutTask), 0, "still V1");
        _relay(worker, 0, abi.encodeCall(market.claimTask, (preCutTask, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (preCutTask, WORK)));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (preCutTask, worker, WORK, 0)));
        assertEq(v1Hook.checkCompleteCalls(), 1, "V1 checkComplete ran");
        assertTrue(ITMPHooksV2(address(market)).getTaskSettlement(preCutTask).recorded, "recorded after the cut");
    }

    function test_NewTasksAreV2AfterTheCut() public {
        new Rev028Upgrade().run();
        address[] memory hooks = new address[](1);
        hooks[0] = address(new MockTaskHookV2(address(market), 1));
        bytes32 taskId = _create(hooks);
        assertEq(ITMPHooksV2(address(market)).getTaskHookVersion(taskId), 2);
        assertEq(market.getTaskHooks(taskId)[0], hooks[0], "getTaskHooks reads V2 attachments after the cut");

        hooks[0] = address(new MockTaskHook());
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookV1Retired.selector, uint8(0)));
        _relay(
            requester,
            REWARD,
            abi.encodeCall(
                market.createTask,
                (
                    taskConfig(REWARD, 7 days, TMP_CLAIM),
                    ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                    ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                    noEvaluatorConfig(),
                    stakeTerms(false, 0)
                )
            )
        );
    }

    /// @dev Each cut must fit Tempo's per-transaction gas cap (about 29.9M) with room to spare. Tempo
    ///      charges about 250,000 gas for a new storage slot against about 22,100 here, so the
    ///      estimate adds that difference for every slot a cut creates.
    function test_EachCutFitsTempo() public {
        placeAtVersion(address(market), 27);
        Rev028Upgrade up = new Rev028Upgrade();
        IDiamondCut.FacetCut[][] memory cuts = new IDiamondCut.FacetCut[][](4);
        cuts[0] = up.cutOne();
        cuts[1] = up.cutTwo();
        cuts[2] = up.cutThree();
        cuts[3] = up.cutFour();
        for (uint256 k; k < 4; ++k) {
            vm.startStateDiffRecording();
            uint256 g = gasleft();
            vm.prank(owner);
            IDiamondCut(address(market)).diamondCut(cuts[k], address(0), "");
            uint256 used = g - gasleft();
            Vm.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();
            uint256 fresh;
            for (uint256 a; a < diff.length; ++a) {
                for (uint256 b; b < diff[a].storageAccesses.length; ++b) {
                    Vm.StorageAccess memory st = diff[a].storageAccesses[b];
                    if (st.isWrite && !st.reverted && st.previousValue == bytes32(0) && st.newValue != bytes32(0)) {
                        ++fresh;
                    }
                }
            }
            uint256 tempoEstimate = used + fresh * (250_000 - 22_100);
            emit log_named_uint("cut", k + 1);
            emit log_named_uint("  gas here", used);
            emit log_named_uint("  new slots", fresh);
            emit log_named_uint("  Tempo estimate", tempoEstimate);
            assertLt(tempoEstimate, 20_000_000, "a cut must stay well under Tempo's per-transaction cap");
        }
        vm.prank(owner);
        AdminFacet(address(market)).setDiamondVersion(28);
        assertEq(market.getTaskHooks(preCutTask)[0], address(v1Hook), "settlement views and registry routed");
    }

    /// @dev The diamond is usable between cuts: after cutOne alone, and after cutTwo, a pre-cut V1
    ///      task still claims, submits and settles, and the version stays 27 until the bump.
    function test_DiamondConsistentBetweenCuts() public {
        placeAtVersion(address(market), 27);
        Rev028Upgrade up = new Rev028Upgrade();
        IDiamondCut.FacetCut[] memory one = up.cutOne();
        vm.prank(owner);
        IDiamondCut(address(market)).diamondCut(one, address(0), "");
        assertEq(AdminFacet(address(market)).diamondVersion(), 27, "still rev027 after cutOne");
        _relay(worker, 0, abi.encodeCall(market.claimTask, (preCutTask, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (preCutTask, WORK)));
        assertEq(v1Hook.checkClaimCalls(), 1, "V1 claim check ran through the new dispatch");

        IDiamondCut.FacetCut[] memory two = up.cutTwo();
        vm.prank(owner);
        IDiamondCut(address(market)).diamondCut(two, address(0), "");
        assertEq(AdminFacet(address(market)).diamondVersion(), 27, "still rev027 after cutTwo");
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (preCutTask, worker, WORK, 0)));
        assertEq(v1Hook.checkCompleteCalls(), 1, "V1 accept check ran");
        assertTrue(ITMPHooksV2(address(market)).getTaskSettlement(preCutTask).recorded, "recorded");
    }

    function test_UpgradePausesAcrossTheCuts() public {
        placeAtVersion(address(market), 27);
        new Rev028Upgrade().run();
        assertFalse(AdminFacet(address(market)).paused(), "unpaused after the bump");
        assertEq(AdminFacet(address(market)).diamondVersion(), 28);
    }

    /// @dev After a partial failure (cutOne and cutTwo landed, the diamond paused), a rerun sends
    ///      only the missing cuts, bumps the version and unpauses; a further rerun changes nothing.
    function test_ResumesAfterAPartialRun() public {
        placeAtVersion(address(market), 27);
        Rev028Upgrade up = new Rev028Upgrade();
        vm.startPrank(owner);
        AdminFacet(address(market)).pause();
        IDiamondCut(address(market)).diamondCut(up.cutOne(), address(0), "");
        IDiamondCut(address(market)).diamondCut(up.cutTwo(), address(0), "");
        vm.stopPrank();
        bool[4] memory landed = up.cutsLanded(address(market));
        assertTrue(landed[0] && landed[1], "first two cuts detected");
        assertFalse(landed[2] || landed[3], "last two cuts missing");
        address acceptance = IDiamondLoupe(address(market)).facetAddress(ITMPDiamond.acceptSubmission.selector);

        up.run();
        assertEq(AdminFacet(address(market)).diamondVersion(), 28);
        assertFalse(AdminFacet(address(market)).paused(), "unpaused though the failed run left it paused");
        assertEq(
            IDiamondLoupe(address(market)).facetAddress(ITMPDiamond.acceptSubmission.selector),
            acceptance,
            "cutTwo was not sent again"
        );
        landed = up.cutsLanded(address(market));
        assertTrue(landed[0] && landed[1] && landed[2] && landed[3], "all four cuts on the diamond");

        new Rev028Upgrade().run();
        assertEq(
            IDiamondLoupe(address(market)).facetAddress(ITMPDiamond.acceptSubmission.selector),
            acceptance,
            "a rerun is a no-op"
        );
    }

    function test_RevertsUnlessAtRev027() public {
        placeAtVersion(address(market), 26);
        Rev028Upgrade up = new Rev028Upgrade();
        vm.expectRevert("Rev028Upgrade: diamond is not at rev027");
        up.run();
    }
}
