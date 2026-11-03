// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHookV2 } from "../src/interfaces/ITMPHookV2.sol";
import { TMP_CLAIM, TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { RewardVault } from "../src/hooks/RewardVault.sol";
import { EpochBudget } from "../src/hooks/EpochBudget.sol";
import { TaskTokenRewardHook } from "../src/hooks/TaskTokenRewardHook.sol";
import { TaskTokenRewardHookV2 } from "../src/hooks/TaskTokenRewardHookV2.sol";
import { PayoutGateHook } from "../src/hooks/payout-gate/PayoutGateHook.sol";
import { DeployRewardHookProxy } from "../script/lib/DeployRewardHookProxy.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev Parity of TaskTokenRewardHookV2 (rev028) with the V1 reward hook on the same diamond: a task
///      created before the cut with the V1 hook and one after it with the V2 hook earn the same
///      bonus through the same lifecycle.
contract TaskTokenRewardHookV2Test is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockUSDC internal dreams;
    MockPGTRForwarder internal forwarder;
    TaskTokenRewardHook internal hook1;
    TaskTokenRewardHookV2 internal hook2;

    address internal owner = address(0xA0);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    uint256 internal constant REWARD = 100e6;
    bytes32 internal constant WORK = keccak256("work");

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        dreams = new MockUSDC();
        market = deployDiamond(owner, address(usdc), address(0xFEE), 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));

        (RewardVault v1, EpochBudget b1) = _deps();
        hook1 = DeployRewardHookProxy.deploy(
            address(v1), address(b1), address(market), 18, 1e18, 1000, address(dreams), 8000, address(0xBEEF), owner
        );
        v1.setHook(address(hook1));
        b1.setHook(address(hook1));
        hook1.setRamp(
            [uint40(1), uint40(2), uint40(3)], [uint16(10_000), uint16(10_000), uint16(10_000), uint16(10_000)]
        );

        (RewardVault v2, EpochBudget b2) = _deps();
        bytes memory init = abi.encodeCall(
            TaskTokenRewardHookV2.initialize,
            (address(v2), address(b2), address(market), 18, 1e18, 1000, address(dreams), 8000, address(0xBEEF), owner)
        );
        hook2 = TaskTokenRewardHookV2(address(new ERC1967Proxy(address(new TaskTokenRewardHookV2()), init)));
        v2.setHook(address(hook2));
        b2.setHook(address(hook2));
        hook2.setRamp(
            [uint40(1), uint40(2), uint40(3)], [uint16(10_000), uint16(10_000), uint16(10_000), uint16(10_000)]
        );
        vm.stopPrank();
        usdc.mint(address(forwarder), 10_000e6);
    }

    function _deps() internal returns (RewardVault vault, EpochBudget budget) {
        vault = new RewardVault(address(dreams), owner);
        budget = new EpochBudget(7 days, 1_000_000e6, 100_000e6, 100_000e6, 10_000e6, owner);
        dreams.mint(owner, 100_000e18);
        dreams.transfer(address(vault), 100_000e18);
    }

    function _relay(address sender, uint256 amount, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, amount, data);
    }

    function _create(bytes4 mode, address[] memory hooks, bytes memory data) internal returns (bytes32) {
        return abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        taskConfig(REWARD, 3 days, mode),
                        ITMPCore.HookConfig({ contracts: hooks, data: data }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        noEvaluatorConfig(),
                        stakeTerms(false, 0)
                    )
                )
            ),
            (bytes32)
        );
    }

    function _one(address h) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = h;
    }

    function _runClaim(address hook) internal returns (bytes32 taskId) {
        taskId = _create(TMP_CLAIM, _one(hook), "");
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));
    }

    function test_DeclaresV2() public view {
        assertTrue(hook2.supportsInterface(type(ITMPHookV2).interfaceId));
        assertEq(hook2.hookCapabilities(), hook2.CAPABILITIES());
        assertEq(hook2.minDiamondVersion(), 28);
    }

    function test_V1HookRetiredAfterCut() public {
        bytes memory create = abi.encodeCall(
            market.createTask,
            (
                taskConfig(REWARD, 3 days, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: _one(address(hook1)), data: "" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                stakeTerms(false, 0)
            )
        );
        vm.expectRevert();
        _relay(requester, REWARD, create);
    }

    function test_ParityClaimTask() public {
        placeAtVersion(address(market), 27);
        _runClaim(address(hook1));
        placeAtVersion(address(market), 28);
        _runClaim(address(hook2));
        assertGt(hook1.claimable(worker), 0, "v1 paid a bonus");
        assertEq(hook2.claimable(worker), hook1.claimable(worker), "worker bonus");
        assertEq(hook2.claimable(requester), hook1.claimable(requester), "requester bonus");
    }

    function test_ParityBounty() public {
        placeAtVersion(address(market), 27);
        bytes32 a = _create(TMP_BOUNTY, _one(address(hook1)), "");
        _relay(worker, 0, abi.encodeCall(market.submitWork, (a, WORK)));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (a, worker, WORK, 0)));
        placeAtVersion(address(market), 28);
        bytes32 b = _create(TMP_BOUNTY, _one(address(hook2)), "");
        _relay(worker, 0, abi.encodeCall(market.submitWork, (b, WORK)));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (b, worker, WORK, 0)));
        assertEq(hook2.claimable(worker), hook1.claimable(worker), "worker bonus");
    }

    function test_ParityCancelReleasesReserve() public {
        placeAtVersion(address(market), 27);
        bytes32 a = _create(TMP_CLAIM, _one(address(hook1)), "");
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (a, 0)));
        placeAtVersion(address(market), 28);
        bytes32 b = _create(TMP_CLAIM, _one(address(hook2)), "");
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (b, 0)));
        assertEq(hook2.claimable(worker), 0);
        assertEq(hook1.claimable(worker), 0);
    }

    function test_ComposesWithPayoutGate() public {
        PayoutGateHook gate = new PayoutGateHook(address(market));
        address[] memory hooks = new address[](2);
        hooks[0] = address(hook2);
        hooks[1] = address(gate);
        bytes[] memory configs = new bytes[](2);
        configs[1] = abi.encode(bytes32(0), uint64(block.timestamp + 1 hours), new bytes32[](0));
        bytes32 taskId = _create(TMP_CLAIM, hooks, abi.encode(configs));
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        bytes memory accept = abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0));
        vm.expectRevert();
        _relay(requester, 0, accept);
        assertEq(hook2.claimable(worker), 0, "no bonus while gated");
        vm.warp(block.timestamp + 1 hours);
        _relay(requester, 0, accept);
        assertGt(hook2.claimable(worker), 0, "bonus paid with the payout");
    }
}
