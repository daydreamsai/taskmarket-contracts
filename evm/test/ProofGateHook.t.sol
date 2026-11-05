// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { ITMPHookV2 } from "../src/interfaces/ITMPHookV2.sol";
import { LibAppStorage, AppStorage } from "../src/libraries/LibAppStorage.sol";
import { LibHooksV2 } from "../src/libraries/LibHooksV2.sol";
import { ProofGateHook } from "../src/hooks/proof-gate/ProofGateHook.sol";
import { BaseTMPHookV2 } from "../src/hooks/base/BaseTMPHookV2.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";

/// @dev Reads the position of taskHookVersion in AppStorage so a test can zero one task's entry.
contract HookVersionSlot {
    function baseSlot() external view returns (uint256 slot) {
        AppStorage storage s = LibAppStorage.appStorage();
        mapping(bytes32 => uint8) storage m = s.taskHookVersion;
        assembly {
            slot := m.slot
        }
    }
}

contract ProofGateHookTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;
    ProofGateHook internal gate;
    bytes4 internal benchmark;

    address internal owner = address(1);
    address internal feeRecipient = address(2);
    address internal requester = address(3);
    address internal allowedWorker = address(4);
    address internal otherWorker = address(5);

    uint256 internal constant REWARD = 100 * 10 ** 6;
    uint256 internal constant DURATION = 7 days;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 10_000 * 10 ** 6);
        gate = new ProofGateHook(address(market));
        benchmark = market.BENCHMARK();
    }

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _create(bytes memory allowedConfig) internal returns (bytes32) {
        address[] memory hooks = new address[](1);
        hooks[0] = address(gate);
        bytes[] memory configs = new bytes[](1);
        configs[0] = allowedConfig;
        return abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        taskConfig(REWARD, DURATION, benchmark),
                        ITMPCore.HookConfig({ contracts: hooks, data: abi.encode(configs) }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        noEvaluatorConfig(),
                        stakeTerms(false, 0)
                    )
                )
            ),
            (bytes32)
        );
    }

    function _createGated() internal returns (bytes32) {
        address[] memory allowed = new address[](1);
        allowed[0] = allowedWorker;
        return _create(abi.encode(allowed));
    }

    function _submitProof(bytes32 taskId, address worker, bytes32 proofHash) internal {
        _relay(worker, 0, abi.encodeCall(market.submitProof, (taskId, proofHash, keccak256("eval"), 9500)));
    }

    /// @dev The diamond wraps the hook's own revert data in HookRejected(index, action, reason).
    function _expectBlocked(address worker) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                ITMPHooksV2.HookRejected.selector,
                uint8(0),
                LibHooksV2.A_SUBMIT_PROOF,
                abi.encodeWithSelector(ProofGateHook.ProofGate__WorkerNotAllowed.selector, worker)
            )
        );
    }

    function _hasProof(bytes32 taskId) internal view returns (bool) {
        try market.taskProofHashes(taskId, 0) returns (bytes32) {
            return true;
        } catch {
            return false;
        }
    }

    function test_ProofGate_blocksBenchmarkProofFromWorkerNotOnAllowlist() public {
        bytes32 taskId = _createGated();
        assertEq(ITMPHooksV2(address(market)).getTaskHookVersion(taskId), LibHooksV2.VERSION_V2);

        uint256 marketBefore = usdc.balanceOf(address(market));
        uint256 workerBefore = usdc.balanceOf(otherWorker);

        _expectBlocked(otherWorker);
        _submitProof(taskId, otherWorker, keccak256("proof"));

        assertFalse(_hasProof(taskId), "proof recorded");
        assertEq(usdc.balanceOf(address(market)), marketBefore, "escrow moved");
        assertEq(usdc.balanceOf(otherWorker), workerBefore, "worker paid");
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Open));
    }

    function test_ProofGate_passesBenchmarkProofFromAllowlistedWorker() public {
        bytes32 taskId = _createGated();
        bytes32 proofHash = keccak256("proof");

        vm.expectEmit(true, true, false, true);
        emit ITMPCore.ProofSubmitted(taskId, allowedWorker, proofHash, keccak256("eval"), 9500);
        _submitProof(taskId, allowedWorker, proofHash);

        assertEq(market.taskProofHashes(taskId, 0), proofHash);
        assertTrue(gate.isAllowed(taskId, allowedWorker));
        assertFalse(gate.isAllowed(taskId, otherWorker));
    }

    function test_ProofGate_rejectionDoesNotBlockAllowlistedWorkerAfterwards() public {
        bytes32 taskId = _createGated();
        _expectBlocked(otherWorker);
        _submitProof(taskId, otherWorker, keccak256("blocked"));
        _submitProof(taskId, allowedWorker, keccak256("ok"));
        assertEq(market.taskProofHashes(taskId, 0), keccak256("ok"));
    }

    function test_ProofGate_v1TaskKeepsSubmitProofUngated() public {
        bytes32 taskId = _createGated();

        // A task created before the cut reads version zero and dispatches V1, which has no
        // submitProof check; zero this one task's entry to stand in for it.
        uint256 base = new HookVersionSlot().baseSlot();
        vm.store(address(market), keccak256(abi.encode(taskId, base)), bytes32(0));
        assertEq(ITMPHooksV2(address(market)).getTaskHookVersion(taskId), 0);

        _submitProof(taskId, otherWorker, keccak256("proof"));
        assertEq(market.taskProofHashes(taskId, 0), keccak256("proof"));
    }

    function test_ProofGate_emptyConfigStartsClosedAndRequesterCanAllow() public {
        bytes32 taskId = _create("");

        _expectBlocked(allowedWorker);
        _submitProof(taskId, allowedWorker, keccak256("early"));

        vm.prank(otherWorker);
        vm.expectRevert(ProofGateHook.ProofGate__NotRequester.selector);
        gate.allow(taskId, otherWorker);

        vm.prank(requester);
        gate.allow(taskId, allowedWorker);
        _submitProof(taskId, allowedWorker, keccak256("late"));
        assertEq(market.taskProofHashes(taskId, 0), keccak256("late"));
    }

    function test_ProofGate_callbackOnlyFromDiamond() public {
        bytes32 taskId = _createGated();
        ITMPHookV2.TaskContextV2 memory ctx;
        vm.expectRevert(abi.encodeWithSelector(BaseTMPHookV2.BaseTMPHookV2__UnauthorizedCaller.selector, address(this)));
        gate.beforeSubmitProof(taskId, ctx, otherWorker, bytes32(0), "");
    }
}
