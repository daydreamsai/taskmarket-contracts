// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHookV2 } from "../src/interfaces/ITMPHookV2.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { TMP_BOUNTY, TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { ITMPTerms } from "../src/interfaces/ITMPTerms.sol";
import { ITMPReservation } from "../src/interfaces/ITMPReservation.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { SponsoredTaskTypes } from "../src/hooks/sponsored-task/SponsoredTaskTypes.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTaskFactoryV2 } from "../src/hooks/sponsored-task/SponsoredTaskFactoryV2.sol";
import { SponsoredTasksVaultV2 } from "../src/hooks/sponsored-task/SponsoredTasksVaultV2.sol";
import { SponsoredTaskHookV2 } from "../src/hooks/sponsored-task/SponsoredTaskHookV2.sol";
import { SponsoredTaskTerms } from "../src/hooks/sponsored-task/libraries/SponsoredTaskTerms.sol";
import { PayoutGateHook } from "../src/hooks/payout-gate/PayoutGateHook.sol";
import { MockTaskHookV2 } from "./mocks/MockTaskHookV2.sol";
import { SponsoredTaskFeeConfig } from "./helpers/SponsoredTaskFeeConfig.sol";
import { MockTaskmarketForSponsoredTask } from "./mocks/MockTaskmarketForSponsoredTask.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev Mock market that also drives the V2 callbacks, so the same task state reaches both hooks.
contract MockTaskmarketV2ForSponsoredTask is MockTaskmarketForSponsoredTask {
    function ctxV2(bytes32 taskId) public view returns (ITMPHookV2.TaskContextV2 memory c) {
        ITMPCore.TaskContext memory v1 = this.getTaskContext(taskId);
        c.taskId = taskId;
        c.requester = v1.requester;
        c.paymentToken = v1.paymentToken;
        c.reward = v1.reward;
        c.mode = v1.mode;
        c.currentState = v1.currentState;
        c.priorStatus = v1.currentState;
    }

    function v2Create(ITMPHookV2 hook, bytes32 taskId, bytes calldata config) external {
        hook.beforeCreate(taskId, ctxV2(taskId), config, "");
    }

    function v2Accept(ITMPHookV2 hook, bytes32 taskId, ITMPCore.Verdict calldata verdict) external {
        hook.beforeAccept(taskId, ctxV2(taskId), verdict, "");
    }

    function v2AfterComplete(ITMPHookV2 hook, bytes32 taskId) external {
        ITMPHookV2.SettlementAmounts memory none;
        hook.afterComplete(taskId, ctxV2(taskId), none, 0);
    }

    function v2AfterCancel(ITMPHookV2 hook, bytes32 taskId) external {
        ITMPHookV2.SettlementAmounts memory none;
        hook.afterCancel(taskId, ctxV2(taskId), none, 0);
    }
}

/// @dev The V2 hook's manifest and its diamond-only entry points. Its lifecycle outcomes are covered by
///      SponsoredTaskHookV2Suite and the diamond test below.
contract SponsoredTaskHookV2Test is Test {
    bytes32 private constant TASK_ID = keccak256("task");

    SponsoredTaskHookV2 private hook2;

    function setUp() external {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6, address(this));
        SponsoredTaskRegistry registry = new SponsoredTaskRegistry(address(this));
        hook2 =
            new SponsoredTaskHookV2(address(new MockTaskmarketV2ForSponsoredTask()), IERC20(address(usdc)), registry);
    }

    function test_DeclaresOnlyItsCapabilities() external view {
        assertEq(hook2.hookCapabilities(), hook2.CAPABILITIES());
        assertEq(hook2.minDiamondVersion(), 28);
        assertTrue(hook2.supportsInterface(type(ITMPHookV2).interfaceId));
    }

    function test_OnlyDiamondCalls() external {
        ITMPHookV2.TaskContextV2 memory c;
        vm.expectRevert();
        hook2.beforeCreate(TASK_ID, c, "", "");
    }
}

