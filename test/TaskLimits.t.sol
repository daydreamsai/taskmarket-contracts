// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPTerms } from "../src/interfaces/ITMPTerms.sol";
import { TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { MockTaskHook } from "./mocks/MockTaskHook.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev rev025 per-chain limits on tags and hooks per task.
contract TaskLimitsTest is Test, DiamondTestHelper {
    uint256 internal constant REWARD = 100e6;
    uint256 internal constant DURATION = 7 days;

    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;
    address internal owner = makeAddr("owner");
    address internal requester = makeAddr("requester");
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 100_000e6);
    }

    function _tags(uint256 n) internal pure returns (bytes32[] memory t) {
        t = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            t[i] = keccak256(abi.encode(i));
        }
    }

    function _hookList(uint256 n) internal returns (address[] memory h) {
        h = new address[](n);
        for (uint256 i; i < n; ++i) {
            h[i] = address(new MockTaskHook());
        }
    }

    function _data(uint256 tagCount, address[] memory hooks) internal pure returns (bytes memory) {
        ITMPCore.TaskTerms memory terms;
        return abi.encodeCall(
            ITMPTerms.createTask,
            (
                taskConfig(REWARD, DURATION, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: _tags(tagCount) }),
                noEvaluatorConfig(),
                terms
            )
        );
    }

    function _create(uint256 tagCount, address[] memory hooks) internal {
        forwarder.relay(address(market), requester, REWARD, _data(tagCount, hooks));
    }

    function _expectCreateRevert(uint256 tagCount, address[] memory hooks, bytes4 err) internal {
        bytes memory data = _data(tagCount, hooks);
        vm.expectRevert(err);
        forwarder.relay(address(market), requester, REWARD, data);
    }

    function test_TaskLimits_DefaultsWhileStorageZero() public view {
        (uint256 maxTags, uint256 maxHooks) = market.taskLimits();
        assertEq(maxTags, 10, "default max tags");
        assertEq(maxHooks, 8, "default max hooks");
    }

    function test_Create_DefaultBoundariesPass() public {
        _create(10, _hookList(8));
    }

    function test_Create_RevertsAtElevenTags() public {
        _expectCreateRevert(11, new address[](0), ITMPCore.TooManyTags.selector);
    }

    function test_Create_RevertsAtNineHooks() public {
        _expectCreateRevert(0, _hookList(9), ITMPCore.TooManyHooks.selector);
    }

    function test_Create_DefaultHooksCountTowardsLimit() public {
        address[] memory defaults = _hookList(2);
        vm.prank(owner);
        market.setDefaultHooks(defaults);
        _create(0, _hookList(6));
        _expectCreateRevert(0, _hookList(7), ITMPCore.TooManyHooks.selector);
    }

    function test_SetTaskLimits_OwnerChangesLimits() public {
        vm.expectEmit(false, false, false, true, address(market));
        emit ITMPCore.TaskLimitsUpdated(3, 2);
        vm.prank(owner);
        market.setTaskLimits(3, 2);
        (uint256 maxTags, uint256 maxHooks) = market.taskLimits();
        assertEq(maxTags, 3, "max tags");
        assertEq(maxHooks, 2, "max hooks");

        _create(3, _hookList(2));
        _expectCreateRevert(4, new address[](0), ITMPCore.TooManyTags.selector);
        _expectCreateRevert(0, _hookList(3), ITMPCore.TooManyHooks.selector);

        vm.prank(owner);
        market.setTaskLimits(20, 12);
        _create(20, _hookList(12));
    }

    function test_SetDefaultHooks_UsesConfiguredLimit() public {
        vm.prank(owner);
        market.setTaskLimits(10, 2);
        address[] memory three = _hookList(3);
        vm.prank(owner);
        vm.expectRevert(ITMPCore.TooManyHooks.selector);
        market.setDefaultHooks(three);
    }

    function test_SetTaskLimits_NonOwnerRefused() public {
        vm.prank(requester);
        vm.expectRevert();
        market.setTaskLimits(5, 5);
    }

    function test_SetTaskLimits_RejectsInvalid() public {
        address[] memory defaults = _hookList(3);
        vm.startPrank(owner);
        market.setDefaultHooks(defaults);
        vm.expectRevert(ITMPCore.InvalidTaskLimits.selector);
        market.setTaskLimits(0, 8);
        vm.expectRevert(ITMPCore.InvalidTaskLimits.selector);
        market.setTaskLimits(65, 8);
        vm.expectRevert(ITMPCore.InvalidTaskLimits.selector);
        market.setTaskLimits(10, 0);
        vm.expectRevert(ITMPCore.InvalidTaskLimits.selector);
        market.setTaskLimits(10, 17);
        vm.expectRevert(ITMPCore.InvalidTaskLimits.selector);
        market.setTaskLimits(10, 2);
        market.setTaskLimits(64, 16);
        market.setTaskLimits(1, 3);
        vm.stopPrank();
    }
}
