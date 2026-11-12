// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
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
import { SponsoredTaskHookV2 } from "../src/hooks/sponsored-task/SponsoredTaskHookV2.sol";
import { RemoteSponsoredTaskHookV2 } from "../src/hooks/sponsored-task/RemoteSponsoredTaskHookV2.sol";
import { SponsoredTaskSettlement } from "../src/hooks/sponsored-task/libraries/SponsoredTaskSettlement.sol";
import { SponsoredTaskTerms } from "../src/hooks/sponsored-task/libraries/SponsoredTaskTerms.sol";
import { MockTaskHookV2 } from "./mocks/MockTaskHookV2.sol";
import { SponsoredTaskFeeConfig } from "./helpers/SponsoredTaskFeeConfig.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev Rev030: the sponsorship follows the awards the diamond settled. A task carries the
///      sponsored hook and a requester transforming hook (bit 26 reallocate) after it; the commitment
///      `beforeAccept` makes from the core verdict is provisional, and `afterComplete`, `reconcile`
///      and `finalizeSettlement` recommit from the stored verdict that holds the paid awards.
abstract contract SponsoredSettledAwardsBase is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;
    MockTaskHookV2 internal transformer;

    address internal owner = address(0xA0);
    address internal requester = address(0xB0);
    address internal evaluator = address(0xE0);
    address internal resolver = address(0xD0);
    uint256 internal constant REWARD = 100e6;
    uint256 internal constant DURATION = 7 days;
    uint256 internal constant GROSS = 10_000;

    function _baseSetUp() internal {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), address(0xFEE), 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 1_000_000e6);
        transformer = new MockTaskHookV2(address(market), (uint32(1) << 13) | (uint32(1) << 26) | (uint32(1) << 27));
    }

    function _w(uint256 i) internal pure returns (address) {
        return address(uint160(0xC0 + i));
    }

    function _relay(address sender, uint256 amount, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, amount, data);
    }

    function _hooks(address sponsored) internal view returns (address[] memory hooks) {
        hooks = new address[](2);
        hooks[0] = sponsored;
        hooks[1] = address(transformer);
    }

    /// @dev The terms hash a Bounty with no evaluator at creation and default settlement terms has.
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
            evaluator: evaluatorAtCreation ? evaluator : address(0),
            evaluatorStake: 0,
            evaluatorFeeBps: 0,
            evaluationWindow: evaluatorAtCreation ? 2 days : 0,
            appealWindow: evaluatorAtCreation ? 1 days : 0,
            disputeResolver: evaluatorAtCreation ? resolver : address(0),
            contentHash: bytes32(0),
            contentURIHash: keccak256(bytes("")),
            tagsHash: keccak256(abi.encode(new bytes32[](0))),
            hooksHash: keccak256(abi.encode(hooks))
        });
        SponsoredTaskTerms.SettlementTerms memory settlement;
        return keccak256(
            abi.encode(
                SponsoredTaskTerms.TERMS_HASH_TYPEHASH,
                keccak256(abi.encode(SponsoredTaskTerms.TASK_TERMS_TYPEHASH, t)),
                keccak256(abi.encode(SponsoredTaskTerms.SETTLEMENT_TERMS_TYPEHASH, settlement))
            )
        );
    }

    function _create(address[] memory hooks, bytes memory sponsoredConfig) internal returns (bytes32 taskId) {
        bytes[] memory configs = new bytes[](hooks.length);
        configs[0] = sponsoredConfig;
        taskId = abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        taskConfig(REWARD, DURATION, TMP_BOUNTY),
                        ITMPCore.HookConfig({ contracts: hooks, data: abi.encode(configs) }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        evaluatorAtCreation
                            ? ITMPCore.TaskEvaluatorConfig({
                                evaluator: evaluator,
                                evaluatorStake: 0,
                                evaluatorFeeBps: 0,
                                evaluationWindow: 2 days,
                                appealWindow: 1 days,
                                disputeResolver: resolver
                            })
                            : noEvaluatorConfig(),
                        stakeTerms(false, 0)
                    )
                )
            ),
            (bytes32)
        );
    }

    function _submit(bytes32 taskId, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            _relay(_w(i), 0, abi.encodeCall(market.submitWork, (taskId, keccak256(abi.encode("work", i)))));
        }
    }

    function _acceptOne(bytes32 taskId) internal {
        _relay(
            requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, _w(0), keccak256(abi.encode("work", 0)), 0))
        );
    }

    /// @dev acceptSubmissions over the first `n` submitters, in equal shares (the first takes the rest).
    function _acceptN(bytes32 taskId, uint256 n) internal returns (ITMPCore.Award[] memory core) {
        address[] memory workers = new address[](n);
        uint16[] memory shares = new uint16[](n);
        uint256 left = 10_000;
        for (uint256 i; i < n; ++i) {
            workers[i] = _w(i);
            shares[i] = uint16(10_000 / n);
            left -= 10_000 / n;
        }
        shares[0] += uint16(left);
        core = new ITMPCore.Award[](n);
        for (uint256 i; i < n; ++i) {
            core[i] = ITMPCore.Award({ worker: workers[i], amount: REWARD * shares[i] / 10_000, rank: uint16(i + 1) });
        }
        _relay(requester, 0, abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0)));
    }

    function _evaluateAndFinalize(bytes32 taskId, ITMPCore.VerdictType verdictType, ITMPCore.Award[] memory awards)
        internal
    {
        _relay(
            evaluator,
            0,
            abi.encodeCall(market.evaluate, (taskId, verdictType, uint16(900), uint16(1000), bytes32(0), awards))
        );
        vm.warp(block.timestamp + 1 days);
        market.finalizeVerdict(taskId);
    }

    /// @dev The sponsored hooks freeze the evaluator once a sponsorship is active (rev030), so a task
    ///      that needs one is created with it, and the terms hash the sponsor funded includes it.
    bool internal evaluatorAtCreation;

    function _withEvaluator() internal {
        evaluatorAtCreation = true;
    }

    function _award(address w, uint256 amount, uint16 rank) internal pure returns (ITMPCore.Award memory) {
        return ITMPCore.Award({ worker: w, amount: amount, rank: rank });
    }

    function _two(ITMPCore.Award memory a, ITMPCore.Award memory b) internal pure returns (ITMPCore.Award[] memory r) {
        r = new ITMPCore.Award[](2);
        r[0] = a;
        r[1] = b;
    }

    function _three(ITMPCore.Award memory a, ITMPCore.Award memory b, ITMPCore.Award memory c)
        internal
        pure
        returns (ITMPCore.Award[] memory r)
    {
        r = new ITMPCore.Award[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    /// @dev The net sponsor entitlement each SponsoredTaskEntitlement event in `logs` grants `worker`.
    function _netOf(Vm.Log[] memory logs, address emitter, address worker) internal pure returns (uint256 net) {
        bytes32 sig =
            keccak256("SponsoredTaskEntitlement(bytes32,uint256,address,uint256,uint256,uint256,uint256,bytes32)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != emitter || logs[i].topics.length != 4 || logs[i].topics[0] != sig) continue;
            if (address(uint160(uint256(logs[i].topics[3]))) != worker) continue;
            (,,, uint256 n,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, bytes32));
            net += n;
        }
    }
}