/// @dev End to end on the diamond: a sponsored Bounty with the V2 hook and the payout gate.
contract SponsoredTaskHookV2DiamondTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;
    MockERC20 internal projectToken;
    SponsoredTaskHookV2 internal hook;
    SponsoredTasksVaultV2 internal vault;
    PayoutGateHook internal gate;

    address internal owner = address(0xA0);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    uint256 internal constant REWARD = 100e6;
    uint256 internal constant DURATION = 7 days;
    uint256 internal constant GROSS = 10_000;
    bytes32 internal constant WORK = keccak256("work");

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), address(0xFEE), 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 1_000_000e6);

        projectToken = new MockERC20("Project", "PROJECT", 18, address(this));
        SponsoredTaskFeePolicy feePolicy = new SponsoredTaskFeePolicy(address(this), 0, address(0xFEE1));
        SponsoredTaskRegistry registry = new SponsoredTaskRegistry(address(this));
        hook = new SponsoredTaskHookV2(address(market), IERC20(address(usdc)), registry);
        SponsoredTaskFactoryV2 factory = new SponsoredTaskFactoryV2(
            address(hook), address(feePolicy), registry, SponsoredTaskFeeConfig.none(IERC20(address(usdc)))
        );
        registry.setFactory(address(factory), true);
        (address vaultAddress,) = factory.createVault(address(projectToken), address(this), keccak256("e2e"));
        vault = SponsoredTasksVaultV2(vaultAddress);
        vault.configureManager(requester, GROSS * 100, true);
        projectToken.mint(address(this), GROSS * 100);
        projectToken.approve(address(vault), type(uint256).max);
        vault.fund(GROSS * 100);
        gate = new PayoutGateHook(address(market));
    }

    function _termsHash(address[] memory hooks) internal view returns (bytes32) {
        SponsoredTaskTerms.SettlementTerms memory settlement;
        return _termsHash(hooks, TMP_BOUNTY, settlement);
    }

    function _termsHash(address[] memory hooks, bytes4 mode, SponsoredTaskTerms.SettlementTerms memory settlement)
        internal
        view
        returns (bytes32)
    {
        SponsoredTaskTerms.Terms memory t = SponsoredTaskTerms.Terms({
            reward: REWARD,
            duration: DURATION,
            mode: mode,
            pitchDuration: 0,
            bidDuration: 0,
            auctionSubtype: bytes4(0),
            stakeRequired: false,
            stakeBps: 0,
            feeBps: 500,
            evaluator: address(0),
            evaluatorStake: 0,
            evaluatorFeeBps: 0,
            evaluationWindow: 0,
            appealWindow: 0,
            disputeResolver: address(0),
            contentHash: bytes32(0),
            contentURIHash: keccak256(bytes("")),
            tagsHash: keccak256(abi.encode(new bytes32[](0))),
            hooksHash: keccak256(abi.encode(hooks))
        });
        return keccak256(
            abi.encode(
                SponsoredTaskTerms.TERMS_HASH_TYPEHASH,
                keccak256(abi.encode(SponsoredTaskTerms.TASK_TERMS_TYPEHASH, t)),
                keccak256(abi.encode(SponsoredTaskTerms.SETTLEMENT_TERMS_TYPEHASH, settlement))
            )
        );
    }

    function test_SponsoredBountyWithGate() public {
        address[] memory hooks = new address[](2);
        hooks[0] = address(hook);
        hooks[1] = address(gate);
        bytes[] memory configs = new bytes[](2);
        configs[0] = hook.encodeHookData(
            SponsoredTaskHookV2.FundingRequest({
                route: 0,
                vault: address(vault),
                vaultId: vault.vaultId(),
                allocationId: bytes32(0),
                epoch: 1,
                feeBps: 0,
                feeRecipient: address(0xFEE1),
                grossAmount: GROSS,
                taskTermsHash: _termsHash(hooks)
            })
        );
        configs[1] = abi.encode(bytes32(0), uint64(block.timestamp + 1 days), new bytes32[](0));
        bytes32 taskId = abi.decode(
            forwarder.relay(
                address(market),
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        taskConfig(REWARD, DURATION, TMP_BOUNTY),
                        ITMPCore.HookConfig({ contracts: hooks, data: abi.encode(configs) }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        noEvaluatorConfig(),
                        stakeTerms(false, 0)
                    )
                )
            ),
            (bytes32)
        );
        (,,,,,,,, SponsoredTaskHookV2.HookStatus st) = hook.taskAllocationSettlement(taskId);
        assertEq(uint8(st), uint8(SponsoredTaskHookV2.HookStatus.Reserved), "reserved at creation");

        forwarder.relay(address(market), worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        bytes memory accept = abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0));
        vm.expectPartialRevert(ITMPHooksV2.HookRejected.selector);
        forwarder.relay(address(market), requester, 0, accept);

        vm.warp(block.timestamp + 1 days);
        forwarder.relay(address(market), requester, 0, accept);
        (,,,,,,,, st) = hook.taskAllocationSettlement(taskId);
        assertEq(uint8(st), uint8(SponsoredTaskHookV2.HookStatus.CompletionCommitted), "committed");

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: REWARD, rank: 1 });
        hook.finalizeSettlement(taskId, awards);
        (,,,,,,, uint256 distributed) = vault.allocationTerms(taskId);
        assertEq(distributed, GROSS, "sponsor tokens distributed");
        assertTrue(ITMPHooksV2(address(market)).getTaskSettlement(taskId).recorded, "record");
    }

    /// @dev The backend's shape: a protocol default V2 hook attached first, then the sponsored hook,
    ///      with the terms hash covering the attachments in that order (as getTaskHooks returns).
    function test_SponsoredCreateAfterADefaultHook() public {
        MockTaskHookV2 defaultHook = new MockTaskHookV2(address(market), uint32(1) << 25);
        address[] memory defaults = new address[](1);
        defaults[0] = address(defaultHook);
        vm.prank(owner);
        ITMPHooksV2(address(market)).setDefaultHooksV2(defaults);

        address[] memory attached = new address[](2);
        attached[0] = address(defaultHook);
        attached[1] = address(hook);
        bytes[] memory configs = new bytes[](1);
        configs[0] = hook.encodeHookData(
            SponsoredTaskHookV2.FundingRequest({
                route: 0,
                vault: address(vault),
                vaultId: vault.vaultId(),
                allocationId: bytes32(0),
                epoch: 1,
                feeBps: 0,
                feeRecipient: address(0xFEE1),
                grossAmount: GROSS,
                taskTermsHash: _termsHash(attached)
            })
        );
        bytes32 taskId = abi.decode(
            forwarder.relay(
                address(market),
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        taskConfig(REWARD, DURATION, TMP_BOUNTY),
                        ITMPCore.HookConfig({ contracts: _one(address(hook)), data: abi.encode(configs) }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        noEvaluatorConfig(),
                        stakeTerms(false, 0)
                    )
                )
            ),
            (bytes32)
        );
        assertEq(market.getTaskHooks(taskId)[0], address(defaultHook), "defaults first");
        (,,,,,,,, SponsoredTaskHookV2.HookStatus st) = hook.taskAllocationSettlement(taskId);
        assertEq(uint8(st), uint8(SponsoredTaskHookV2.HookStatus.Reserved), "reserved at creation");
    }

    /// @dev A rejected delivery whose outcome is a refund ends the task (Expired), but the diamond
    ///      dispatches only afterForfeit. The reservation must still go back to the vault.
    function test_RejectedDeliveryThatEndsTheTask_ReleasesTheReservation() public {
        address[] memory hooks = _one(address(hook));
        SponsoredTaskTerms.SettlementTerms memory settlement;
        settlement.rejectOutcome = uint8(ITMPCore.RejectOutcome.Refund);
        bytes[] memory configs = new bytes[](1);
        configs[0] = hook.encodeHookData(
            SponsoredTaskHookV2.FundingRequest({
                route: 0,
                vault: address(vault),
                vaultId: vault.vaultId(),
                allocationId: bytes32(0),
                epoch: 1,
                feeBps: 0,
                feeRecipient: address(0xFEE1),
                grossAmount: GROSS,
                taskTermsHash: _termsHash(hooks, TMP_CLAIM, settlement)
            })
        );
        ITMPCore.TaskTerms memory terms;
        terms.version = 1;
        terms.rejectOutcome = ITMPCore.RejectOutcome.Refund;
        bytes32 taskId = abi.decode(
            forwarder.relay(
                address(market),
                requester,
                REWARD,
                abi.encodeCall(
                    ITMPTerms.createTask,
                    (
                        taskConfig(REWARD, DURATION, TMP_CLAIM),
                        ITMPCore.HookConfig({ contracts: hooks, data: abi.encode(configs) }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        noEvaluatorConfig(),
                        terms
                    )
                )
            ),
            (bytes32)
        );
        assertEq(vault.totalReserved(), GROSS, "reserved at creation");

        forwarder.relay(address(market), worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        forwarder.relay(address(market), worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.rejectDelivery, (taskId)));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Expired), "task ended");

        (,,,,,,,, SponsoredTaskHookV2.HookStatus st) = hook.taskAllocationSettlement(taskId);
        assertEq(uint8(st), uint8(SponsoredTaskHookV2.HookStatus.Released), "released in the same call");
        assertEq(vault.totalReserved(), 0, "reservation back in the vault");
        assertEq(vault.managerAccount(requester).reserved, 0, "manager cap restored");
    }

    /// @dev A requester that spreads its acceptSubmissions over more than MAX_AWARDS paying awards
    ///      (eight of them dust to addresses it controls) releases the sponsorship. No evaluator
    ///      chose that list, so the hook records the default against the requester (rev031).
    function test_RequesterPaddedAcceptSubmissions_RecordsDefaultByRequester() public {
        address[] memory hooks = _one(address(hook));
        bytes[] memory configs = new bytes[](1);
        configs[0] = hook.encodeHookData(
            SponsoredTaskHookV2.FundingRequest({
                route: 0,
                vault: address(vault),
                vaultId: vault.vaultId(),
                allocationId: bytes32(0),
                epoch: 1,
                feeBps: 0,
                feeRecipient: address(0xFEE1),
                grossAmount: GROSS,
                taskTermsHash: _termsHash(hooks)
            })
        );
        bytes32 taskId = abi.decode(
            forwarder.relay(
                address(market),
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        taskConfig(REWARD, DURATION, TMP_BOUNTY),
                        ITMPCore.HookConfig({ contracts: hooks, data: abi.encode(configs) }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        noEvaluatorConfig(),
                        stakeTerms(false, 0)
                    )
                )
            ),
            (bytes32)
        );
        uint256 n = hook.MAX_AWARDS() + 1;
        address[] memory workers = new address[](n);
        uint16[] memory shares = new uint16[](n);
        for (uint256 i; i < n; ++i) {
            workers[i] = address(uint160(0xD000 + i));
            shares[i] = 1;
            forwarder.relay(address(market), workers[i], 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        }
        shares[0] = uint16(10_000 - (n - 1));

        vm.recordLogs();
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0))
        );

        (,,,,,,,, SponsoredTaskHookV2.HookStatus st) = hook.taskAllocationSettlement(taskId);
        assertEq(uint8(st), uint8(SponsoredTaskHookV2.HookStatus.AwardCountExceeded), "sponsorship released");
        assertEq(vault.totalReserved(), 0, "reservation back in the vault");
        assertEq(_requesterDefaults(address(hook), taskId), 1, "default recorded against the requester");
    }

    function _requesterDefaults(address emitter, bytes32 taskId) internal returns (uint256 count) {
        bytes32 sig = keccak256("SponsoredTaskDefaultedByRequester(bytes32,bytes32,address)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == emitter && logs[i].topics.length == 4 && logs[i].topics[0] == sig
                    && logs[i].topics[1] == taskId && logs[i].topics[3] == bytes32(uint256(uint160(requester)))
            ) ++count;
        }
    }

    /// @dev A sponsored Claim task offered to `reserved`, funded with `termsHash`.
    function _createReserved(address reserved, bytes32 termsHash) internal returns (bytes memory) {
        address[] memory hooks = _one(address(hook));
        bytes[] memory configs = new bytes[](1);
        configs[0] = hook.encodeHookData(
            SponsoredTaskHookV2.FundingRequest({
                route: 0,
                vault: address(vault),
                vaultId: vault.vaultId(),
                allocationId: bytes32(0),
                epoch: 1,
                feeBps: 0,
                feeRecipient: address(0xFEE1),
                grossAmount: GROSS,
                taskTermsHash: termsHash
            })
        );
        return abi.encodeCall(
            ITMPReservation.createTask,
            (
                taskConfig(REWARD, DURATION, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: hooks, data: abi.encode(configs) }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                stakeTerms(false, 0),
                reserved
            )
        );
    }

    /// @dev Rev031 (Cyclops 4445): the terms hash of a task with a reserved worker commits that
    ///      worker, so a manager cannot fund a reservation the sponsor did not commit to.
    function test_ReservedWorkerIsPartOfTheTermsHash() public {
        SponsoredTaskTerms.SettlementTerms memory settlement;
        bytes32 withoutWorker = _termsHash(_one(address(hook)), TMP_CLAIM, settlement);
        bytes32 withWorker =
            keccak256(abi.encode(SponsoredTaskTerms.RESERVED_TERMS_HASH_TYPEHASH, withoutWorker, worker));

        bytes memory unbound = _createReserved(worker, withoutWorker);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITMPHooksV2.HookRejected.selector,
                uint8(0),
                uint8(0),
                abi.encodeWithSelector(SponsoredTaskHookV2.TaskTermsMismatch.selector, withoutWorker, withWorker)
            )
        );
        forwarder.relay(address(market), requester, REWARD, unbound);

        bytes32 taskId = abi.decode(
            forwarder.relay(address(market), requester, REWARD, _createReserved(worker, withWorker)), (bytes32)
        );
        assertEq(hook.currentTaskTermsHash(taskId), withWorker, "the reservation's worker is committed");
        (,,,,,,,, SponsoredTaskHookV2.HookStatus st) = hook.taskAllocationSettlement(taskId);
        assertEq(uint8(st), uint8(SponsoredTaskHookV2.HookStatus.Reserved), "funded");
    }

    function _one(address h) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = h;
    }
}
