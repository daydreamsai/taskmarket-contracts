// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { Rev030Upgrade } from "../script/upgrades/Rev030Upgrade.s.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { MockTaskHook } from "./mocks/MockTaskHook.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @title Rev030UpgradeTest
/// @dev Rev030 replaces every facet whose code changed, Adds the AdminFacet winner-cap selectors and
///      Removes the three V1 hook selectors. The checks prove each replaced facet's selectors reach new
///      bytecode, the Added selectors are routed and the Removed ones are not, the winner cap is set on
///      Tempo and left at the default elsewhere, only a rev029 diamond takes the step, a rerun at rev030
///      is a no-op, a pre-cut task with a V1 hook list settles after the cut with no hook call, and after
///      the cut an operator whose revoke removed its control no longer holds a role on the task it
///      created.
contract Rev030UpgradeTest is Test, DiamondTestHelper {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    uint256 internal constant BUDGET = 10e6;
    uint256 internal constant REWARD = 2e6;
    uint32 internal constant ROLE_STRANGER = uint32(1) << 31;

    address internal owner;
    address internal projectOwner = address(0xB0);
    address internal operator = address(0xB1);
    address internal worker = address(0xB2);

    ITMPDiamond internal market;
    ITMPProject internal projects;
    MockPGTRForwarder internal forwarder;
    MockUSDC internal usdc;
    uint256 internal projectId;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), address(0xFEE0), 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        projects = ITMPProject(address(market));
        initMockPool(address(market), owner);
        usdc.mint(address(forwarder), 1_000e6);
        projectId = abi.decode(
            _relay(
                projectOwner,
                BUDGET,
                abi.encodeCall(
                    projects.createProject, (address(usdc), BUDGET, uint64(block.timestamp + 30 days), 30 days)
                )
            ),
            (uint256)
        );
        // A fresh diamond already routes what rev030 Adds; a rev029 diamond does not.
        IDiamondCut.FacetCut[] memory unroute = new IDiamondCut.FacetCut[](1);
        unroute[0] = IDiamondCut.FacetCut(
            address(0), IDiamondCut.FacetCutAction.Remove, FacetSelectors.selectorsAddedRev030()
        );
        vm.prank(owner);
        IDiamondCut(address(market)).diamondCut(unroute, address(0), "");
        // A rev029 diamond still routes the V1 hook selectors rev030 Removes.
        _routeRemovedRev030(address(market), owner, true);
        placeAtVersion(address(market), 29);

        vm.chainId(84532);
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_84532", vm.toString(address(market)));
    }

    function _relay(address sender, uint256 amount, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, amount, data);
    }

    function test_Upgrade_ReplacesHooksV2FacetAndBumpsVersion() public {
        IDiamondLoupe loupe = IDiamondLoupe(address(market));
        bytes4[] memory selectors = FacetSelectors.hooksV2FacetSelectors();
        address before = loupe.facetAddress(selectors[0]);

        new Rev030Upgrade().run();

        assertEq(AdminFacet(address(market)).diamondVersion(), 30, "diamondVersion 30");
        address after_ = loupe.facetAddress(selectors[0]);
        assertNotEq(after_, before, "HooksV2Facet replaced");
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(loupe.facetAddress(selectors[i]), after_, "every HooksV2Facet selector on the new facet");
        }
    }

    function test_Upgrade_ReplacesEveryChangedFacet() public {
        bytes4[][] memory sets = new bytes4[][](13);
        sets[0] = FacetSelectors.adminFacetSelectorsKeptRev030();
        sets[1] = FacetSelectors.acceptFacetSelectorsRev028();
        sets[2] = FacetSelectors.coreFacetSelectors();
        sets[3] = FacetSelectors.evalFacetSelectors();
        sets[4] = FacetSelectors.hookDispatchFacetSelectors();
        sets[5] = FacetSelectors.hooksV2FacetSelectors();
        sets[6] = FacetSelectors.projectFacetSelectors();
        sets[7] = FacetSelectors.settlementFacetSelectors();
        sets[8] = FacetSelectors.workerFacetSelectors();
        sets[9] = FacetSelectors.cutFacetSelectors();
        sets[10] = FacetSelectors.auctionFacetSelectors();
        sets[11] = FacetSelectors.ratingFacetSelectors();
        sets[12] = FacetSelectors.registryFacetSelectors();
        IDiamondLoupe loupe = IDiamondLoupe(address(market));
        address[] memory before = new address[](sets.length);
        for (uint256 i; i < sets.length; ++i) {
            before[i] = loupe.facetAddress(sets[i][0]);
        }

        new Rev030Upgrade().run();

        for (uint256 i; i < sets.length; ++i) {
            address after_ = loupe.facetAddress(sets[i][0]);
            assertNotEq(after_, before[i], "facet replaced");
            for (uint256 j; j < sets[i].length; ++j) {
                assertEq(loupe.facetAddress(sets[i][j]), after_, "every selector on the new facet");
            }
        }
        bytes4[] memory added = FacetSelectors.selectorsAddedRev030();
        address admin = loupe.facetAddress(sets[0][0]);
        for (uint256 i; i < added.length; ++i) {
            assertEq(loupe.facetAddress(added[i]), admin, "winner-cap selectors on the new AdminFacet");
        }
        bytes4[] memory removed = FacetSelectors.selectorsRemovedRev030();
        for (uint256 i; i < removed.length; ++i) {
            assertEq(loupe.facetAddress(removed[i]), address(0), "V1 hook selector removed");
        }
        assertFalse(AdminFacet(address(market)).paused(), "unpaused after the run");
    }

    /// @dev A task from before the rev028 cut, with a V1 hook in its list, settles after the cut and the
    ///      hook is never called. (The same list on a rev029 diamond would have been dispatched.)
    function test_Upgrade_PreCutTaskWithAV1HookSettlesWithoutIt() public {
        MockTaskHook v1 = new MockTaskHook();
        v1.setRevertOnCheckComplete(true);
        bytes32 taskId = abi.decode(
            _relay(
                projectOwner,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        taskConfig(REWARD, 7 days, TMP_BOUNTY),
                        ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        noEvaluatorConfig(),
                        stakeTerms(false, 0)
                    )
                )
            ),
            (bytes32)
        );
        address[] memory legacy = new address[](1);
        legacy[0] = address(v1);
        makeLegacyV1Task(address(market), taskId, legacy);

        new Rev030Upgrade().run();

        assertEq(market.getTaskHooks(taskId).length, 0, "no hooks to dispatch");
        address[] memory workers = new address[](1);
        workers[0] = worker;
        uint16[] memory shares = new uint16[](1);
        shares[0] = 10_000;
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(
            projectOwner, 0, abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0))
        );
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted), "settled");
        assertEq(v1.checkCompleteCalls(), 0, "the V1 hook is not called");
        assertEq(v1.onCompleteCalls(), 0, "the V1 hook is not called");
        assertTrue(ITMPHooksV2(address(market)).getTaskSettlement(taskId).recorded, "settlement recorded");
    }

    function test_Upgrade_LeavesTheWinnerCapAtTheDefaultOffTempo() public {
        new Rev030Upgrade().run();
        assertEq(AdminFacet(address(market)).maxSubmissionWinners(), 50, "Base keeps 50");
    }

    function test_Upgrade_SetsTheTempoWinnerCap() public {
        vm.chainId(42431);
        vm.setEnv("FORGE_DIAMOND_ADDRESS_42431", vm.toString(address(market)));
        new Rev030Upgrade().run();
        assertEq(AdminFacet(address(market)).maxSubmissionWinners(), 30, "Tempo caps at 30");
        assertEq(AdminFacet(address(market)).diamondVersion(), 30);
    }

    function test_Upgrade_RevokedOperatorLosesItsRolesOnItsTask() public {
        ITMPProject.GrantTerms memory terms = ITMPProject.GrantTerms({
            cap: 0,
            requesterOfRecord: ITMPProject.RequesterOfRecord.Operator,
            ownerOverride: false,
            revokeRemovesControl: true
        });
        _relay(projectOwner, 0, abi.encodeCall(projects.grantOperator, (projectId, operator, terms)));
        _relay(operator, 0, abi.encodeCall(projects.acceptGrant, (projectId, keccak256(abi.encode(terms)))));
        ITMPCore.TaskTerms memory t;
        t.version = 2;
        bytes32 taskId = abi.decode(
            _relay(
                operator,
                0,
                abi.encodeCall(
                    projects.createProjectTask,
                    (
                        projectId,
                        taskConfig(2e6, 7 days, TMP_BOUNTY),
                        ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        noEvaluatorConfig(),
                        t,
                        address(0)
                    )
                )
            ),
            (bytes32)
        );
        _relay(projectOwner, 0, abi.encodeCall(projects.revokeOperator, (projectId, operator)));

        new Rev030Upgrade().run();

        assertEq(market.getTask(taskId).requester, operator, "the operator is still the requester of record");
        assertEq(ITMPHooksV2(address(market)).taskCallerRoles(taskId, operator), ROLE_STRANGER, "no role left");
    }

    function test_RerunAtRev030IsANoOp() public {
        new Rev030Upgrade().run();
        address facet = IDiamondLoupe(address(market)).facetAddress(FacetSelectors.hooksV2FacetSelectors()[0]);
        new Rev030Upgrade().run();
        assertEq(
            IDiamondLoupe(address(market)).facetAddress(FacetSelectors.hooksV2FacetSelectors()[0]),
            facet,
            "the cut was not sent again"
        );
        assertEq(AdminFacet(address(market)).diamondVersion(), 30);
    }

    function test_RevertsUnlessAtRev029() public {
        placeAtVersion(address(market), 28);
        Rev030Upgrade up = new Rev030Upgrade();
        vm.expectRevert("Rev030Upgrade: diamond is not at rev029");
        up.run();
    }

    function test_CutIsSplitOnTempoOnly() public {
        Rev030Upgrade up = new Rev030Upgrade();
        assertTrue(up.splitCut(4217));
        assertTrue(up.splitCut(42431));
        assertFalse(up.splitCut(8453));
        assertFalse(up.splitCut(84532));
    }

    function test_EachCutEntryStaysFarUnderTempoCap() public {
        IDiamondCut.FacetCut[] memory all = new Rev030Upgrade().cut();
        uint256 worst;
        uint256 total;
        for (uint256 i = 0; i < all.length; i++) {
            IDiamondCut.FacetCut[] memory one = new IDiamondCut.FacetCut[](1);
            one[0] = all[i];
            uint256 g = gasleft();
            vm.prank(owner);
            IDiamondCut(address(market)).diamondCut(one, address(0), "");
            uint256 used = g - gasleft();
            total += used;
            if (used > worst) worst = used;
        }
        emit log_named_uint("  largest entry gas", worst);
        emit log_named_uint("  all entries gas", total);
        // Tempo prices state writes about three times higher than this EVM run; the fork check in
        // script/tempo.sh is the real gate, this keeps an entry from growing past it unnoticed.
        assertLt(worst, 8_000_000, "one entry must stay well under Tempo's per-transaction cap");
    }

    function test_TempoRunResumesAfterPartOfTheCutLanded() public {
        vm.chainId(42431);
        vm.setEnv("FORGE_DIAMOND_ADDRESS_42431", vm.toString(address(market)));
        IDiamondCut.FacetCut[] memory all = new Rev030Upgrade().cut();
        vm.startPrank(owner);
        AdminFacet(address(market)).pause();
        for (uint256 i = 0; i < 2; i++) {
            IDiamondCut.FacetCut[] memory one = new IDiamondCut.FacetCut[](1);
            one[0] = all[i];
            IDiamondCut(address(market)).diamondCut(one, address(0), "");
        }
        vm.stopPrank();
        new Rev030Upgrade().run();
        assertEq(AdminFacet(address(market)).diamondVersion(), 30);
        assertEq(AdminFacet(address(market)).maxSubmissionWinners(), 30);
        assertFalse(AdminFacet(address(market)).paused());
        assertEq(
            IDiamondLoupe(address(market)).facetAddress(bytes4(0xe98650f3)), address(0), "the V1 selectors are removed"
        );
    }
}
