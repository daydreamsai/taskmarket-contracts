// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
import { TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { BaseTMPHookV2 } from "../src/hooks/base/BaseTMPHookV2.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { MockTaskHookV2 } from "./mocks/MockTaskHookV2.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev A V2 hook declaring only the observer bit, with its capabilities in code rather than
///      storage so it also answers through an EIP-7702 delegation.
contract ObserverOnlyHookV2 is BaseTMPHookV2 {
    constructor(address diamond_) BaseTMPHookV2(diamond_) { }

    function hookCapabilities() external pure override returns (uint32) {
        return uint32(1) << 25;
    }
}

/// @dev rev030: a changed hook cannot trap a Claim worker's stake, an EIP-7702 delegated account is
///      never a hook, a transforming hook cannot forfeit an approved worker's stake, and a task with
///      a transforming hook keeps a neutral appeal open.
contract Rev030HookSafetyTest is DiamondTestHelper {
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
    uint256 internal constant STAKE = 10e6;
    uint256 internal constant DURATION = 7 days;
    uint256 internal constant FEE_BPS = 500;
    bytes32 internal constant WORK = keccak256("work");

    uint32 internal constant BIT_SUBMIT = uint32(1) << 9;
    uint32 internal constant BIT_APPEAL = uint32(1) << 12;
    uint32 internal constant BIT_ACCEPT = uint32(1) << 13;
    uint32 internal constant BIT_OBSERVER = uint32(1) << 25;
    uint32 internal constant BIT_REALLOCATE = uint32(1) << 26;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, uint16(FEE_BPS));
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 100_000e6);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _evalCfg(address disputeResolver) internal view returns (ITMPCore.TaskEvaluatorConfig memory) {
        return ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: 0,
            evaluatorFeeBps: 0,
            evaluationWindow: uint32(2 days),
            appealWindow: uint32(1 days),
            disputeResolver: disputeResolver
        });
    }

    function _evalCfgNone() internal pure returns (ITMPCore.TaskEvaluatorConfig memory c) {
        return c;
    }

    function _createCall(address[] memory hooks, ITMPCore.TaskEvaluatorConfig memory cfg, ITMPCore.TaskTerms memory t)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            market.createTask,
            (
                taskConfig(REWARD, DURATION, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                cfg,
                t
            )
        );
    }

    function _create(address[] memory hooks, ITMPCore.TaskEvaluatorConfig memory cfg, ITMPCore.TaskTerms memory t)
        internal
        returns (bytes32)
    {
        return abi.decode(_relay(requester, REWARD, _createCall(hooks, cfg, t)), (bytes32));
    }

    function _one(address h) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = h;
    }

    function _two(address h0, address h1) internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = h0;
        a[1] = h1;
    }

    function _disallowed() internal pure returns (ITMPCore.TaskTerms memory t) {
        t = stakeTerms(true, 1000);
        t.releaseAllowed = ITMPCore.ReleaseAllowed.Disallowed;
    }

    function _award(uint256 amount) internal view returns (ITMPCore.Award[] memory awards) {
        awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: amount, rank: 1 });
    }

    function _transforming() internal returns (MockTaskHookV2) {
        return new MockTaskHookV2(address(market), BIT_ACCEPT | BIT_REALLOCATE);
    }

    function _assign(bytes32 taskId, address disputeResolver) internal view returns (bytes memory) {
        return abi.encodeCall(market.assignEvaluator, (taskId, evaluator, 0, 0, 2 days, 1 days, disputeResolver));
    }

    // -------------------------------------------------------------------------
    // A changed hook opens releaseClaim
    // -------------------------------------------------------------------------

    function test_ReleaseClaim_OpensWhenObserverHookCodeChanges() public {
        ObserverOnlyHookV2 hook = new ObserverOnlyHookV2(address(market));
        bytes32 id = _create(_one(address(hook)), _evalCfgNone(), _disallowed());
        _relay(worker, STAKE, abi.encodeCall(market.claimTask, (id, STAKE)));

        // An observer-only hook cannot veto delivery while its code is unchanged.
        vm.expectRevert(ITMPCore.ReleaseNotAllowed.selector);
        _relay(worker, 0, abi.encodeCall(market.releaseClaim, (id)));

        // The hook's code changes after the claim: its vetoable observer callback now blocks delivery.
        vm.etch(address(hook), address(usdc).code);
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookCodeChanged.selector, uint8(0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (id, WORK)));

        // So the worker may leave with the stake despite the Disallowed term.
        _relay(worker, 0, abi.encodeCall(market.releaseClaim, (id)));
        assertEq(usdc.balanceOf(worker), STAKE, "stake returned in full inside the grace period");
        assertEq(uint8(market.getTaskState(id)), uint8(ITMPCore.TaskStatus.Open), "task reopened");
    }

    function test_ReleaseClaim_DisallowedHonouredWhileHookCodeUnchanged() public {
        ObserverOnlyHookV2 hook = new ObserverOnlyHookV2(address(market));
        bytes32 id = _create(_one(address(hook)), _evalCfgNone(), _disallowed());
        _relay(worker, STAKE, abi.encodeCall(market.claimTask, (id, STAKE)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (id, WORK)));
        assertEq(market.getTask(id).deliverable, WORK, "delivery goes through");
    }

    // -------------------------------------------------------------------------
    // An EIP-7702 delegated account is never a hook
    // -------------------------------------------------------------------------

    function test_CreateTask_RefusesDelegatedAccountHook() public {
        ObserverOnlyHookV2 impl = new ObserverOnlyHookV2(address(market));
        (address eoa, uint256 pk) = makeAddrAndKey("delegated-hook");
        vm.signAndAttachDelegation(address(impl), pk);
        bytes memory data = _createCall(_one(eoa), _evalCfgNone(), _disallowed());
        assertEq(eoa.code.length, 23, "the account carries a delegation designator");
        assertEq(bytes3(eoa.code), bytes3(0xef0100), "designator prefix");
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookDelegatedAccount.selector, uint8(0)));
        _relay(requester, REWARD, data);
    }

    function test_CreateTask_RefusesEtchedDesignatorHook() public {
        ObserverOnlyHookV2 impl = new ObserverOnlyHookV2(address(market));
        address eoa = address(0xD7702);
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(impl)));
        address[] memory hooks = _two(address(new ObserverOnlyHookV2(address(market))), eoa);
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookDelegatedAccount.selector, uint8(1)));
        _relay(requester, REWARD, _createCall(hooks, _evalCfgNone(), _disallowed()));
    }

    function test_SetDefaultHooks_RefusesDelegatedAccount() public {
        ObserverOnlyHookV2 impl = new ObserverOnlyHookV2(address(market));
        address eoa = address(0xD7702);
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(impl)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookDelegatedAccount.selector, uint8(0)));
        ITMPHooksV2(address(market)).setDefaultHooksV2(_one(eoa));
    }

    // -------------------------------------------------------------------------
    // A transforming hook cannot forfeit an approved worker's stake
    // -------------------------------------------------------------------------

    function test_FinalizeVerdict_TransformZeroesApprove_ReturnsClaimStake() public {
        MockTaskHookV2 h = _transforming();
        bytes32 id = _create(_one(address(h)), _evalCfg(resolver), stakeTerms(false, 0));
        _relay(worker, STAKE, abi.encodeCall(market.claimTask, (id, STAKE)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (id, WORK)));
        _relay(
            evaluator,
            0,
            abi.encodeCall(market.evaluate, (id, ITMPCore.VerdictType.APPROVE, 900, 1000, bytes32(0), _award(REWARD)))
        );
        h.setResult(_award(0), 0, false);
        vm.warp(block.timestamp + 1 days);

        uint256 requesterBefore = usdc.balanceOf(requester);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.StakeReturned(id, worker, STAKE);
        market.finalizeVerdict(id);

        assertEq(usdc.balanceOf(worker), STAKE, "the evaluator approved: the stake comes back, no reward");
        assertEq(usdc.balanceOf(requester), requesterBefore + REWARD, "the zeroed reward goes back to the requester");
        assertEq(market.getTask(id).stakeAmount, 0, "stake settled exactly once");
        assertEq(usdc.balanceOf(address(market)), 0, "nothing left in escrow");
    }

    // -------------------------------------------------------------------------
    // A task with a transforming hook keeps a neutral appeal open
    // -------------------------------------------------------------------------

    function test_CreateTask_RefusesTransformingWithAppealHook() public {
        MockTaskHookV2 appealHook = new MockTaskHookV2(address(market), BIT_APPEAL);
        address[] memory hooks = _two(address(_transforming()), address(appealHook));
        vm.expectRevert(ITMPHooksV2.TransformingHookWithAppealHook.selector);
        _relay(requester, REWARD, _createCall(hooks, _evalCfg(resolver), stakeTerms(false, 0)));

        // The transforming hook itself may not declare the appeal bit either.
        MockTaskHookV2 both = new MockTaskHookV2(address(market), BIT_ACCEPT | BIT_REALLOCATE | BIT_APPEAL);
        vm.expectRevert(ITMPHooksV2.TransformingHookWithAppealHook.selector);
        _relay(requester, REWARD, _createCall(_one(address(both)), _evalCfgNone(), stakeTerms(false, 0)));
    }

    function test_CreateTask_AllowsAppealHookWithoutTransformingHook() public {
        MockTaskHookV2 appealHook = new MockTaskHookV2(address(market), BIT_APPEAL);
        _create(_one(address(appealHook)), _evalCfg(address(0)), stakeTerms(false, 0));
    }

    function test_CreateTask_RefusesTransformingWithEvaluatorWithoutResolver() public {
        bytes memory data = _createCall(_one(address(_transforming())), _evalCfg(address(0)), stakeTerms(false, 0));
        vm.expectRevert(ITMPHooksV2.TransformingHookNeedsDisputeResolver.selector);
        _relay(requester, REWARD, data);
    }

    function test_CreateTask_AllowsTransformingWithResolverOrWithoutEvaluator() public {
        _create(_one(address(_transforming())), _evalCfg(resolver), stakeTerms(false, 0));
        _create(_one(address(_transforming())), _evalCfgNone(), stakeTerms(false, 0));
    }

    function test_AssignEvaluator_RefusesNoResolverOnTransformingTask() public {
        bytes32 id = _create(_one(address(_transforming())), _evalCfgNone(), stakeTerms(false, 0));
        vm.expectRevert(ITMPHooksV2.TransformingHookNeedsDisputeResolver.selector);
        _relay(requester, 0, _assign(id, address(0)));

        _relay(requester, 0, _assign(id, resolver));
        assertEq(market.getTaskEvaluatorConfig(id).disputeResolver, resolver, "assigned with a resolver");
    }

    function test_AssignEvaluator_AllowsNoResolverWithoutTransformingHook() public {
        MockTaskHookV2 h = new MockTaskHookV2(address(market), BIT_ACCEPT);
        bytes32 id = _create(_one(address(h)), _evalCfgNone(), stakeTerms(false, 0));
        _relay(requester, 0, _assign(id, address(0)));
    }

    function test_CreateProjectTask_RefusesTransformingWithoutResolver() public {
        initMockPool(address(market), owner);
        ITMPProject projects = ITMPProject(address(market));
        uint256 projectId = abi.decode(
            _relay(
                requester,
                REWARD * 2,
                abi.encodeCall(
                    projects.createProject, (address(usdc), REWARD * 2, uint64(block.timestamp + 30 days), 30 days)
                )
            ),
            (uint256)
        );
        ITMPCore.TaskTerms memory t;
        t.version = 2;
        bytes memory noResolver = abi.encodeCall(
            projects.createProjectTask,
            (
                projectId,
                taskConfig(REWARD, DURATION, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: _one(address(_transforming())), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                _evalCfg(address(0)),
                t,
                address(0)
            )
        );
        vm.expectRevert(ITMPHooksV2.TransformingHookNeedsDisputeResolver.selector);
        _relay(requester, 0, noResolver);

        MockTaskHookV2 appealHook = new MockTaskHookV2(address(market), BIT_APPEAL);
        bytes memory withAppealHook = abi.encodeCall(
            projects.createProjectTask,
            (
                projectId,
                taskConfig(REWARD, DURATION, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: _two(address(_transforming()), address(appealHook)), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                _evalCfg(resolver),
                t,
                address(0)
            )
        );
        vm.expectRevert(ITMPHooksV2.TransformingHookWithAppealHook.selector);
        _relay(requester, 0, withAppealHook);
    }
}
