// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { MockTaskHookV2 } from "./mocks/MockTaskHookV2.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev rev031 (Cyclops 7649): setDefaultHooksV2 refuses a default list that would revert every
///      task creation, and still accepts a transforming default.
contract Rev031DefaultHooksTest is DiamondTestHelper {
    ITMPDiamond internal market;
    ITMPHooksV2 internal v2;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(0xA0);
    address internal requester = address(0xB0);
    address internal evaluator = address(0xE0);
    address internal resolver = address(0xD0);

    uint256 internal constant REWARD = 100e6;

    uint32 internal constant BIT_APPEAL = uint32(1) << 12;
    uint32 internal constant BIT_ACCEPT = uint32(1) << 13;
    uint32 internal constant BIT_OBSERVER = uint32(1) << 25;
    uint32 internal constant BIT_REALLOCATE = uint32(1) << 26;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), address(0xFEE), 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        v2 = ITMPHooksV2(address(market));
        usdc.mint(address(forwarder), 100_000e6);
    }

    function _hook(uint32 caps) internal returns (address) {
        return address(new MockTaskHookV2(address(market), caps));
    }

    function _two(address h0, address h1) internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = h0;
        a[1] = h1;
    }

    function _one(address h) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = h;
    }

    function _setDefaults(address[] memory hooks) internal {
        vm.prank(owner);
        v2.setDefaultHooksV2(hooks);
    }

    function _create(address disputeResolver, bool withEvaluator) internal returns (bytes memory) {
        return forwarder.relay(address(market), requester, REWARD, _createCall(disputeResolver, withEvaluator));
    }

    function _createCall(address disputeResolver, bool withEvaluator) internal view returns (bytes memory) {
        ITMPCore.TaskEvaluatorConfig memory cfg;
        if (withEvaluator) {
            cfg = ITMPCore.TaskEvaluatorConfig({
                evaluator: evaluator,
                evaluatorStake: 0,
                evaluatorFeeBps: 0,
                evaluationWindow: uint32(2 days),
                appealWindow: uint32(1 days),
                disputeResolver: disputeResolver
            });
        }
        return abi.encodeCall(
            market.createTask,
            (
                taskConfig(REWARD, 7 days, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                cfg,
                stakeTerms(false, 0)
            )
        );
    }

    function test_SetDefaults_RefusesTransformerNextToAppealHook() public {
        address[] memory hooks = _two(_hook(BIT_ACCEPT | BIT_REALLOCATE), _hook(BIT_APPEAL));
        vm.prank(owner);
        vm.expectRevert(ITMPHooksV2.TransformingHookWithAppealHook.selector);
        v2.setDefaultHooksV2(hooks);

        // The same pair in the other order.
        hooks = _two(hooks[1], hooks[0]);
        vm.prank(owner);
        vm.expectRevert(ITMPHooksV2.TransformingHookWithAppealHook.selector);
        v2.setDefaultHooksV2(hooks);
        assertEq(v2.getDefaultHooksV2().length, 0, "no defaults set");
    }

    function test_SetDefaults_RefusesTransformerDeclaringAppeal() public {
        address[] memory hooks = _one(_hook(BIT_ACCEPT | BIT_REALLOCATE | BIT_APPEAL));
        vm.prank(owner);
        vm.expectRevert(ITMPHooksV2.TransformingHookWithAppealHook.selector);
        v2.setDefaultHooksV2(hooks);
    }

    /// A transforming default is allowed: tasks are still created, and an evaluator task names a
    /// dispute resolver, as it would with a requester-attached transformer.
    function test_SetDefaults_AllowsTransformingDefault() public {
        _setDefaults(_two(_hook(BIT_ACCEPT | BIT_REALLOCATE), _hook(BIT_OBSERVER)));
        assertEq(v2.getDefaultHooksV2().length, 2);
        assertTrue(v2.getDefaultHooksV2()[0].transforming);

        _create(address(0), false);
        _create(resolver, true);
        bytes memory data = _createCall(address(0), true);
        vm.expectRevert(ITMPHooksV2.TransformingHookNeedsDisputeResolver.selector);
        forwarder.relay(address(market), requester, REWARD, data);
    }

    function test_SetDefaults_AllowsAppealHookWithoutTransformer() public {
        _setDefaults(_two(_hook(BIT_APPEAL), _hook(BIT_OBSERVER)));
        assertEq(v2.getDefaultHooksV2().length, 2);
        _create(address(0), false);
    }
}
