// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPTerms } from "../src/interfaces/ITMPTerms.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { CoreFacet } from "../src/facets/CoreFacet.sol";
import { TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";

/// @title CoreFacetSplitTest
/// @dev rev027 splits CoreFacet: the worker entrypoints move to WorkerFacet and task creation to
///      LibTaskCreation. Checks that every selector routes to the right facet, that CoreFacet
///      serves none of the moved ones, that both facets have room under the size limit, and that a
///      task still runs from creation to acceptance across the two facets.
contract CoreFacetSplitTest is Test, DiamondTestHelper {
    uint256 internal constant REWARD = 100e6;
    uint256 internal constant STAKE = 10e6;
    uint256 internal constant MAX_CONTRACT_SIZE = 24_576;

    address internal owner = address(1);
    address internal requester = address(3);
    address internal worker = address(4);

    ITMPDiamond internal market;
    MockPGTRForwarder internal forwarder;
    MockUSDC internal usdc;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), address(0xFEE0), 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 10_000e6);
    }

    function _relay(address sender, uint256 amount, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, amount, data);
    }

    function test_EverySelectorRoutesToItsFacet() public view {
        IDiamondLoupe loupe = IDiamondLoupe(address(market));
        address core = loupe.facetAddress(ITMPDiamond.createTask.selector);
        address workerFacet = loupe.facetAddress(ITMPDiamond.claimTask.selector);
        assertNotEq(core, workerFacet, "two facets");

        bytes4[] memory coreSelectors = FacetSelectors.coreFacetSelectors();
        for (uint256 i; i < coreSelectors.length; ++i) {
            assertEq(loupe.facetAddress(coreSelectors[i]), core, "core selector on CoreFacet");
        }
        bytes4[] memory workerSelectors = FacetSelectors.workerFacetSelectors();
        for (uint256 i; i < workerSelectors.length; ++i) {
            assertEq(loupe.facetAddress(workerSelectors[i]), workerFacet, "worker selector on WorkerFacet");
        }
    }

    function test_CoreFacetNoLongerServesWorkerSelectors() public {
        address core = address(new CoreFacet());
        bytes4[] memory workerSelectors = FacetSelectors.workerFacetSelectors();
        for (uint256 i; i < workerSelectors.length; ++i) {
            (bool ok,) = core.call(abi.encodePacked(workerSelectors[i], new bytes(96)));
            assertFalse(ok, "CoreFacet does not implement a moved selector");
        }
    }

    function test_BothFacetsHaveRoomUnderTheSizeLimit() public {
        // Coverage builds without the optimizer, so its bytecode says nothing about deployed size.
        vm.skip(vm.isContext(VmSafe.ForgeContext.Coverage));
        IDiamondLoupe loupe = IDiamondLoupe(address(market));
        uint256 coreSize = loupe.facetAddress(ITMPDiamond.createTask.selector).code.length;
        uint256 workerSize = loupe.facetAddress(ITMPDiamond.claimTask.selector).code.length;
        emit log_named_uint("CoreFacet deployed size", coreSize);
        emit log_named_uint("WorkerFacet deployed size", workerSize);
        assertLt(coreSize, MAX_CONTRACT_SIZE - 4096, "CoreFacet keeps at least 4 KiB of room");
        assertLt(workerSize, MAX_CONTRACT_SIZE - 4096, "WorkerFacet keeps at least 4 KiB of room");
    }

    function test_TaskRunsAcrossBothFacets() public {
        bytes memory data = abi.encodeCall(
            ITMPTerms.createTask,
            (
                taskConfig(REWARD, 7 days, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                stakeTerms(true, 1000)
            )
        );
        bytes32 taskId = abi.decode(_relay(requester, REWARD, data), (bytes32));
        _relay(worker, STAKE, abi.encodeCall(market.claimTask, (taskId, STAKE)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Accepted));
        assertEq(market.totalLiabilities(), 0, "every liability released");
        assertEq(usdc.balanceOf(address(market)), 0, "escrow empty");
    }
}
