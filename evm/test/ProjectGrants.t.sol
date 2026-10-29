// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
import { FundingPool } from "../src/FundingPool.sol";
import { ITMPFundingPool } from "../src/interfaces/ITMPFundingPool.sol";
import { TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev rev027: operators spend a project's budget under grant terms the owner states and the
///      operator accepts. Covers each term, the rejections, the cap and its release by refunds, and
///      who may act on an operator's task under every override and revoke setting.
contract ProjectGrantsTest is DiamondTestHelper {
    ITMPDiamond internal market;
    ITMPProject internal projects;
    ITMPFundingPool internal pools;
    FundingPool internal mockPool;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal admin = address(0xA0);
    address internal owner = address(0xB0);
    address internal operator = address(0xB1);
    address internal otherOperator = address(0xB2);
    address internal stranger = address(0xC1);

    uint256 internal constant BUDGET = 10e6;
    uint256 internal constant REWARD = 2e6;
    uint256 internal constant CAP = 5e6;
    uint256 internal id;

    function setUp() public {
        vm.startPrank(admin);
        usdc = new MockUSDC();
        market = deployDiamond(admin, address(usdc), address(0xFEE), 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        projects = ITMPProject(address(market));
        mockPool = initMockPool(address(market), admin);
        pools = ITMPFundingPool(address(mockPool));
        usdc.mint(address(forwarder), 1_000e6);
        id = abi.decode(
            _relay(
                owner,
                BUDGET,
                abi.encodeCall(
                    projects.createProject, (address(usdc), BUDGET, uint64(block.timestamp + 30 days), 30 days)
                )
            ),
            (uint256)
        );
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _terms(uint256 cap, ITMPProject.RequesterOfRecord ror, bool ownerOverride, bool revokeRemovesControl)
        internal
        pure
        returns (ITMPProject.GrantTerms memory)
    {
        return ITMPProject.GrantTerms({
            cap: cap, requesterOfRecord: ror, ownerOverride: ownerOverride, revokeRemovesControl: revokeRemovesControl
        });
    }

    function _grant(address op, ITMPProject.GrantTerms memory t) internal {
        _relay(owner, 0, abi.encodeCall(projects.grantOperator, (id, op, t)));
    }

    function _accept(address op) internal {
        _relay(op, 0, abi.encodeCall(projects.acceptGrant, (id)));
    }

    function _grantAndAccept(address op, ITMPProject.GrantTerms memory t) internal {
        _grant(op, t);
        _accept(op);
    }

    function _taskCall(uint256 reward) internal view returns (bytes memory) {
        ITMPCore.TaskTerms memory t;
        t.version = 2;
        return abi.encodeCall(
            projects.createProjectTask,
            (
                id,
                taskConfig(reward, 7 days, TMP_BOUNTY),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                t,
                address(0)
            )
        );
    }

    function _opTask(address op, uint256 reward) internal returns (bytes32) {
        return abi.decode(_relay(op, 0, _taskCall(reward)), (bytes32));
    }

    function _cancel(address who, bytes32 taskId) internal returns (bool ok) {
        try forwarder.relay(address(market), who, 0, abi.encodeCall(market.cancelTask, (taskId, 0))) {
            return true;
        } catch {
            return false;
        }
    }

    function _wideOpen() internal pure returns (ITMPProject.GrantTerms memory) {
        return _terms(0, ITMPProject.RequesterOfRecord.Owner, true, true);
    }

    // -------------------------------------------------------------------------
    // Grant, accept, revoke
    // -------------------------------------------------------------------------

    function test_Grant_RecordsTheTermsUntilAccepted() public {
        _grant(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        ITMPProject.Grant memory g = projects.getGrant(id, operator);
        assertTrue(g.exists);
        assertFalse(g.accepted);
        assertEq(g.terms.cap, CAP);

        // The owner may edit the terms until the operator accepts.
        _grant(operator, _terms(CAP + 1, ITMPProject.RequesterOfRecord.Operator, false, false));
        g = projects.getGrant(id, operator);
        assertEq(g.terms.cap, CAP + 1);
        assertEq(uint8(g.terms.requesterOfRecord), uint8(ITMPProject.RequesterOfRecord.Operator));
        assertFalse(g.terms.ownerOverride);
    }

    function test_Accept_FreezesTheTerms() public {
        _grantAndAccept(operator, _wideOpen());
        assertTrue(projects.getGrant(id, operator).accepted);
        vm.expectRevert(ITMPProject.GrantAlreadyAccepted.selector);
        _relay(owner, 0, abi.encodeCall(projects.grantOperator, (id, operator, _wideOpen())));
    }

    function test_RevertWhen_Grant_NotOwner() public {
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        _relay(stranger, 0, abi.encodeCall(projects.grantOperator, (id, operator, _wideOpen())));
        // An operator cannot grant another operator.
        _grantAndAccept(operator, _wideOpen());
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        _relay(operator, 0, abi.encodeCall(projects.grantOperator, (id, otherOperator, _wideOpen())));
    }

    function test_RevertWhen_Grant_ToTheOwnerOrZero() public {
        vm.expectRevert(ITMPProject.InvalidOperator.selector);
        _relay(owner, 0, abi.encodeCall(projects.grantOperator, (id, owner, _wideOpen())));
        vm.expectRevert(ITMPProject.InvalidOperator.selector);
        _relay(owner, 0, abi.encodeCall(projects.grantOperator, (id, address(0), _wideOpen())));
    }

    function test_RevertWhen_Accept_NoGrantOrAlreadyAcceptedOrRevoked() public {
        vm.expectRevert(ITMPProject.GrantNotFound.selector);
        _relay(operator, 0, abi.encodeCall(projects.acceptGrant, (id)));

        _grantAndAccept(operator, _wideOpen());
        vm.expectRevert(ITMPProject.GrantAlreadyAccepted.selector);
        _relay(operator, 0, abi.encodeCall(projects.acceptGrant, (id)));

        _grant(otherOperator, _wideOpen());
        _relay(owner, 0, abi.encodeCall(projects.revokeOperator, (id, otherOperator)));
        vm.expectRevert(ITMPProject.GrantRevoked.selector);
        _relay(otherOperator, 0, abi.encodeCall(projects.acceptGrant, (id)));
    }

    function test_RevertWhen_Revoke_NotOwnerOrNoGrantOrTwice() public {
        _grantAndAccept(operator, _wideOpen());
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        _relay(operator, 0, abi.encodeCall(projects.revokeOperator, (id, operator)));
        vm.expectRevert(ITMPProject.GrantNotFound.selector);
        _relay(owner, 0, abi.encodeCall(projects.revokeOperator, (id, otherOperator)));

        _relay(owner, 0, abi.encodeCall(projects.revokeOperator, (id, operator)));
        assertTrue(projects.getGrant(id, operator).revoked);
        vm.expectRevert(ITMPProject.GrantRevoked.selector);
        _relay(owner, 0, abi.encodeCall(projects.revokeOperator, (id, operator)));
        vm.expectRevert(ITMPProject.GrantRevoked.selector);
        _relay(owner, 0, abi.encodeCall(projects.grantOperator, (id, operator, _wideOpen())));
    }

    // -------------------------------------------------------------------------
    // Spending
    // -------------------------------------------------------------------------

    function test_Operator_SpendsAfterAccepting() public {
        _grantAndAccept(operator, _wideOpen());
        bytes32 taskId = _opTask(operator, REWARD);
        assertEq(projects.taskOperator(taskId), operator);
        assertEq(projects.taskCreatedBy(taskId), operator);
        assertEq(projects.projectOf(taskId), id);
        assertEq(market.getTask(taskId).requester, owner, "owner is the requester of record by default");
        assertEq(projects.getProject(id).available, BUDGET - REWARD);
        assertEq(projects.getGrant(id, operator).committed, REWARD);
        assertEq(usdc.balanceOf(address(market)), market.totalLiabilities());
    }

    function test_Operator_AsRequesterOfRecord() public {
        _grantAndAccept(operator, _terms(0, ITMPProject.RequesterOfRecord.Operator, true, true));
        bytes32 taskId = _opTask(operator, REWARD);
        assertEq(market.getTask(taskId).requester, operator);
        assertEq(projects.taskOperator(taskId), operator);
    }

    function test_OwnerTask_HasNoOperator() public {
        _grantAndAccept(operator, _wideOpen());
        bytes32 taskId = abi.decode(_relay(owner, 0, _taskCall(REWARD)), (bytes32));
        assertEq(projects.taskOperator(taskId), address(0));
        assertEq(projects.taskCreatedBy(taskId), owner);
    }

    function test_RevertWhen_Operator_NotGrantedUnacceptedOrRevoked() public {
        vm.expectRevert(ITMPProject.NotProjectOperator.selector);
        _relay(stranger, 0, _taskCall(REWARD));

        _grant(operator, _wideOpen());
        vm.expectRevert(ITMPProject.GrantNotAccepted.selector);
        _relay(operator, 0, _taskCall(REWARD));

        _accept(operator);
        _relay(owner, 0, abi.encodeCall(projects.revokeOperator, (id, operator)));
        vm.expectRevert(ITMPProject.GrantRevoked.selector);
        _relay(operator, 0, _taskCall(REWARD));
    }

    function test_RevertWhen_Operator_PastItsCap() public {
        _grantAndAccept(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        _opTask(operator, 3e6);
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.OperatorCapExceeded.selector, 2e6, 3e6));
        _relay(operator, 0, _taskCall(3e6));
        _opTask(operator, 2e6);
        assertEq(projects.getGrant(id, operator).committed, CAP);
    }

    function test_Cap_IsReleasedByARefund() public {
        _grantAndAccept(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        bytes32 first = _opTask(operator, CAP);
        assertTrue(_cancel(operator, first));
        assertEq(projects.getGrant(id, operator).committed, 0);
        _opTask(operator, CAP);
        assertEq(projects.getProject(id).available, BUDGET - CAP);
    }

    /// @dev A reward increase or an evaluator stake on an operator's task is drawn from the pool
    ///      and counts toward the operator's cap, as creating the task did.
    function test_Operator_TopUps_CountTowardItsCap() public {
        _grantAndAccept(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        bytes32 taskId = _opTask(operator, 3e6);
        _relay(operator, 0, abi.encodeCall(market.updateTask, (taskId, 4e6, 0, 0, 0)));
        assertEq(projects.getGrant(id, operator).committed, 4e6);
        assertEq(projects.getProject(id).available, BUDGET - 4e6, "the increase came out of the pool");

        bytes memory raise = abi.encodeCall(market.updateTask, (taskId, 6e6, 0, 0, 0));
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.OperatorCapExceeded.selector, 1e6, 2e6));
        _relay(operator, 0, raise);
        bytes memory stake =
            abi.encodeCall(market.assignEvaluator, (taskId, address(0xE0), 2e6, 0, 3 days, 2 days, address(0xD0)));
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.OperatorCapExceeded.selector, 1e6, 2e6));
        _relay(operator, 0, stake);

        _relay(
            operator,
            0,
            abi.encodeCall(market.assignEvaluator, (taskId, address(0xE0), 1e6, 0, 3 days, 2 days, address(0xD0)))
        );
        assertEq(projects.getGrant(id, operator).committed, CAP);
        assertEq(projects.getProject(id).available, BUDGET - CAP);

        // Cancelling returns all of it to the pool and gives the cap back.
        assertTrue(_cancel(operator, taskId));
        assertEq(projects.getGrant(id, operator).committed, 0);
        assertEq(projects.getProject(id).available, BUDGET);
        assertEq(usdc.balanceOf(address(market)), market.totalLiabilities());
    }

    /// @dev The owner acting on an operator's task is not held to the operator's cap, but what it
    ///      adds still counts toward the operator's committed, so the task's refunds give back
    ///      exactly what was counted.
    function test_Owner_TopsUpAnOperatorsTask() public {
        _grantAndAccept(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        bytes32 taskId = _opTask(operator, 3e6);
        _relay(owner, 0, abi.encodeCall(market.updateTask, (taskId, 6e6, 0, 0, 0)));
        assertEq(projects.getGrant(id, operator).committed, 6e6);
        assertTrue(_cancel(owner, taskId));
        assertEq(projects.getGrant(id, operator).committed, 0);
        assertEq(projects.getProject(id).available, BUDGET);
    }

    /// @dev A revoked operator that keeps control of its tasks may finish them but spends no more.
    function test_RevertWhen_RevokedOperator_TopsUp() public {
        _grantAndAccept(operator, _terms(0, ITMPProject.RequesterOfRecord.Owner, false, false));
        bytes32 taskId = _opTask(operator, 3e6);
        _relay(owner, 0, abi.encodeCall(projects.revokeOperator, (id, operator)));
        bytes memory raise = abi.encodeCall(market.updateTask, (taskId, 4e6, 0, 0, 0));
        vm.expectRevert(ITMPProject.GrantRevoked.selector);
        _relay(operator, 0, raise);
        assertTrue(_cancel(operator, taskId), "the operator still finishes what it started");
    }

    function test_Caps_AreSeparatePerOperator() public {
        _grantAndAccept(operator, _terms(3e6, ITMPProject.RequesterOfRecord.Owner, true, true));
        _grantAndAccept(otherOperator, _terms(3e6, ITMPProject.RequesterOfRecord.Owner, true, true));
        _opTask(operator, 3e6);
        _opTask(otherOperator, 3e6);
        assertEq(projects.getProject(id).available, BUDGET - 6e6);
    }

    function test_RevertWhen_Operator_OverTheProjectBudgetEvenWithoutACap() public {
        _grantAndAccept(operator, _wideOpen());
        bytes memory data = _taskCall(BUDGET + 1);
        vm.expectRevert(abi.encodeWithSelector(ITMPFundingPool.PoolBalanceExceeded.selector, BUDGET, BUDGET + 1));
        _relay(operator, 0, data);
    }

    function test_RevertWhen_Operator_PastTheEndDate() public {
        _grantAndAccept(operator, _wideOpen());
        vm.warp(block.timestamp + 30 days);
        bytes memory data = _taskCall(REWARD);
        vm.expectRevert(ITMPProject.ProjectNotOpen.selector);
        _relay(operator, 0, data);
    }

    // -------------------------------------------------------------------------
    // Operators never reach the owner's functions
    // -------------------------------------------------------------------------

    /// @dev An operator may back the project like anyone else, but closing it early stays the owner's.
    function test_RevertWhen_Operator_ClosesTheProject() public {
        _grantAndAccept(operator, _wideOpen());
        _relay(operator, 1e6, abi.encodeCall(pools.fund, (projects.projectPoolId(id), 1e6, address(0))));
        uint256 shares = pools.sharesOf(projects.projectPoolId(id), operator);
        assertGt(shares, 0, "the operator backed the project");
        vm.prank(operator);
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        projects.closeProject(id);
        assertFalse(projects.getProject(id).closed);
    }

    // -------------------------------------------------------------------------
    // Who may act on an operator's task: every override and revoke setting
    // -------------------------------------------------------------------------

    /// @dev Cancels an operator's task as `who` and returns whether the requester guard let them.
    function _canAct(address who, bytes32 taskId) internal returns (bool) {
        uint256 snap = vm.snapshotState();
        bool ok = _cancel(who, taskId);
        vm.revertToState(snap);
        return ok;
    }

    function _matrix(ITMPProject.RequesterOfRecord ror, bool ownerOverride, bool revokeRemoves)
        internal
        returns (bytes32 taskId)
    {
        _grantAndAccept(operator, _terms(0, ror, ownerOverride, revokeRemoves));
        taskId = _opTask(operator, REWARD);
    }

    function test_Control_OwnerIsRequester_OverrideOn() public {
        bytes32 t = _matrix(ITMPProject.RequesterOfRecord.Owner, true, true);
        assertTrue(_canAct(owner, t));
        assertTrue(_canAct(operator, t));
        assertFalse(_canAct(stranger, t));
    }

    function test_Control_OwnerIsRequester_OverrideOff_BlocksTheOwner() public {
        bytes32 t = _matrix(ITMPProject.RequesterOfRecord.Owner, false, true);
        assertFalse(_canAct(owner, t));
        assertTrue(_canAct(operator, t));
    }

    function test_Control_OperatorIsRequester_OverrideOn() public {
        bytes32 t = _matrix(ITMPProject.RequesterOfRecord.Operator, true, true);
        assertTrue(_canAct(owner, t));
        assertTrue(_canAct(operator, t));
        assertFalse(_canAct(stranger, t));
    }

    function test_Control_OperatorIsRequester_OverrideOff_BlocksTheOwner() public {
        bytes32 t = _matrix(ITMPProject.RequesterOfRecord.Operator, false, true);
        assertFalse(_canAct(owner, t));
        assertTrue(_canAct(operator, t));
    }

    function test_Revoke_RemovesControl_PassesTheTaskToTheOwner() public {
        ITMPProject.RequesterOfRecord[2] memory rors =
            [ITMPProject.RequesterOfRecord.Owner, ITMPProject.RequesterOfRecord.Operator];
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            // Override off, so only the revoke can hand the owner control.
            bytes32 t = _matrix(rors[i], false, true);
            assertFalse(_canAct(owner, t));
            _relay(owner, 0, abi.encodeCall(projects.revokeOperator, (id, operator)));
            assertTrue(_canAct(owner, t), "owner takes control");
            assertFalse(_canAct(operator, t), "operator loses control");
            vm.revertToState(snap);
        }
    }

    function test_Revoke_KeepsControl_OperatorFinishesWhatItStarted() public {
        ITMPProject.RequesterOfRecord[2] memory rors =
            [ITMPProject.RequesterOfRecord.Owner, ITMPProject.RequesterOfRecord.Operator];
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            bytes32 t = _matrix(rors[i], false, false);
            _relay(owner, 0, abi.encodeCall(projects.revokeOperator, (id, operator)));
            assertTrue(_canAct(operator, t), "operator keeps control");
            assertFalse(_canAct(owner, t), "owner still blocked by the override setting");
            vm.revertToState(snap);
        }
    }

    function test_Revoke_KeepsControl_OverrideOn_BothAct() public {
        bytes32 t = _matrix(ITMPProject.RequesterOfRecord.Operator, true, false);
        _relay(owner, 0, abi.encodeCall(projects.revokeOperator, (id, operator)));
        assertTrue(_canAct(owner, t));
        assertTrue(_canAct(operator, t));
    }

    function test_RevokedOperator_RefundsStillGoToTheProject() public {
        bytes32 t = _matrix(ITMPProject.RequesterOfRecord.Owner, true, false);
        _relay(owner, 0, abi.encodeCall(projects.revokeOperator, (id, operator)));
        assertTrue(_cancel(operator, t));
        assertEq(projects.getProject(id).available, BUDGET);
        assertEq(usdc.balanceOf(operator), 0);
    }

    function test_OwnerTask_IsUnaffectedByGrants() public {
        _grantAndAccept(operator, _terms(0, ITMPProject.RequesterOfRecord.Owner, false, true));
        bytes32 t = abi.decode(_relay(owner, 0, _taskCall(REWARD)), (bytes32));
        assertTrue(_canAct(owner, t));
        assertFalse(_canAct(operator, t), "an operator never acts on the owner's task");
    }

    function test_DirectCalls_AreRefused() public {
        vm.prank(owner);
        vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
        market.cancelTask(bytes32(0), 0);
    }
}