contract Rev030SponsoredTaskSettledAwardsTest is SponsoredSettledAwardsBase {
    MockERC20 internal projectToken;
    SponsoredTaskHookV2 internal hook;
    SponsoredTasksVaultV2 internal vault;

    function setUp() public {
        _baseSetUp();
        projectToken = new MockERC20("Project", "PROJECT", 18, address(this));
        SponsoredTaskFeePolicy feePolicy = new SponsoredTaskFeePolicy(address(this), 0, address(0xFEE1));
        SponsoredTaskRegistry registry = new SponsoredTaskRegistry(address(this));
        address implementation = address(new SponsoredTaskHookV2(address(market), IERC20(address(usdc)), registry));
        hook = SponsoredTaskHookV2(
            address(new ERC1967Proxy(implementation, abi.encodeCall(SponsoredTaskHookV2.initialize, (address(this)))))
        );
        SponsoredTaskFactoryV2 factory = new SponsoredTaskFactoryV2(
            address(hook), address(feePolicy), registry, SponsoredTaskFeeConfig.none(IERC20(address(usdc)))
        );
        registry.setFactory(address(factory), true);
        (address vaultAddress,) = factory.createVault(address(projectToken), address(this), keccak256("rev030"));
        vault = SponsoredTasksVaultV2(vaultAddress);
        vault.configureManager(requester, GROSS * 100, true);
        projectToken.mint(address(this), GROSS * 100);
        projectToken.approve(address(vault), type(uint256).max);
        vault.fund(GROSS * 100);
    }

    function _sponsoredTask() internal returns (bytes32) {
        address[] memory hooks = _hooks(address(hook));
        return _create(
            hooks,
            hook.encodeHookData(
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
            )
        );
    }

    function _status(bytes32 taskId) internal view returns (SponsoredTaskHookV2.HookStatus st) {
        (,,,,,,,, st) = hook.taskAllocationSettlement(taskId);
    }

    function _digest(bytes32 taskId) internal view returns (bytes32 d) {
        (, d,,,,,,,) = hook.taskAllocationSettlement(taskId);
    }

    /// @dev The settlement the hook must install for `awards`, against a pool of the full reward.
    function _expected(bytes32 taskId, ITMPCore.VerdictType verdictType, ITMPCore.Award[] memory awards)
        internal
        view
        returns (SponsoredTaskSettlement.Result memory)
    {
        return SponsoredTaskSettlement.calculate(
            SponsoredTaskSettlement.SettlementIdentity({
                vaultId: vault.vaultId(), vaultEpoch: 1, allocationId: taskId, taskId: taskId
            }),
            GROSS,
            REWARD,
            0,
            verdictType,
            awards
        );
    }

    function _assertSettled(bytes32 taskId, ITMPCore.VerdictType verdictType, ITMPCore.Award[] memory paid)
        internal
        view
    {
        assertEq(uint8(_status(taskId)), uint8(SponsoredTaskHookV2.HookStatus.SettlementPrepared), "settled");
        SponsoredTaskSettlement.Result memory r = _expected(taskId, verdictType, paid);
        (,,,, uint256 released, bytes32 root, uint32 leaves,) = vault.allocationSettlement(taskId);
        assertEq(root, r.rewardsRoot, "vault root follows the paid awards");
        assertEq(leaves, r.leafCount, "leaf count");
        (,,,,,,, uint256 distributed) = vault.allocationTerms(taskId);
        assertEq(distributed, r.distributedGross, "distributed");
        assertEq(released, GROSS - r.distributedGross, "the rest released");
    }

    // -------------------------------------------------------------------------
    // acceptSubmission
    // -------------------------------------------------------------------------

    function test_AcceptSubmission_SponsorshipFollowsReallocatedAward() public {
        bytes32 taskId = _sponsoredTask();
        _submit(taskId, 2);
        // The requester accepts worker 0; its transforming hook pays worker 1 instead.
        ITMPCore.Award[] memory paid = _two(_award(_w(0), 0, 1), _award(_w(1), 60e6, 2));
        transformer.setResult(paid, 0, false);
        _acceptOne(taskId);

        assertEq(
            _digest(taskId),
            SponsoredTaskSettlement.awardsDigestMemory(taskId, ITMPCore.VerdictType.APPROVE, paid),
            "commitment recommitted from the paid awards"
        );
        vm.recordLogs();
        hook.reconcile(taskId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertSettled(taskId, ITMPCore.VerdictType.APPROVE, paid);
        assertEq(_netOf(logs, address(hook), _w(0)), 0, "the cut worker gets no sponsor tokens");
        assertEq(_netOf(logs, address(hook), _w(1)), GROSS, "the paid worker gets the sponsorship");
    }

    function test_AcceptSubmission_UnchangedWithoutTransform() public {
        bytes32 taskId = _sponsoredTask();
        _submit(taskId, 1);
        _acceptOne(taskId);
        assertFalse(market.getTaskVerdict(taskId).issued, "no stored verdict");
        ITMPCore.Award[] memory core = new ITMPCore.Award[](1);
        core[0] = _award(_w(0), REWARD, 1);
        assertEq(
            _digest(taskId),
            SponsoredTaskSettlement.awardsDigestMemory(taskId, ITMPCore.VerdictType.APPROVE, core),
            "core commitment"
        );
        hook.reconcile(taskId);
        _assertSettled(taskId, ITMPCore.VerdictType.APPROVE, core);
    }

    /// @dev A fee-only result (bit 27) leaves the awards as the core computed them: no verdict is
    ///      stored and the core commitment settles.
    function test_AcceptSubmissions_FeeOnlyTransformKeepsCoreAwards() public {
        bytes32 taskId = _sponsoredTask();
        _submit(taskId, 2);
        vm.prank(owner);
        ITMPHooksV2(address(market)).setMaxHookFeeBps(100);
        transformer.setResult(new ITMPCore.Award[](0), 100, false);
        ITMPCore.Award[] memory core = _acceptN(taskId, 2);
        assertFalse(market.getTaskVerdict(taskId).issued, "no stored verdict");
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskHookV2.AwardsRequired.selector, taskId));
        hook.reconcile(taskId);
        hook.finalizeSettlement(taskId, core);
        _assertSettled(taskId, ITMPCore.VerdictType.APPROVE, core);
    }

    // -------------------------------------------------------------------------
    // acceptSubmissions (multi-winner Bounty)
    // -------------------------------------------------------------------------

    function test_AcceptSubmissions_SponsorshipFollowsReallocatedAwards() public {
        bytes32 taskId = _sponsoredTask();
        _submit(taskId, 3);
        // Core: workers 0 and 1 in halves. Paid: worker 0 cut to zero, worker 1 raised, worker 2 added.
        ITMPCore.Award[] memory paid = _three(_award(_w(0), 0, 1), _award(_w(1), 30e6, 2), _award(_w(2), 10e6, 3));
        transformer.setResult(paid, 0, false);
        ITMPCore.Award[] memory core = _acceptN(taskId, 2);

        assertEq(market.getTaskVerdict(taskId).awards.length, 3, "verdict records the paid awards");
        // A permissionless settlement with the core awards no longer matches.
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskHookV2.VerdictCommitmentMismatch.selector, taskId));
        hook.finalizeSettlement(taskId, core);

        vm.recordLogs();
        assertEq(uint8(hook.reconcile(taskId)), uint8(SponsoredTaskHookV2.HookStatus.SettlementPrepared));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertSettled(taskId, ITMPCore.VerdictType.APPROVE, paid);
        assertEq(_netOf(logs, address(hook), _w(0)), 0, "cut worker");
        assertEq(_netOf(logs, address(hook), _w(1)), GROSS * 3 / 4, "raised worker");
        assertEq(_netOf(logs, address(hook), _w(2)), GROSS / 4, "added worker");
        // Settled: further calls are no-ops.
        assertEq(uint8(hook.reconcile(taskId)), uint8(SponsoredTaskHookV2.HookStatus.SettlementPrepared));
    }

    function test_AcceptSubmissions_UnchangedWithoutTransform() public {
        bytes32 taskId = _sponsoredTask();
        _submit(taskId, 2);
        ITMPCore.Award[] memory core = _acceptN(taskId, 2);
        assertEq(
            _digest(taskId),
            SponsoredTaskSettlement.awardsDigestMemory(taskId, ITMPCore.VerdictType.APPROVE, core),
            "core commitment"
        );
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskHookV2.AwardsRequired.selector, taskId));
        hook.reconcile(taskId);
        hook.finalizeSettlement(taskId, core);
        _assertSettled(taskId, ITMPCore.VerdictType.APPROVE, core);
    }

    // -------------------------------------------------------------------------
    // finalizeVerdict (evaluator path)
    // -------------------------------------------------------------------------

    function test_FinalizeVerdict_ApproveFollowsReallocatedAwards() public {
        _withEvaluator();
        bytes32 taskId = _sponsoredTask();
        _submit(taskId, 2);
        ITMPCore.Award[] memory paid = _two(_award(_w(0), 10e6, 1), _award(_w(1), 30e6, 2));
        transformer.setResult(paid, 0, false);
        _evaluateAndFinalize(taskId, ITMPCore.VerdictType.APPROVE, _two(_award(_w(0), 90e6, 1), _award(_w(1), 10e6, 2)));

        hook.reconcile(taskId);
        _assertSettled(taskId, ITMPCore.VerdictType.APPROVE, paid);
    }

    /// @dev PARTIAL scales the sponsorship by the paid total over the pool, not the core total.
    function test_FinalizeVerdict_PartialScalesFromPaidTotal() public {
        _withEvaluator();
        bytes32 taskId = _sponsoredTask();
        _submit(taskId, 2);
        ITMPCore.Award[] memory paid = _two(_award(_w(0), 10e6, 1), _award(_w(1), 10e6, 2));
        transformer.setResult(paid, 0, false);
        _evaluateAndFinalize(taskId, ITMPCore.VerdictType.PARTIAL, _two(_award(_w(0), 40e6, 1), _award(_w(1), 40e6, 2)));

        hook.reconcile(taskId);
        _assertSettled(taskId, ITMPCore.VerdictType.PARTIAL, paid);
        (,,,,,,, uint256 distributed) = vault.allocationTerms(taskId);
        assertEq(distributed, GROSS * 20e6 / REWARD, "20% of the gross, not 80%");
    }

    function test_FinalizeVerdict_UnchangedWithoutTransform() public {
        _withEvaluator();
        bytes32 taskId = _sponsoredTask();
        _submit(taskId, 2);
        ITMPCore.Award[] memory core = _two(_award(_w(0), 40e6, 1), _award(_w(1), 20e6, 2));
        _evaluateAndFinalize(taskId, ITMPCore.VerdictType.PARTIAL, core);
        hook.reconcile(taskId);
        _assertSettled(taskId, ITMPCore.VerdictType.PARTIAL, core);
    }

    // -------------------------------------------------------------------------
    // MAX_AWARDS, missed afterComplete
    // -------------------------------------------------------------------------

    /// @dev Paid awards above MAX_AWARDS release the provisional commitment's reservation in
    ///      afterComplete, which must not revert.
    function test_PaidAwardsAboveMaxReleaseInAfterComplete() public {
        bytes32 taskId = _sponsoredTask();
        uint256 n = hook.MAX_AWARDS() + 1;
        _submit(taskId, n);
        ITMPCore.Award[] memory paid = new ITMPCore.Award[](n);
        for (uint256 i; i < n; ++i) {
            paid[i] = _award(_w(i), 1e6, uint16(i + 1));
        }
        transformer.setResult(paid, 0, false);
        _acceptN(taskId, 2);

        assertEq(uint8(_status(taskId)), uint8(SponsoredTaskHookV2.HookStatus.AwardCountExceeded), "unsettleable");
        (,,,,,,, SponsoredTaskTypes.AllocationStatus vs) = vault.allocationSettlement(taskId);
        assertEq(uint8(vs), uint8(SponsoredTaskTypes.AllocationStatus.Released), "reservation released");
        assertEq(uint8(hook.reconcile(taskId)), uint8(SponsoredTaskHookV2.HookStatus.AwardCountExceeded));
        assertEq(hook.finalizeSettlement(taskId, paid), bytes32(0), "nothing to settle");
    }

    /// @dev The largest recommit (MAX_AWARDS paid awards) completes inside afterComplete's budget: the
    ///      diamond swallows a failed afterComplete, so a recommitted digest proves it ran to the end.
    function test_MaxPaidAwardsRecommitInAfterComplete() public {
        bytes32 taskId = _sponsoredTask();
        uint256 n = hook.MAX_AWARDS();
        _submit(taskId, n);
        ITMPCore.Award[] memory paid = new ITMPCore.Award[](n);
        for (uint256 i; i < n; ++i) {
            paid[i] = _award(_w(i), 1e6 * (i + 1), uint16(i + 1));
        }
        transformer.setResult(paid, 0, false);
        _acceptN(taskId, 2);
        assertEq(
            _digest(taskId),
            SponsoredTaskSettlement.awardsDigestMemory(taskId, ITMPCore.VerdictType.APPROVE, paid),
            "recommitted in afterComplete"
        );
        hook.reconcile(taskId);
        _assertSettled(taskId, ITMPCore.VerdictType.APPROVE, paid);
    }

    /// @dev Core awards above MAX_AWARDS release at beforeAccept, as before; a transform that cuts
    ///      them back under the bound does not reopen the released sponsorship.
    function test_CoreAwardsAboveMaxStayReleased() public {
        bytes32 taskId = _sponsoredTask();
        uint256 n = hook.MAX_AWARDS() + 1;
        _submit(taskId, n);
        transformer.setResult(_two(_award(_w(0), 50e6, 1), _award(_w(1), 50e6, 2)), 0, false);
        _acceptN(taskId, n);
        assertEq(uint8(_status(taskId)), uint8(SponsoredTaskHookV2.HookStatus.AwardCountExceeded));
        (,,,,,,, SponsoredTaskTypes.AllocationStatus vs) = vault.allocationSettlement(taskId);
        assertEq(uint8(vs), uint8(SponsoredTaskTypes.AllocationStatus.Released), "reservation released");
    }

    /// @dev afterComplete is best effort: when it fails, the provisional commitment holds the core
    ///      awards, and a permissionless finalizeSettlement racing reconcile cannot settle them: both
    ///      recommit from the stored verdict first.
    function test_MissedAfterComplete_SettlementStillFollowsPaidAwards() public {
        bytes32 taskId = _sponsoredTask();
        _submit(taskId, 2);
        ITMPCore.Award[] memory paid = _two(_award(_w(0), 5e6, 1), _award(_w(1), 45e6, 2));
        transformer.setResult(paid, 0, false);
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(ITMPHookV2.afterComplete.selector), "");
        ITMPCore.Award[] memory core = _acceptN(taskId, 2);
        vm.clearMockedCalls();
        assertEq(
            _digest(taskId),
            SponsoredTaskSettlement.awardsDigestMemory(taskId, ITMPCore.VerdictType.APPROVE, core),
            "still the provisional commitment"
        );

        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskHookV2.VerdictCommitmentMismatch.selector, taskId));
        hook.finalizeSettlement(taskId, core);
        hook.finalizeSettlement(taskId, paid);
        _assertSettled(taskId, ITMPCore.VerdictType.APPROVE, paid);
    }

    function test_MissedAfterComplete_ReconcileFollowsPaidAwards() public {
        bytes32 taskId = _sponsoredTask();
        _submit(taskId, 2);
        ITMPCore.Award[] memory paid = _two(_award(_w(0), 5e6, 1), _award(_w(1), 45e6, 2));
        transformer.setResult(paid, 0, false);
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(ITMPHookV2.afterComplete.selector), "");
        _acceptN(taskId, 2);
        vm.clearMockedCalls();
        hook.reconcile(taskId);
        _assertSettled(taskId, ITMPCore.VerdictType.APPROVE, paid);
    }
}

