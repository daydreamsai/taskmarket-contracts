// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHookV2 } from "../src/interfaces/ITMPHookV2.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { SponsoredTaskTypes } from "../src/hooks/sponsored-task/SponsoredTaskTypes.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTaskFactoryV2 } from "../src/hooks/sponsored-task/SponsoredTaskFactoryV2.sol";
import { SponsoredTasksVaultV2 } from "../src/hooks/sponsored-task/SponsoredTasksVaultV2.sol";
import { SponsoredTaskHook } from "../src/hooks/sponsored-task/SponsoredTaskHook.sol";
import { SponsoredTaskHookV2 } from "../src/hooks/sponsored-task/SponsoredTaskHookV2.sol";
import { SponsoredTaskTerms } from "../src/hooks/sponsored-task/libraries/SponsoredTaskTerms.sol";
import { PayoutGateHook } from "../src/hooks/payout-gate/PayoutGateHook.sol";
import { MockTaskHookV2 } from "./mocks/MockTaskHookV2.sol";
import { SponsoredTaskFeeConfig } from "./helpers/SponsoredTaskFeeConfig.sol";
import { MockTaskmarketForSponsoredTask } from "./SponsoredTaskHook.t.sol";
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

/// @dev Parity: the V2 hook reaches the V1 hook's outcomes for the same task state.
contract SponsoredTaskHookV2ParityTest is Test {
    bytes32 private constant TASK_ID = keccak256("task");
    uint256 private constant NATIVE_REWARD = 1_000_000;
    uint256 private constant GROSS = 10_000;
    uint16 private constant TOKEN_FEE_BPS = 50;
    address private constant MANAGER = address(0xCAFE);
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant TOKEN_FEE_RECIPIENT = address(0xFEE1);

    MockTaskmarketV2ForSponsoredTask private market1;
    MockTaskmarketV2ForSponsoredTask private market2;
    MockERC20 private usdc;
    MockERC20 private projectToken;
    SponsoredTaskHook private hook1;
    SponsoredTaskHookV2 private hook2;
    SponsoredTasksVaultV2 private vault1;
    SponsoredTasksVaultV2 private vault2;

    function setUp() external {
        usdc = new MockERC20("USD Coin", "USDC", 6, address(this));
        projectToken = new MockERC20("Project", "PROJECT", 18, address(this));
        SponsoredTaskFeePolicy feePolicy = new SponsoredTaskFeePolicy(address(this), TOKEN_FEE_BPS, TOKEN_FEE_RECIPIENT);
        SponsoredTaskRegistry registry = new SponsoredTaskRegistry(address(this));
        market1 = new MockTaskmarketV2ForSponsoredTask();
        market2 = new MockTaskmarketV2ForSponsoredTask();
        hook1 = new SponsoredTaskHook(address(market1), IERC20(address(usdc)), registry);
        hook2 = new SponsoredTaskHookV2(address(market2), IERC20(address(usdc)), registry);
        vault1 = _vault(registry, address(hook1), address(feePolicy), "v1");
        vault2 = _vault(registry, address(hook2), address(feePolicy), "v2");
        market1.primeTask(TASK_ID, MANAGER, address(usdc), NATIVE_REWARD, TMP_BOUNTY, address(hook1));
        market2.primeTask(TASK_ID, MANAGER, address(usdc), NATIVE_REWARD, TMP_BOUNTY, address(hook2));
    }

    function _vault(SponsoredTaskRegistry registry, address hook, address feePolicy, bytes memory salt)
        private
        returns (SponsoredTasksVaultV2 vault)
    {
        SponsoredTaskFactoryV2 factory = new SponsoredTaskFactoryV2(
            hook, feePolicy, registry, SponsoredTaskFeeConfig.none(IERC20(address(usdc)))
        );
        registry.setFactory(address(factory), true);
        (address vaultAddress,) = factory.createVault(address(projectToken), address(this), keccak256(salt));
        vault = SponsoredTasksVaultV2(vaultAddress);
        vault.configureManager(MANAGER, GROSS * 100, true);
        projectToken.mint(address(this), GROSS * 100);
        projectToken.approve(address(vault), type(uint256).max);
        vault.fund(GROSS * 100);
    }

    function _hookData(SponsoredTaskHook h, SponsoredTasksVaultV2 v, bytes32 termsHash)
        private
        view
        returns (bytes memory)
    {
        return h.encodeHookData(
            SponsoredTaskHook.FundingRequest({
                route: 0,
                vault: address(v),
                vaultId: v.vaultId(),
                allocationId: bytes32(0),
                epoch: 1,
                feeBps: TOKEN_FEE_BPS,
                feeRecipient: TOKEN_FEE_RECIPIENT,
                grossAmount: GROSS,
                taskTermsHash: termsHash
            })
        );
    }

    function _fundBoth() private {
        market1.callCheckFund(hook1, TASK_ID, _hookData(hook1, vault1, hook1.currentTaskTermsHash(TASK_ID)));
        // The V2 configuration is the V1 hookData, byte for byte.
        bytes memory config = _hookData(hook1, vault2, hook2.currentTaskTermsHash(TASK_ID));
        assertEq(
            keccak256(config),
            keccak256(
                hook2.encodeHookData(
                    SponsoredTaskHookV2.FundingRequest({
                        route: 0,
                        vault: address(vault2),
                        vaultId: vault2.vaultId(),
                        allocationId: bytes32(0),
                        epoch: 1,
                        feeBps: TOKEN_FEE_BPS,
                        feeRecipient: TOKEN_FEE_RECIPIENT,
                        grossAmount: GROSS,
                        taskTermsHash: hook2.currentTaskTermsHash(TASK_ID)
                    })
                )
            ),
            "same encoding"
        );
        market2.v2Create(hook2, TASK_ID, config);
    }

    function _verdict() private pure returns (ITMPCore.Verdict memory v) {
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](2);
        awards[0] = ITMPCore.Award({ worker: ALICE, amount: 700_000, rank: 1 });
        awards[1] = ITMPCore.Award({ worker: BOB, amount: 300_000, rank: 2 });
        v.issued = true;
        v.verdictType = ITMPCore.VerdictType.APPROVE;
        v.score = 1000;
        v.confidence = 1000;
        v.awards = awards;
    }

    function _assertVaultsMatch() private view {
        (,,,,,,, uint256 d1) = vault1.allocationTerms(TASK_ID);
        (,,,,,,, uint256 d2) = vault2.allocationTerms(TASK_ID);
        assertEq(d1, d2, "distributedGross");
        (uint256 o1, uint256 p1, uint256 f1,, uint256 r1,,, SponsoredTaskTypes.AllocationStatus s1) =
            vault1.allocationSettlement(TASK_ID);
        (uint256 o2, uint256 p2, uint256 f2,, uint256 r2,,, SponsoredTaskTypes.AllocationStatus s2) =
            vault2.allocationSettlement(TASK_ID);
        assertEq(o1, o2, "outstanding");
        assertEq(p1, p2, "paid");
        assertEq(f1, f2, "fee outstanding");
        assertEq(r1, r2, "released");
        assertEq(uint8(s1), uint8(s2), "vault status");
    }

    function _status1() private view returns (uint8 s) {
        (,,,,,,,, SponsoredTaskHook.HookStatus st) = hook1.taskAllocationSettlement(TASK_ID);
        s = uint8(st);
    }

    function _status2() private view returns (uint8 s) {
        (,,,,,,,, SponsoredTaskHookV2.HookStatus st) = hook2.taskAllocationSettlement(TASK_ID);
        s = uint8(st);
    }

    function test_DeclaresOnlyItsCapabilities() external view {
        assertEq(hook2.hookCapabilities(), hook2.CAPABILITIES());
        assertEq(hook2.minDiamondVersion(), 28);
        assertTrue(hook2.supportsInterface(type(ITMPHookV2).interfaceId));
    }

    function test_ParityReserve() external {
        _fundBoth();
        assertEq(_status1(), _status2(), "hook status");
        _assertVaultsMatch();
    }

    function test_ParityCompletionAndSettlement() external {
        _fundBoth();
        market1.setStatus(TASK_ID, ITMPCore.TaskStatus.Accepted);
        market2.setStatus(TASK_ID, ITMPCore.TaskStatus.Accepted);
        market1.callCheckComplete(hook1, TASK_ID, _verdict());
        market2.v2Accept(hook2, TASK_ID, _verdict());
        assertEq(_status1(), _status2(), "committed");
        // The rewards roots differ only because each binds its own vault; the amounts must match.
        hook1.finalizeSettlement(TASK_ID, _verdict().awards);
        hook2.finalizeSettlement(TASK_ID, _verdict().awards);
        assertEq(_status1(), _status2(), "settled");
        _assertVaultsMatch();
    }

    function test_ParityCancelRelease() external {
        _fundBoth();
        market1.setStatus(TASK_ID, ITMPCore.TaskStatus.Cancelled);
        market2.setStatus(TASK_ID, ITMPCore.TaskStatus.Cancelled);
        market1.callOnCancel(hook1, TASK_ID);
        market2.v2AfterCancel(hook2, TASK_ID);
        assertEq(_status1(), _status2(), "released");
        _assertVaultsMatch();
    }

    function test_AfterCompleteCommitsUncommittedCompletion() external {
        _fundBoth();
        market1.setStatus(TASK_ID, ITMPCore.TaskStatus.Accepted);
        market2.setStatus(TASK_ID, ITMPCore.TaskStatus.Accepted);
        market1.setVerdict(TASK_ID, _verdict());
        market2.setVerdict(TASK_ID, _verdict());
        market1.callOnComplete(hook1, TASK_ID, _verdict());
        market2.v2AfterComplete(hook2, TASK_ID);
        assertEq(_status1(), _status2(), "committed from the stored verdict");
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
        SponsoredTaskTerms.Terms memory t = SponsoredTaskTerms.Terms({
            reward: REWARD,
            duration: DURATION,
            mode: TMP_BOUNTY,
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
        // Default settlement terms: every window and outcome is left at its zero (protocol default).
        SponsoredTaskTerms.SettlementTerms memory settlement;
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

    function _one(address h) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = h;
    }
}
