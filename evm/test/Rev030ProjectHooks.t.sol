// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
import { TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { BaseTMPHookV2 } from "../src/hooks/base/BaseTMPHookV2.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { MockTaskHookV2 } from "./mocks/MockTaskHookV2.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";

/// @dev Records the project id its beforeCreate and its observer saw.
contract ProjectProbeHook is BaseTMPHookV2 {
    uint256 public createProjectId = type(uint256).max;
    uint256 public observedCreates;

    constructor(address diamond_) BaseTMPHookV2(diamond_) { }

    function hookCapabilities() external pure override returns (uint32) {
        return uint32(1) | (uint32(1) << 25);
    }

    function beforeCreate(bytes32, TaskContextV2 calldata ctx, bytes calldata, bytes calldata)
        external
        override
        returns (bytes4)
    {
        createProjectId = ctx.projectId;
        return this.beforeCreate.selector;
    }

    function afterAction(bytes32, TaskContextV2 calldata, uint8 action, bytes calldata, uint64) external override {
        if (action == 0) ++observedCreates;
    }
}

/// @dev rev030: a project task's creation is observed and shows its project to beforeCreate, and
///      the per-task hook limit cannot be set below the default hooks.
contract Rev030ProjectHooksTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xB0);

    uint256 internal constant REWARD = 100e6;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 100_000e6);
    }

    function test_CreateProjectTask_RunsBeforeCreateWithProjectIdAndObserver() public {
        initMockPool(address(market), owner);
        ITMPProject projects = ITMPProject(address(market));
        uint256 projectId = abi.decode(
            forwarder.relay(
                address(market),
                requester,
                REWARD * 2,
                abi.encodeCall(
                    projects.createProject, (address(usdc), REWARD * 2, uint64(block.timestamp + 30 days), 30 days)
                )
            ),
            (uint256)
        );
        ProjectProbeHook hook = new ProjectProbeHook(address(market));
        address[] memory hooks = new address[](1);
        hooks[0] = address(hook);
        ITMPCore.TaskTerms memory t;
        t.version = 2;
        ITMPCore.TaskEvaluatorConfig memory none;
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(
                projects.createProjectTask,
                (
                    projectId,
                    taskConfig(REWARD, 7 days, TMP_CLAIM),
                    ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                    ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                    none,
                    t,
                    address(0)
                )
            )
        );
        assertEq(hook.createProjectId(), projectId, "beforeCreate sees the project");
        assertEq(hook.observedCreates(), 1, "the observer sees the creation");
    }

    function test_SetTaskLimits_RefusesBelowTheV2DefaultHooks() public {
        address[] memory defaults = new address[](2);
        defaults[0] = address(new MockTaskHookV2(address(market), uint32(1) << 25));
        defaults[1] = address(new MockTaskHookV2(address(market), uint32(1) << 25));
        vm.startPrank(owner);
        ITMPHooksV2(address(market)).setDefaultHooksV2(defaults);
        vm.expectRevert(ITMPCore.InvalidTaskLimits.selector);
        market.setTaskLimits(10, 1);
        market.setTaskLimits(10, 2);
        vm.stopPrank();
    }

    function test_SetDefaultHooksV2_RefusesMoreThanMaxHooks() public {
        vm.startPrank(owner);
        market.setTaskLimits(10, 1);
        address[] memory defaults = new address[](2);
        defaults[0] = address(new MockTaskHookV2(address(market), uint32(1) << 25));
        defaults[1] = address(new MockTaskHookV2(address(market), uint32(1) << 25));
        vm.expectRevert(ITMPHooksV2.TooManyDefaultHooks.selector);
        ITMPHooksV2(address(market)).setDefaultHooksV2(defaults);
        vm.stopPrank();
    }
}
