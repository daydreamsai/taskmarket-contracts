// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { TMP_CLAIM, TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { BaseTMPHookV2 } from "../src/hooks/base/BaseTMPHookV2.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev A V2 hook that burns the whole budget it is given, on every callback it declares, once armed.
contract BurnerHookV2 is BaseTMPHookV2 {
    uint256 public sink;
    bool public armed;
    uint32 public immutable caps;

    constructor(address diamond_, uint32 caps_) BaseTMPHookV2(diamond_) {
        caps = caps_;
    }

    function arm() external {
        armed = true;
    }

    function hookCapabilities() external view override returns (uint32) {
        return caps;
    }

    function _burn() internal {
        if (!armed) return;
        for (uint256 i; i < type(uint256).max; ++i) {
            sink = i;
        }
    }

    function afterAction(bytes32, TaskContextV2 calldata, uint8, bytes calldata, uint64) external override {
        _burn();
    }

    function beforeAccept(bytes32, TaskContextV2 calldata, ITMPCore.Verdict calldata, bytes calldata)
        external
        override
        returns (bytes4, SettlementDelta memory, ITMPCore.Award[] memory)
    {
        _burn();
        return _allowAccept();
    }

    function afterComplete(bytes32, TaskContextV2 calldata, SettlementAmounts calldata, uint64) external override {
        _burn();
    }
}

/// @dev rev030: hooks never block delivery (observers) or a forced exit's settlement, however much
///      gas they burn, and the gas hooks may spend on an exit is capped.
contract Rev030HookGasTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    address internal evaluator = address(0xE0);
    address internal resolver = address(0xD0);

    uint256 internal constant REWARD = 100e6;
    uint256 internal constant DURATION = 7 days;
    uint256 internal constant TEMPO_STIPEND = 7_000_000;
    uint256 internal constant TX_CAP = 30_000_000;
    bytes32 internal constant WORK = keccak256("work");
    uint32 internal constant OBSERVER = uint32(1) << 25;
    uint32 internal constant ACCEPT_AND_AFTER = (uint32(1) << 13) | (uint32(1) << 21);

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        market.setHookGasStipend(TEMPO_STIPEND);
        vm.stopPrank();
        usdc.mint(address(forwarder), 100_000e6);
    }

    function _relay(address sender, uint256 payment, bytes memory data) internal {
        forwarder.relay{ gas: TX_CAP }(address(market), sender, payment, data);
    }

    function _burners(uint256 n, uint32 caps) internal returns (address[] memory hooks) {
        hooks = new address[](n);
        for (uint256 i; i < n; ++i) {
            hooks[i] = address(new BurnerHookV2(address(market), caps));
        }
    }

    function _arm(address[] memory hooks) internal {
        for (uint256 i; i < hooks.length; ++i) {
            BurnerHookV2(hooks[i]).arm();
        }
    }

    function _cfg(address disputeResolver) internal view returns (ITMPCore.TaskEvaluatorConfig memory) {
        return ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: 0,
            evaluatorFeeBps: 0,
            evaluationWindow: uint32(2 days),
            appealWindow: uint32(1 days),
            disputeResolver: disputeResolver
        });
    }

    function _create(bytes4 mode, address[] memory hooks, ITMPCore.TaskEvaluatorConfig memory cfg)
        internal
        returns (bytes32 id)
    {
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                taskConfig(REWARD, DURATION, mode),
                ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                cfg,
                stakeTerms(false, 0)
            )
        );
        id = abi.decode(forwarder.relay(address(market), requester, REWARD, data), (bytes32));
    }

    function _award(address w, uint256 amount) internal pure returns (ITMPCore.Award[] memory a) {
        a = new ITMPCore.Award[](1);
        a[0] = ITMPCore.Award({ worker: w, amount: amount, rank: 1 });
    }

    // -------------------------------------------------------------------------
    // Watch-only hooks never block delivery
    // -------------------------------------------------------------------------

    function test_SubmitWork_NotBlockedByBurningObservers() public {
        address[] memory hooks = _burners(5, OBSERVER);
        bytes32 id = _create(TMP_CLAIM, hooks, _cfg(address(0)));
        _relay(worker, 0, abi.encodeCall(market.claimTask, (id, 0)));
        _arm(hooks);

        vm.recordLogs();
        _relay(worker, 0, abi.encodeCall(market.submitWork, (id, WORK)));

        assertEq(market.getTask(id).deliverable, WORK, "delivery went through");
        uint256 skipped;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ITMPHooksV2.HookCallFailedV2.selector) ++skipped;
        }
        assertGt(skipped, 0, "at least one observer was skipped for gas");
        for (uint256 i; i < hooks.length; ++i) {
            assertGt(ITMPHooksV2(address(market)).hookCallSeq(id, uint8(i)), 0, "every hook's seq advanced");
        }
    }

    // -------------------------------------------------------------------------
    // Total hook gas cap on forced exits
    // -------------------------------------------------------------------------

    function test_ResolveDispute_CompletesUnderTheTxCapWithBurningHooks() public {
        address[] memory hooks = _burners(6, ACCEPT_AND_AFTER);
        bytes32 id = _create(TMP_CLAIM, hooks, _cfg(resolver));
        _relay(worker, 0, abi.encodeCall(market.claimTask, (id, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (id, WORK)));
        _relay(
            evaluator,
            0,
            abi.encodeCall(
                market.evaluate, (id, ITMPCore.VerdictType.REJECT, 100, 1000, bytes32(0), new ITMPCore.Award[](0))
            )
        );
        _relay(worker, 0, abi.encodeCall(market.appeal, (id)));
        _arm(hooks);

        vm.prank(resolver);
        uint256 g = gasleft();
        market.resolveDispute{ gas: TX_CAP }(id, ITMPCore.VerdictType.APPROVE, _award(worker, REWARD));
        uint256 used = g - gasleft();

        assertEq(uint8(market.getTaskState(id)), uint8(ITMPCore.TaskStatus.Accepted), "settled");
        assertGt(usdc.balanceOf(worker), 0, "worker paid");
        assertLt(used, TX_CAP, "under the cap");
    }

    function test_FinalizeVerdict_ThirtyWinnersAfterExpiry_CompletesUnderTheTxCap() public {
        address[] memory hooks = _burners(6, ACCEPT_AND_AFTER);
        bytes32 id = _create(TMP_BOUNTY, hooks, _cfg(resolver));
        uint256 n = 30;
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](n);
        for (uint256 i; i < n; ++i) {
            address w = address(uint160(0xC100 + i));
            _relay(w, 0, abi.encodeCall(market.submitWork, (id, WORK)));
            awards[i] = ITMPCore.Award({ worker: w, amount: 3e6, rank: uint16(i + 1) });
        }
        _relay(
            evaluator,
            0,
            abi.encodeCall(market.evaluate, (id, ITMPCore.VerdictType.APPROVE, 900, 1000, bytes32(0), awards))
        );
        _arm(hooks);
        vm.warp(market.getTask(id).expiryTime + 1);

        uint256 g = gasleft();
        market.finalizeVerdict{ gas: TX_CAP }(id);
        uint256 used = g - gasleft();

        assertEq(uint8(market.getTaskState(id)), uint8(ITMPCore.TaskStatus.Accepted), "settled");
        assertGt(usdc.balanceOf(address(uint160(0xC100))), 0, "winner paid");
        assertLt(used, TX_CAP, "under the cap");
    }
}
