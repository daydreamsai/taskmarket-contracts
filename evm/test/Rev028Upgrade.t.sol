// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { Rev028Upgrade } from "../script/upgrades/Rev028Upgrade.s.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";

/// @title Rev028UpgradeTest
/// @dev Builds a diamond holding a live task, strips the rev028 selectors to stand in for a rev027
///      diamond, runs the cut, and checks the routing, the version, the live task and a project end
///      to end.
contract Rev028UpgradeTest is Test, DiamondTestHelper {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    uint256 internal constant REWARD = 100e6;

    address internal owner;
    address internal requester = address(3);
    address internal feeRecipient = address(0xFEE0);

    ITMPDiamond internal market;
    MockPGTRForwarder internal forwarder;
    MockUSDC internal usdc;
    bytes32 internal liveTask;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 10_000e6);

        liveTask = abi.decode(
            _relay(
                requester,
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

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(
            address(0), IDiamondCut.FacetCutAction.Remove, FacetSelectors.selectorsAddedRev028()
        );
        vm.prank(owner);
        IDiamondCut(address(market)).diamondCut(cuts, address(0), "");
        placeAtVersion(address(market), 27);

        vm.chainId(84532);
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_84532", vm.toString(address(market)));
    }

    function _relay(address sender, uint256 amount, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, amount, data);
    }

    function test_Upgrade_AddsProjectFacetAndReplacesThePayingFacets() public {
        IDiamondLoupe loupe = IDiamondLoupe(address(market));
        bytes4[] memory added = FacetSelectors.selectorsAddedRev028();
        for (uint256 i; i < added.length; ++i) {
            assertEq(loupe.facetAddress(added[i]), address(0), "unrouted at rev027");
        }
        address coreBefore = loupe.facetAddress(ITMPDiamond.createTask.selector);
        address acceptBefore = loupe.facetAddress(ITMPDiamond.acceptSubmission.selector);
        address evalBefore = loupe.facetAddress(ITMPDiamond.evaluate.selector);
        address settlementBefore = loupe.facetAddress(ITMPDiamond.refundExpired.selector);

        new Rev028Upgrade().run();

        assertEq(AdminFacet(address(market)).diamondVersion(), 28, "diamondVersion 28");
        address projectFacet = loupe.facetAddress(ITMPProject.createProject.selector);
        assertNotEq(projectFacet, address(0), "ProjectFacet routed");
        for (uint256 i; i < added.length; ++i) {
            assertEq(loupe.facetAddress(added[i]), projectFacet, "every project selector on ProjectFacet");
        }
        assertNotEq(loupe.facetAddress(ITMPDiamond.createTask.selector), coreBefore, "CoreFacet replaced");
        assertNotEq(loupe.facetAddress(ITMPDiamond.acceptSubmission.selector), acceptBefore, "AcceptanceFacet replaced");
        assertNotEq(loupe.facetAddress(ITMPDiamond.evaluate.selector), evalBefore, "EvaluatorFacet replaced");
        assertNotEq(
            loupe.facetAddress(ITMPDiamond.refundExpired.selector), settlementBefore, "SettlementFacet replaced"
        );
    }

    function test_Upgrade_RefusesWrongVersion() public {
        placeAtVersion(address(market), 26);
        Rev028Upgrade step = new Rev028Upgrade();
        vm.expectRevert(bytes("Rev028Upgrade: diamond is not at rev027"));
        step.run();
    }

    function test_Upgrade_LiveTaskRefundsItsRequesterAndAProjectRuns() public {
        new Rev028Upgrade().run();

        // A task live at the cut belongs to no project and refunds its requester as before.
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (liveTask, 0)));
        assertEq(usdc.balanceOf(requester), REWARD);

        ITMPProject projects = ITMPProject(address(market));
        uint256 id = abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(projects.createProject, (address(usdc), REWARD, uint64(block.timestamp + 30 days)))
            ),
            (uint256)
        );
        assertEq(projects.getProject(id).available, REWARD);
        assertEq(market.totalLiabilities(), REWARD);
        assertEq(usdc.balanceOf(address(market)), REWARD);
    }
}