contract Rev030RemoteSponsoredTaskSettledAwardsTest is SponsoredSettledAwardsBase {
    RemoteSponsoredTaskHookV2 internal hook;

    function setUp() public {
        _baseSetUp();
        address implementation = address(new RemoteSponsoredTaskHookV2(address(market)));
        hook = RemoteSponsoredTaskHookV2(
            address(
                new ERC1967Proxy(implementation, abi.encodeCall(RemoteSponsoredTaskHookV2.initialize, (address(this))))
            )
        );
    }

    function _remoteTask() internal returns (bytes32) {
        address[] memory hooks = _hooks(address(hook));
        return _create(
            hooks,
            hook.encodeHookData(
                RemoteSponsoredTaskHookV2.FundingRequest({
                    remoteChainId: 46_630,
                    vault: address(0x7A17),
                    vaultId: keccak256("remote-vault"),
                    token: address(0x70CE),
                    grossAmount: GROSS,
                    commitmentNonce: 1,
                    epoch: 1,
                    feeBps: 0,
                    feeRecipient: address(0),
                    taskTermsHash: _termsHash(hooks)
                })
            )
        );
    }

    function _expectedRoot(bytes32 taskId, ITMPCore.VerdictType verdictType, ITMPCore.Award[] memory awards)
        internal
        view
        returns (bytes32)
    {
        RemoteSponsoredTaskHookV2.Commitment memory c = hook.commitment(taskId);
        return SponsoredTaskSettlement.calculate(
            SponsoredTaskSettlement.SettlementIdentity({
                vaultId: c.vaultId, vaultEpoch: c.epoch, allocationId: c.allocationId, taskId: taskId
            }),
            GROSS,
            REWARD,
            0,
            verdictType,
            awards
        )
        .rewardsRoot;
    }

    function test_Remote_AcceptSubmissions_RootFollowsReallocatedAwards() public {
        bytes32 taskId = _remoteTask();
        _submit(taskId, 3);
        ITMPCore.Award[] memory paid = _three(_award(_w(0), 0, 1), _award(_w(1), 30e6, 2), _award(_w(2), 10e6, 3));
        transformer.setResult(paid, 0, false);
        ITMPCore.Award[] memory core = _acceptN(taskId, 2);

        RemoteSponsoredTaskHookV2.Outcome memory o = hook.outcome(taskId);
        assertEq(
            o.awardsDigest,
            SponsoredTaskSettlement.awardsDigestMemory(taskId, ITMPCore.VerdictType.APPROVE, paid),
            "recommitted"
        );
        vm.expectRevert(abi.encodeWithSelector(RemoteSponsoredTaskHookV2.VerdictCommitmentMismatch.selector, taskId));
        hook.finalizeSettlement(taskId, core);
        vm.recordLogs();
        hook.reconcile(taskId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        o = hook.outcome(taskId);
        assertEq(uint8(o.status), uint8(RemoteSponsoredTaskHookV2.HookStatus.SettlementPrepared));
        assertEq(o.rewardsRoot, _expectedRoot(taskId, ITMPCore.VerdictType.APPROVE, paid), "relayed root");
        assertEq(_netOf(logs, address(hook), _w(0)), 0, "cut worker");
        assertEq(_netOf(logs, address(hook), _w(2)), GROSS / 4, "added worker");
    }

    function test_Remote_UnchangedWithoutTransform() public {
        bytes32 taskId = _remoteTask();
        _submit(taskId, 2);
        ITMPCore.Award[] memory core = _acceptN(taskId, 2);
        hook.finalizeSettlement(taskId, core);
        assertEq(hook.outcome(taskId).rewardsRoot, _expectedRoot(taskId, ITMPCore.VerdictType.APPROVE, core));
    }

    function test_Remote_FinalizeVerdictPartialFollowsPaidAwards() public {
        _withEvaluator();
        bytes32 taskId = _remoteTask();
        _submit(taskId, 2);
        ITMPCore.Award[] memory paid = _two(_award(_w(0), 10e6, 1), _award(_w(1), 10e6, 2));
        transformer.setResult(paid, 0, false);
        _evaluateAndFinalize(taskId, ITMPCore.VerdictType.PARTIAL, _two(_award(_w(0), 40e6, 1), _award(_w(1), 40e6, 2)));
        hook.reconcile(taskId);
        assertEq(hook.outcome(taskId).rewardsRoot, _expectedRoot(taskId, ITMPCore.VerdictType.PARTIAL, paid));
    }

    function test_Remote_MissedAfterComplete_FinalizeFollowsPaidAwards() public {
        bytes32 taskId = _remoteTask();
        _submit(taskId, 2);
        ITMPCore.Award[] memory paid = _two(_award(_w(0), 5e6, 1), _award(_w(1), 45e6, 2));
        transformer.setResult(paid, 0, false);
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(ITMPHookV2.afterComplete.selector), "");
        ITMPCore.Award[] memory core = _acceptN(taskId, 2);
        vm.clearMockedCalls();
        vm.expectRevert(abi.encodeWithSelector(RemoteSponsoredTaskHookV2.VerdictCommitmentMismatch.selector, taskId));
        hook.finalizeSettlement(taskId, core);
        hook.finalizeSettlement(taskId, paid);
        assertEq(hook.outcome(taskId).rewardsRoot, _expectedRoot(taskId, ITMPCore.VerdictType.APPROVE, paid));
    }

    function test_Remote_PaidAwardsAboveMaxMarkUnsettleable() public {
        bytes32 taskId = _remoteTask();
        uint256 n = hook.MAX_AWARDS() + 1;
        _submit(taskId, n);
        ITMPCore.Award[] memory paid = new ITMPCore.Award[](n);
        for (uint256 i; i < n; ++i) {
            paid[i] = _award(_w(i), 1e6, uint16(i + 1));
        }
        transformer.setResult(paid, 0, false);
        _acceptN(taskId, 2);
        assertEq(uint8(hook.outcome(taskId).status), uint8(RemoteSponsoredTaskHookV2.HookStatus.AwardCountExceeded));
        assertEq(uint8(hook.reconcile(taskId)), uint8(RemoteSponsoredTaskHookV2.HookStatus.AwardCountExceeded));
    }
}
