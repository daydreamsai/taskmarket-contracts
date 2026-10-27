// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPReservation } from "../src/interfaces/ITMPReservation.sol";
import { ITMPTermsV1 } from "../src/interfaces/ITMPTerms.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { Rev027Upgrade } from "../script/upgrades/Rev027Upgrade.s.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";

/// @title Rev027UpgradeTest
/// @dev Builds a diamond holding a live claimed task, strips the rev027 selectors to stand in for a
///      rev026 diamond, runs the cut, and checks the routing, the version, the live task, the
///      rev025 createTask selector and a task with a reserved worker end to end.
contract Rev027UpgradeTest is Test, DiamondTestHelper {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    uint256 internal constant REWARD = 100e6;
    uint256 internal constant STAKE = 10e6;

    address internal owner;
    address internal requester = address(3);
    address internal worker = address(4);
    address internal feeRecipient = address(0xFEE0);

    ITMPDiamond internal market;
    MockPGTRForwarder internal forwarder;
    MockUSDC internal usdc;
    bytes32 internal claimedTask;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 10_000e6);

        claimedTask = _createV1();
        _relay(worker, STAKE, abi.encodeCall(market.claimTask, (claimedTask, STAKE)));
        _storeAsVersion1(claimedTask);

        _makeRev026();
    }

    function _relay(address sender, uint256 amount, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, amount, data);
    }

    /// @dev Through the rev025 selector, as a pre-rev027 caller would.
    function _createV1() internal returns (bytes32) {
        ITMPCore.TaskTermsV1 memory v1;
        v1.version = 1;
        v1.stakeRequired = true;
        v1.stakeBps = 1000;
        bytes memory data = abi.encodeCall(
            ITMPTermsV1.createTask,
            (
                taskConfig(REWARD, 7 days, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                v1
            )
        );
        return abi.decode(_relay(requester, REWARD, data), (bytes32));
    }

    /// @dev This build's facet stores version 2, so rewrite the slot to what a rev026 facet left:
    ///      version 1 in the low byte, the top four bytes (acceptWindowSecs) still zero.
    function _storeAsVersion1(bytes32 taskId) internal {
        vm.record();
        market.getTaskTerms(taskId);
        (bytes32[] memory reads,) = vm.accesses(address(market));
        for (uint256 i; i < reads.length; ++i) {
            uint256 word = uint256(vm.load(address(market), reads[i]));
            if (uint8(word) == 2 && word >> 224 == 0 && (word >> 8) & 1 == 1) {
                vm.store(address(market), reads[i], bytes32((word & ~uint256(0xff)) | 1));
                assertEq(market.getTaskTerms(taskId).version, 1, "stored as version 1");
                return;
            }
        }
        revert("terms slot not found");
    }

    function _rev027Added() internal pure returns (bytes4[] memory s) {
        s = FacetSelectors.selectorsAddedRev027();
    }

    /// @dev A rev026 diamond: no rev027 selector routed, version 26.
    function _makeRev026() internal {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, _rev027Added());
        vm.prank(owner);
        IDiamondCut(address(market)).diamondCut(cuts, address(0), "");
        placeAtVersion(address(market), 26);

        vm.chainId(84532);
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_84532", vm.toString(address(market)));
    }

    function test_Upgrade_RoutesEveryRev027SelectorAndBumpsVersion() public {
        IDiamondLoupe loupe = IDiamondLoupe(address(market));
        bytes4[] memory added = _rev027Added();
        for (uint256 i; i < added.length; ++i) {
            assertEq(loupe.facetAddress(added[i]), address(0), "unrouted at rev026");
        }
        address coreBefore = loupe.facetAddress(FacetSelectors.REV025_CREATE_TASK);
        address settlementBefore = loupe.facetAddress(ITMPDiamond.refundExpired.selector);
        address feedbackBefore = loupe.facetAddress(ITMPDiamond.feedbackValue.selector);
        address evaluatorBefore = loupe.facetAddress(ITMPDiamond.evaluatorTimeout.selector);

        new Rev027Upgrade().run();

        assertEq(AdminFacet(address(market)).diamondVersion(), 27, "diamondVersion 27");
        address core = loupe.facetAddress(FacetSelectors.REV025_CREATE_TASK);
        assertNotEq(core, coreBefore, "CoreFacet replaced; the rev025 selector stays routed");
        assertEq(loupe.facetAddress(ITMPReservation.createTask.selector), core, "reserved createTask on CoreFacet");
        assertEq(loupe.facetAddress(ITMPDiamond.createTask.selector), core, "version 2 createTask on CoreFacet");
        address settlement = loupe.facetAddress(ITMPDiamond.refundExpired.selector);
        assertNotEq(settlement, settlementBefore, "SettlementFacet replaced");
        assertEq(loupe.facetAddress(ITMPDiamond.declineReservation.selector), settlement);
        assertEq(loupe.facetAddress(ITMPDiamond.getReservation.selector), settlement);
        assertEq(loupe.facetAddress(ITMPDiamond.requesterTimeout.selector), settlement, "requesterTimeout added");
        address evaluator = loupe.facetAddress(ITMPDiamond.evaluatorTimeout.selector);
        assertNotEq(evaluator, evaluatorBefore, "EvaluatorFacet replaced: evaluatorTimeout loses its forwarder gate");
        address feedback = loupe.facetAddress(ITMPDiamond.feedbackValue.selector);
        assertNotEq(feedback, feedbackBefore, "FeedbackFacet replaced");
        assertEq(loupe.facetAddress(ITMPDiamond.workerAgentOf.selector), feedback);
        address workerFacet = loupe.facetAddress(ITMPReservation.claimTask.selector);
        assertNotEq(workerFacet, core, "claimTask with an agent ID on WorkerFacet");
        bytes4[] memory moved = FacetSelectors.workerFacetSelectorsFromCore();
        for (uint256 i; i < moved.length; ++i) {
            assertEq(loupe.facetAddress(moved[i]), workerFacet, "moved selector on WorkerFacet");
        }
    }

    function test_Upgrade_RefusesWrongVersion() public {
        placeAtVersion(address(market), 25);
        Rev027Upgrade step = new Rev027Upgrade();
        vm.expectRevert(bytes("Rev027Upgrade: diamond is not at rev026"));
        step.run();
    }

    function test_Upgrade_LiveTaskSettlesAndReservedTaskRuns() public {
        new Rev027Upgrade().run();

        // A version 1 task live at the cut still reads its terms and settles.
        ITMPCore.TaskTerms memory live = market.getTaskTerms(claimedTask);
        assertEq(live.version, 1, "stored version 1 terms survive the cut");
        assertEq(live.acceptWindowSecs, 0, "no accept window on a version 1 task");
        (address reserved,) = market.getReservation(claimedTask);
        assertEq(reserved, address(0), "no reserved worker");
        _relay(worker, 0, abi.encodeCall(market.submitWork, (claimedTask, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (claimedTask, worker, keccak256("work"), 0)));
        assertEq(uint8(market.getTask(claimedTask).status), uint8(ITMPCore.TaskStatus.Accepted));

        // The rev025 selector still creates.
        bytes32 legacy = _createV1();
        assertEq(market.getTask(legacy).requester, requester, "rev025 createTask still creates");
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (legacy, 0)));

        bytes memory data = abi.encodeCall(
            ITMPReservation.createTask,
            (
                taskConfig(REWARD, 7 days, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                stakeTerms(false, 0),
                worker
            )
        );
        bytes32 taskId = abi.decode(_relay(requester, REWARD, data), (bytes32));
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("hire"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("hire"), 0)));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Accepted));
        assertEq(market.totalLiabilities(), 0, "every liability released");
        assertEq(usdc.balanceOf(address(market)), 0, "escrow empty");
    }
}
