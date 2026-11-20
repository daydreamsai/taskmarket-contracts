// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { BaseTMPHookV2 } from "../src/hooks/base/BaseTMPHookV2.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { MockTaskHookV2 } from "./mocks/MockTaskHookV2.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev An afterComplete hook that records the call and burns a set amount of gas.
contract BurnAfterCompleteHook is BaseTMPHookV2 {
    uint256 public immutable burn;
    uint256 public calls;

    constructor(address diamond_, uint256 burn_) BaseTMPHookV2(diamond_) {
        burn = burn_;
    }

    function hookCapabilities() external pure override returns (uint32) {
        return uint32(1) << 21;
    }

    function afterComplete(bytes32, TaskContextV2 calldata, SettlementAmounts calldata, uint64)
        external
        override
        onlyDiamond
    {
        calls++;
        uint256 stop = gasleft() - burn;
        while (gasleft() > stop) { }
    }
}

/// @dev rev031: a strict after-callback (accept, cancel, a forfeit) runs or the action reverts. It
///      is never skipped for gas, including at the lowest gas limit at which the action succeeds,
///      and the forced-exit spend cap does not apply to it.
contract StrictHookGasTest is DiamondTestHelper {
    ITMPDiamond internal market;
    ITMPHooksV2 internal v2;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(0xA0);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);

    uint256 internal constant REWARD = 100e6;
    uint256 internal constant DURATION = 7 days;
    bytes32 internal constant WORK = keccak256("work");
    uint32 internal constant BIT_AFTER_COMPLETE = uint32(1) << 21;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), address(0xFEE), 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        v2 = ITMPHooksV2(address(market));
        usdc.mint(address(forwarder), 10_000_000e6);
    }

    function _create(address[] memory hooks) internal returns (bytes32) {
        bytes memory ret = forwarder.relay(
            address(market),
            requester,
            REWARD,
            abi.encodeCall(
                market.createTask,
                (
                    taskConfig(REWARD, DURATION, TMP_CLAIM),
                    ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                    ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                    noEvaluatorConfig(),
                    stakeTerms(false, 0)
                )
            )
        );
        return abi.decode(ret, (bytes32));
    }

    function _submitted(address[] memory hooks) internal returns (bytes32 taskId) {
        taskId = _create(hooks);
        forwarder.relay(address(market), worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        forwarder.relay(address(market), worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
    }

    function _try(address sender, bytes memory data, uint256 gasLimit) internal returns (bool ok) {
        (ok,) = address(forwarder).call{ gas: gasLimit }(
            abi.encodeCall(MockPGTRForwarder.relay, (address(market), sender, 0, data))
        );
    }

    /// @dev What eth_estimateGas finds: the lowest limit at which the call succeeds. Leaves the
    ///      state as it was.
    function _lowest(address sender, bytes memory data) internal returns (uint256 lo) {
        uint256 hi = 30_000_000;
        lo = 100_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            bool ok = _try(sender, data, mid);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid + 1;
        }
    }

    function _one(address h) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = h;
    }

    function test_AcceptAtLowestSucceedingGasRunsAfterComplete() public {
        MockTaskHookV2 h = new MockTaskHookV2(address(market), BIT_AFTER_COMPLETE);
        bytes32 taskId = _submitted(_one(address(h)));
        bytes memory accept = abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0));
        uint256 g = _lowest(requester, accept);
        assertTrue(_try(requester, accept, g), "the accept succeeds at the estimate");
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
        assertEq(h.lastTerminalKind(), 1, "afterComplete ran rather than being skipped");
    }

    function test_StrictAfterCallbacksAreNotCappedLikeAnExit() public {
        // Two hooks with 4M budgets that each spend about 3.5M: together past the 6M forced-exit
        // cap, which applies to exits only.
        vm.prank(owner);
        v2.setHookCapabilityGas(21, 4_000_000);
        BurnAfterCompleteHook h0 = new BurnAfterCompleteHook(address(market), 3_500_000);
        BurnAfterCompleteHook h1 = new BurnAfterCompleteHook(address(market), 3_500_000);
        address[] memory hooks = new address[](2);
        hooks[0] = address(h0);
        hooks[1] = address(h1);
        bytes32 taskId = _submitted(hooks);
        forwarder.relay{ gas: 20_000_000 }(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0))
        );
        assertEq(h0.calls(), 1, "first afterComplete ran");
        assertEq(h1.calls(), 1, "second afterComplete ran");
    }
}
