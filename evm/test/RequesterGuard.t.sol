// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";

/// @dev Every requester entrypoint refuses a caller who is not the task's requester with
///      NotRequester, through a trusted forwarder, and refuses a direct call before that.
contract RequesterGuardTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal admin = address(0xA0);
    address internal requester = address(0xB0);
    address internal stranger = address(0xC1);
    address internal worker = address(0xC0);

    uint256 internal constant REWARD = 10e6;

    bytes32 internal taskId;

    function setUp() public {
        vm.startPrank(admin);
        usdc = new MockUSDC();
        market = deployDiamond(admin, address(usdc), address(0xFEE), 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 1_000e6);

        taskId = abi.decode(
            forwarder.relay(
                address(market),
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
    }

    /// @dev One call per requester entrypoint, each against the Open bounty created in setUp.
    function _calls() internal view returns (bytes[] memory calls) {
        calls = new bytes[](11);
        calls[0] = abi.encodeCall(market.updateTask, (taskId, 0, block.timestamp + 30 days, 0, 0));
        calls[1] = abi.encodeCall(market.cancelTask, (taskId, 0));
        calls[2] = abi.encodeCall(market.rejectSubmission, (taskId, worker));
        calls[3] = abi.encodeCall(market.forfeitAndReopen, (taskId));
        calls[4] = abi.encodeCall(market.rejectDelivery, (taskId));
        calls[5] = abi.encodeCall(market.requestRevision, (taskId));
        calls[6] = abi.encodeCall(market.acceptSubmission, (taskId, worker, bytes32(0), 0));
        calls[7] = abi.encodeCall(
            market.acceptSubmissions, (taskId, new address[](1), new uint16[](1), new bytes32[](1), 0)
        );
        calls[8] = abi.encodeCall(market.assignEvaluator, (taskId, address(0xE0), 0, 0, 3 days, 2 days, address(0xD0)));
        calls[9] = abi.encodeCall(market.selectWorker, (taskId, worker));
        calls[10] = abi.encodeCall(market.rateTask, (taskId, worker, 50, 0, 0, "", bytes32(0)));
    }

    function test_RevertWhen_NotRequester_ThroughTheForwarder() public {
        bytes[] memory calls = _calls();
        for (uint256 i; i < calls.length; ++i) {
            vm.expectRevert(ITMPCore.NotRequester.selector);
            forwarder.relay(address(market), stranger, 0, calls[i]);
        }
    }

    function test_RevertWhen_NotRequester_DirectCall() public {
        bytes[] memory calls = _calls();
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(stranger);
            vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
            (bool ok,) = address(market).call(calls[i]);
            ok;
        }
    }

    function test_RequesterPassesTheGuard() public {
        // The requester gets past the guard: the same calls revert, but not with NotRequester.
        bytes[] memory calls = _calls();
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(address(forwarder));
            (bool ok, bytes memory ret) = address(forwarder)
                .call(abi.encodeCall(MockPGTRForwarder.relay, (address(market), requester, 0, calls[i])));
            if (!ok && ret.length >= 4) {
                bytes4 sel;
                assembly {
                    sel := mload(add(ret, 32))
                }
                assertTrue(sel != ITMPCore.NotRequester.selector, "requester refused by the guard");
            }
        }
    }
}
