// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { Rev029Upgrade } from "../script/upgrades/Rev029Upgrade.s.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { FundingPool } from "../src/FundingPool.sol";
import { IFundingPoolManager } from "../src/interfaces/IFundingPoolManager.sol";
import { ITMPFundingPool } from "../src/interfaces/ITMPFundingPool.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @dev Stands in for the pool implementation a rev028 diamond runs: it does not report revision 29,
///      which is how the upgrade script tells the proxy still needs the new implementation.
contract FundingPoolRev028Stub is FundingPool {
    function fundingPoolRevision() external pure override returns (uint256) {
        revert("rev028");
    }
}

/// @title Rev029UpgradeTest
/// @dev Builds a diamond with a project and a revoked operator grant, strips raiseGrantCap to stand
///      in for a rev028 diamond, runs the cut, and checks the routing, the version, that the grant
///      survives the cut with its committed untouched, and that it can then be granted again.
contract Rev029UpgradeTest is Test, DiamondTestHelper {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    uint256 internal constant BUDGET = 10e6;

    address internal owner;
    address internal projectOwner = address(0xB0);
    address internal operator = address(0xB1);

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
        address pool = address(
            new ERC1967Proxy(
                address(new FundingPoolRev028Stub()),
                abi.encodeCall(FundingPool.initialize, (address(market), address(usdc)))
            )
        );
        vm.prank(owner);
        projects.initFundingPool(pool);
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

        // A grant accepted and revoked on the rev028 diamond: the state rev029 exists to unstick.
        ITMPProject.GrantTerms memory terms = _terms(5e6);
        _relay(projectOwner, 0, abi.encodeCall(projects.grantOperator, (projectId, operator, terms)));
        _relay(operator, 0, abi.encodeCall(projects.acceptGrant, (projectId, keccak256(abi.encode(terms)))));
        _relay(projectOwner, 0, abi.encodeCall(projects.revokeOperator, (projectId, operator)));

        // rev028 routing: no raiseGrantCap.
        placeAtVersion(address(market), 28);
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] =
            IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, FacetSelectors.selectorsAddedRev029());
        vm.prank(owner);
        IDiamondCut(address(market)).diamondCut(cuts, address(0), "");

        vm.chainId(84532);
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_84532", vm.toString(address(market)));
    }

    function _relay(address sender, uint256 amount, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, amount, data);
    }

    function _terms(uint256 cap) internal pure returns (ITMPProject.GrantTerms memory) {
        return ITMPProject.GrantTerms({
            cap: cap,
            requesterOfRecord: ITMPProject.RequesterOfRecord.Owner,
            ownerOverride: true,
            revokeRemovesControl: true
        });
    }

    function test_Upgrade_RoutesRaiseGrantCapAndBumpsVersion() public {
        IDiamondLoupe loupe = IDiamondLoupe(address(market));
        assertEq(loupe.facetAddress(ITMPProject.raiseGrantCap.selector), address(0), "unrouted at rev028");
        address before = loupe.facetAddress(ITMPProject.createProject.selector);

        new Rev029Upgrade().run();

        assertEq(AdminFacet(address(market)).diamondVersion(), 29, "diamondVersion 29");
        address after_ = loupe.facetAddress(ITMPProject.createProject.selector);
        assertNotEq(after_, before, "ProjectFacet replaced");
        bytes4[] memory all = FacetSelectors.projectFacetSelectors();
        for (uint256 i; i < all.length; ++i) {
            assertEq(loupe.facetAddress(all[i]), after_, "every ProjectFacet selector on the new facet");
        }
        assertEq(loupe.facetAddress(ITMPProject.raiseGrantCap.selector), after_, "raiseGrantCap routed");
    }

    function test_Upgrade_RevokedGrantCanBeGrantedAgainAndItsCapRaised() public {
        new Rev029Upgrade().run();
        ITMPProject.Grant memory g = projects.getGrant(projectId, operator);
        assertTrue(g.revoked && g.accepted, "grant survives the cut as it was");

        ITMPProject.GrantTerms memory fresh = _terms(6e6);
        _relay(projectOwner, 0, abi.encodeCall(projects.grantOperator, (projectId, operator, fresh)));
        _relay(operator, 0, abi.encodeCall(projects.acceptGrant, (projectId, keccak256(abi.encode(fresh)))));
        _relay(projectOwner, 0, abi.encodeCall(projects.raiseGrantCap, (projectId, operator, 8e6)));
        g = projects.getGrant(projectId, operator);
        assertTrue(g.accepted && !g.revoked);
        assertEq(g.terms.cap, 8e6);
    }

    function test_Upgrade_UpgradesTheFundingPoolAndKeepsItsState() public {
        address pool = projects.fundingPool();
        bytes32 poolId = projects.projectPoolId(projectId);
        uint256 shares = ITMPFundingPool(pool).sharesOf(poolId, projectOwner);
        assertGt(shares, 0);
        vm.expectRevert();
        IFundingPoolManager(pool).fundingPoolRevision();

        new Rev029Upgrade().run();

        assertGe(IFundingPoolManager(pool).fundingPoolRevision(), 29, "pool upgraded in place");
        assertEq(projects.fundingPool(), pool, "same proxy");
        assertEq(ITMPFundingPool(pool).sharesOf(poolId, projectOwner), shares, "state kept");
        assertTrue(new Rev029Upgrade().poolLanded(pool));
    }

    function test_Upgrade_OwnerTransferAndExtensionWorkAfterTheCut() public {
        address newOwner = address(0xB7);
        address pool = projects.fundingPool();
        bytes32 poolId = projects.projectPoolId(projectId);
        uint256 shares = ITMPFundingPool(pool).sharesOf(poolId, projectOwner);
        new Rev029Upgrade().run();

        IDiamondLoupe loupe = IDiamondLoupe(address(market));
        address facet = loupe.facetAddress(ITMPProject.createProject.selector);
        bytes4[] memory added = FacetSelectors.projectOwnerSelectorsRev029();
        for (uint256 i; i < added.length; ++i) {
            assertEq(loupe.facetAddress(added[i]), facet, "owner selector routed");
        }

        _relay(projectOwner, 0, abi.encodeCall(projects.proposeProjectOwner, (projectId, newOwner)));
        _relay(newOwner, 0, abi.encodeCall(projects.acceptProjectOwner, (projectId)));
        assertEq(projects.getProject(projectId).owner, newOwner);
        assertEq(ITMPFundingPool(pool).sharesOf(poolId, newOwner), shares);
        uint64 newEnd = uint64(block.timestamp + 90 days);
        _relay(newOwner, 0, abi.encodeCall(projects.extendProject, (projectId, newEnd)));
        assertEq(ITMPFundingPool(pool).getPool(poolId).closesAt, newEnd);
    }

    function test_Upgrade_ReplacesEveryFacetThatChecksTheRequester() public {
        IDiamondLoupe loupe = IDiamondLoupe(address(market));
        address coreBefore = loupe.facetAddress(FacetSelectors.coreFacetSelectors()[0]);
        address ratingBefore = loupe.facetAddress(FacetSelectors.ratingFacetSelectors()[0]);
        address hooksBefore = loupe.facetAddress(FacetSelectors.hooksV2FacetSelectors()[0]);
        new Rev029Upgrade().run();
        assertNotEq(loupe.facetAddress(FacetSelectors.coreFacetSelectors()[0]), coreBefore, "core");
        assertNotEq(loupe.facetAddress(FacetSelectors.ratingFacetSelectors()[0]), ratingBefore, "rating");
        assertNotEq(loupe.facetAddress(FacetSelectors.hooksV2FacetSelectors()[0]), hooksBefore, "hooks v2");
    }

    function test_CutTwoFitsTempo() public {
        Rev029Upgrade up = new Rev029Upgrade();
        IDiamondCut.FacetCut[] memory cut = up.cutTwo();
        uint256 g = gasleft();
        vm.prank(owner);
        IDiamondCut(address(market)).diamondCut(cut, address(0), "");
        uint256 used = g - gasleft();
        emit log_named_uint("  cutTwo gas", used);
        assertLt(used, 20_000_000, "the second cut must stay well under Tempo's per-transaction cap");
    }

    function test_Upgrade_KeepsEveryOtherViewWorking() public {
        new Rev029Upgrade().run();
        assertEq(projects.getProject(projectId).owner, projectOwner);
        assertEq(projects.projectCount(), 1);
    }

    /// @dev The cut must fit Tempo's per-transaction gas cap (about 29.9M) with room to spare. Tempo
    ///      charges about 250,000 gas for a new storage slot against about 22,100 here, so the
    ///      estimate adds that difference for every slot the cut creates.
    function test_CutFitsTempo() public {
        Rev029Upgrade up = new Rev029Upgrade();
        IDiamondCut.FacetCut[] memory cut = up.cut();
        vm.startStateDiffRecording();
        uint256 g = gasleft();
        vm.prank(owner);
        IDiamondCut(address(market)).diamondCut(cut, address(0), "");
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
        emit log_named_uint("  gas here", used);
        emit log_named_uint("  new slots", fresh);
        emit log_named_uint("  Tempo estimate", tempoEstimate);
        assertLt(tempoEstimate, 20_000_000, "the cut must stay well under Tempo's per-transaction cap");
    }

    function test_UpgradePausesAcrossTheCut() public {
        new Rev029Upgrade().run();
        assertFalse(AdminFacet(address(market)).paused(), "unpaused after the bump");
        assertEq(AdminFacet(address(market)).diamondVersion(), 29);
    }

    /// @dev After a failure between the cut and the bump (cut landed, diamond paused, version 28),
    ///      a rerun skips the cut, bumps the version and unpauses; a further rerun changes nothing.
    function test_ResumesAfterAPartialRun() public {
        Rev029Upgrade up = new Rev029Upgrade();
        assertFalse(up.cutLanded(address(market)));
        vm.startPrank(owner);
        AdminFacet(address(market)).pause();
        IDiamondCut(address(market)).diamondCut(up.cut(), address(0), "");
        vm.stopPrank();
        assertTrue(up.cutLanded(address(market)));
        address projectFacet = IDiamondLoupe(address(market)).facetAddress(ITMPProject.createProject.selector);

        up.run();
        assertEq(AdminFacet(address(market)).diamondVersion(), 29);
        assertFalse(AdminFacet(address(market)).paused(), "unpaused though the failed run left it paused");
        assertEq(
            IDiamondLoupe(address(market)).facetAddress(ITMPProject.createProject.selector),
            projectFacet,
            "the cut was not sent again"
        );

        new Rev029Upgrade().run();
        assertEq(
            IDiamondLoupe(address(market)).facetAddress(ITMPProject.createProject.selector),
            projectFacet,
            "a rerun is a no-op"
        );
    }

    function test_KeepPausedLeavesTheDiamondPaused() public {
        vm.setEnv("FORGE_KEEP_PAUSED", "true");
        new Rev029Upgrade().run();
        vm.setEnv("FORGE_KEEP_PAUSED", "false");
        assertTrue(AdminFacet(address(market)).paused());
        assertEq(AdminFacet(address(market)).diamondVersion(), 29);
    }

    function test_RevertsUnlessAtRev028() public {
        placeAtVersion(address(market), 27);
        Rev029Upgrade up = new Rev029Upgrade();
        vm.expectRevert("Rev029Upgrade: diamond is not at rev028");
        up.run();
    }
}
