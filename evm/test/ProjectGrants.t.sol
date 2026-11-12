// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { BaseTMPHookV2 } from "../src/hooks/base/BaseTMPHookV2.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { FundingPool } from "../src/FundingPool.sol";
import { ITMPFundingPool } from "../src/interfaces/ITMPFundingPool.sol";
import { TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev Records who the Diamond reports as a task's creator at the moment checkFund runs.
contract CreatorProbeHook is BaseTMPHookV2 {
    mapping(bytes32 taskId => address creator) public seenCreator;

    constructor(address diamond_) BaseTMPHookV2(diamond_) { }

    function hookCapabilities() external pure override returns (uint32) {
        return 1; // beforeCreate
    }

    function beforeCreate(bytes32 taskId, TaskContextV2 calldata, bytes calldata, bytes calldata)
        external
        override
        onlyDiamond
        returns (bytes4)
    {
        seenCreator[taskId] = ITMPProject(diamond).taskCreatedBy(taskId);
        return this.beforeCreate.selector;
    }
}

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
        _relay(op, 0, abi.encodeCall(projects.acceptGrant, (id, _storedTermsHash(op))));
    }

    function _storedTermsHash(address op) internal view returns (bytes32) {
        return keccak256(abi.encode(projects.getGrant(id, op).terms));
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

    // -------------------------------------------------------------------------
    // Caller roles (rev028 callTaskHook): Project
    // -------------------------------------------------------------------------

    function _roles(bytes32 taskId, address who) internal view returns (uint32) {
        return ITMPHooksV2(address(market)).taskCallerRoles(taskId, who);
    }

    function test_CallerRolesOnProjectTasks() public {
        uint32 requesterRole = 1 << 0;
        uint32 projectRole = 1 << 1;
        uint32 strangerRole = uint32(1) << 31;
        _grantAndAccept(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Operator, true, true));
        bytes32 ownerTask = _opTask(owner, REWARD);
        bytes32 opTask = _opTask(operator, REWARD);

        assertEq(_roles(ownerTask, owner), requesterRole | projectRole, "owner on its own task");
        assertEq(_roles(ownerTask, operator), projectRole, "granted operator on the owner's task");
        assertEq(_roles(opTask, operator), requesterRole | projectRole, "operator of record");
        assertEq(_roles(opTask, owner), projectRole, "owner on the operator's task");
        assertEq(_roles(ownerTask, stranger), strangerRole);

        // A granted operator that has not accepted holds no project role.
        _grant(otherOperator, _wideOpen());
        assertEq(_roles(ownerTask, otherOperator), strangerRole, "unaccepted grant");

        // Revoked with revokeRemovesControl (rev030): no longer a project operator, and no role on
        // its own task either, though it is still the creator and the requester of record.
        _relay(owner, 0, abi.encodeCall(projects.revokeOperator, (id, operator)));
        assertEq(_roles(ownerTask, operator), strangerRole, "revoked operator");
        assertEq(market.getTask(opTask).requester, operator, "still the requester of record");
        assertEq(_roles(opTask, operator), strangerRole, "creator whose control was removed");
        assertEq(_roles(opTask, owner), projectRole, "the owner keeps the project role");
    }

    /// @dev Rev030: the creating operator's roles on its task follow LibProject.mayAct in every
    ///      combination of requester of record, override and revoke setting.
    function test_CallerRoles_CreatorFollowsMayAct() public {
        uint32 requesterRole = 1 << 0;
        uint32 projectRole = 1 << 1;
        uint32 strangerRole = uint32(1) << 31;
        ITMPProject.RequesterOfRecord[2] memory rors =
            [ITMPProject.RequesterOfRecord.Owner, ITMPProject.RequesterOfRecord.Operator];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 2; ++j) {
                uint256 snap = vm.snapshotState();
                bool removes = j == 0;
                bool ofRecord = rors[i] == ITMPProject.RequesterOfRecord.Operator;
                bytes32 t = _matrix(rors[i], false, removes);
                _relay(owner, 0, abi.encodeCall(projects.revokeOperator, (id, operator)));
                bool acts = _canAct(operator, t);
                assertEq(acts, !removes, "mayAct: only revokeRemovesControl takes control away");
                uint32 expected = acts ? projectRole | (ofRecord ? requesterRole : 0) : strangerRole;
                assertEq(_roles(t, operator), expected, "the creator's roles follow its control");
                // The owner always holds the project role; as requester of record it holds the
                // requester role only once it may act (here, with override off, after a removing revoke).
                uint32 ownerExpected = projectRole | (!ofRecord && removes ? requesterRole : 0);
                assertEq(_roles(t, owner), ownerExpected, "the owner's roles follow its control");
                vm.revertToState(snap);
            }
        }
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
        _relay(operator, 0, abi.encodeCall(projects.acceptGrant, (id, bytes32(0))));

        _grantAndAccept(operator, _wideOpen());
        bytes32 acceptedHash = _storedTermsHash(operator);
        vm.expectRevert(ITMPProject.GrantAlreadyAccepted.selector);
        _relay(operator, 0, abi.encodeCall(projects.acceptGrant, (id, acceptedHash)));

        _grant(otherOperator, _wideOpen());
        _relay(owner, 0, abi.encodeCall(projects.revokeOperator, (id, otherOperator)));
        vm.expectRevert(ITMPProject.GrantRevoked.selector);
        _relay(otherOperator, 0, abi.encodeCall(projects.acceptGrant, (id, bytes32(0))));
    }

    /// @dev The owner swaps the terms after the operator read them; accepting the old hash reverts
    ///      and the operator can accept only the terms it now sees.
    function test_RevertWhen_Accept_TermsSwappedAfterOperatorReadThem() public {
        ITMPProject.GrantTerms memory reviewed = _terms(1e6, ITMPProject.RequesterOfRecord.Owner, false, false);
        _grant(operator, reviewed);
        bytes32 reviewedHash = keccak256(abi.encode(reviewed));

        ITMPProject.GrantTerms memory swapped = _terms(0, ITMPProject.RequesterOfRecord.Operator, true, true);
        _grant(operator, swapped);

        vm.expectRevert(
            abi.encodeWithSelector(
                ITMPProject.GrantTermsMismatch.selector, keccak256(abi.encode(swapped)), reviewedHash
            )
        );
        _relay(operator, 0, abi.encodeCall(projects.acceptGrant, (id, reviewedHash)));
        assertFalse(projects.getGrant(id, operator).accepted);

        _relay(operator, 0, abi.encodeCall(projects.acceptGrant, (id, keccak256(abi.encode(swapped)))));
        assertTrue(projects.getGrant(id, operator).accepted);
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
        // rev029: a revoked grant can be granted again; see the re-grant tests below.
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

    /// Rev028: a checkFund hook must be able to see who actually created a project task while the
    /// task is being created, since the requester of record is the owner by default and a
    /// sponsorship hook charges the creator's allowance, not the owner's.
    function test_CheckFundHook_SeesTheCreatorNotTheRequesterOfRecord() public {
        _grantAndAccept(operator, _wideOpen());
        CreatorProbeHook probe = new CreatorProbeHook(address(market));

        bytes32 operatorTask = abi.decode(_relay(operator, 0, _taskCallWithHook(REWARD, address(probe))), (bytes32));
        assertEq(market.getTask(operatorTask).requester, owner);
        assertEq(probe.seenCreator(operatorTask), operator, "hook saw the operator, not the owner");

        bytes32 ownerTask = abi.decode(_relay(owner, 0, _taskCallWithHook(REWARD, address(probe))), (bytes32));
        assertEq(probe.seenCreator(ownerTask), owner);
    }

    function _taskCallWithHook(uint256 reward, address hook) internal view returns (bytes memory) {
        ITMPCore.TaskTerms memory t;
        t.version = 2;
        address[] memory hooks = new address[](1);
        hooks[0] = hook;
        return abi.encodeCall(
            projects.createProjectTask,
            (
                id,
                taskConfig(reward, 7 days, TMP_BOUNTY),
                ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                t,
                address(0)
            )
        );
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

    // -------------------------------------------------------------------------
    // rev029: re-grant after revoke, raise the cap in place
    // -------------------------------------------------------------------------

    function _revoke(address op) internal {
        _relay(owner, 0, abi.encodeCall(projects.revokeOperator, (id, op)));
    }

    function _raise(address who, address op, uint256 newCap) internal {
        _relay(who, 0, abi.encodeCall(projects.raiseGrantCap, (id, op, newCap)));
    }

    function test_Regrant_AfterRevoke_ResetsToPendingWithNewTerms() public {
        _grantAndAccept(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        _revoke(operator);
        assertTrue(projects.getGrant(id, operator).revoked);

        ITMPProject.GrantTerms memory fresh = _terms(CAP * 2, ITMPProject.RequesterOfRecord.Operator, false, false);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPProject.OperatorGranted(id, operator, fresh);
        _grant(operator, fresh);

        ITMPProject.Grant memory g = projects.getGrant(id, operator);
        assertTrue(g.exists);
        assertFalse(g.revoked, "revoked cleared");
        assertFalse(g.accepted, "back to pending");
        assertEq(g.terms.cap, CAP * 2);
        assertEq(uint8(g.terms.requesterOfRecord), uint8(ITMPProject.RequesterOfRecord.Operator));
        assertFalse(g.terms.ownerOverride);
        assertFalse(g.terms.revokeRemovesControl);
    }

    function test_Regrant_RevokedPendingGrantCanAlsoBeGrantedAgain() public {
        _grant(operator, _wideOpen());
        _revoke(operator);
        _grant(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        assertFalse(projects.getGrant(id, operator).revoked);
        assertEq(projects.getGrant(id, operator).terms.cap, CAP);
    }

    function test_Regrant_PendingOperatorCannotSpendUntilItAccepts() public {
        _grantAndAccept(operator, _wideOpen());
        _revoke(operator);
        _grant(operator, _wideOpen());
        vm.expectRevert(ITMPProject.GrantNotAccepted.selector);
        _relay(operator, 0, _taskCall(REWARD));
    }

    function test_Regrant_OperatorAcceptsAndSpendsAgain() public {
        _grantAndAccept(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        _opTask(operator, REWARD);
        _revoke(operator);
        vm.expectRevert(ITMPProject.GrantRevoked.selector);
        _relay(operator, 0, _taskCall(REWARD));

        ITMPProject.GrantTerms memory fresh = _terms(CAP + 1e6, ITMPProject.RequesterOfRecord.Operator, true, true);
        _grant(operator, fresh);
        // The operator can only accept the terms it reviewed.
        vm.expectRevert(
            abi.encodeWithSelector(
                ITMPProject.GrantTermsMismatch.selector, keccak256(abi.encode(fresh)), bytes32(uint256(1))
            )
        );
        _relay(operator, 0, abi.encodeCall(projects.acceptGrant, (id, bytes32(uint256(1)))));

        vm.expectEmit(true, true, false, false, address(market));
        emit ITMPProject.GrantAccepted(id, operator);
        _relay(operator, 0, abi.encodeCall(projects.acceptGrant, (id, keccak256(abi.encode(fresh)))));
        assertTrue(projects.getGrant(id, operator).accepted);

        bytes32 taskId = _opTask(operator, REWARD);
        assertEq(market.getTask(taskId).requester, operator, "new requester of record applies to new tasks");
        assertEq(projects.getGrant(id, operator).committed, 2 * REWARD);
    }

    function test_Regrant_CommittedCarriesOverAndStillBoundsTotalSpend() public {
        _grantAndAccept(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        _opTask(operator, 3e6);
        _revoke(operator);
        assertEq(projects.getGrant(id, operator).committed, 3e6);

        _grant(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        assertEq(projects.getGrant(id, operator).committed, 3e6, "committed is not reset");
        _accept(operator);

        // Only the cap's headroom beyond what is still committed can be spent.
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.OperatorCapExceeded.selector, 2e6, 3e6));
        _relay(operator, 0, _taskCall(3e6));
        _opTask(operator, 2e6);
        assertEq(projects.getGrant(id, operator).committed, CAP);
    }

    function test_Regrant_RefundOfAnOldTaskFreesTheCarriedCommitted() public {
        bytes32 old = _matrix(ITMPProject.RequesterOfRecord.Owner, true, true);
        assertEq(projects.getGrant(id, operator).committed, REWARD);
        _revoke(operator);
        _grant(operator, _terms(REWARD, ITMPProject.RequesterOfRecord.Owner, true, true));
        _accept(operator);
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.OperatorCapExceeded.selector, 0, REWARD));
        _relay(operator, 0, _taskCall(REWARD));

        assertTrue(_cancel(owner, old));
        assertEq(projects.getGrant(id, operator).committed, 0, "the old task's refund freed its draw");
        _opTask(operator, REWARD);
    }

    function test_RevertWhen_Regrant_CapBelowCommitted() public {
        _grantAndAccept(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        _opTask(operator, 3e6);
        _revoke(operator);
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantCapBelowCommitted.selector, 3e6 - 1, 3e6));
        _relay(
            owner,
            0,
            abi.encodeCall(
                projects.grantOperator, (id, operator, _terms(3e6 - 1, ITMPProject.RequesterOfRecord.Owner, true, true))
            )
        );
        // Equal to committed is allowed (no headroom); so is zero (no cap beyond the budget).
        _grant(operator, _terms(3e6, ITMPProject.RequesterOfRecord.Owner, true, true));
        _grant(operator, _terms(0, ITMPProject.RequesterOfRecord.Owner, true, true));
    }

    function test_RevertWhen_Regrant_NotOwnerOrStillAccepted() public {
        _grantAndAccept(operator, _wideOpen());
        // Not revoked and accepted: still frozen.
        vm.expectRevert(ITMPProject.GrantAlreadyAccepted.selector);
        _relay(owner, 0, abi.encodeCall(projects.grantOperator, (id, operator, _wideOpen())));
        _revoke(operator);
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        _relay(stranger, 0, abi.encodeCall(projects.grantOperator, (id, operator, _wideOpen())));
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        _relay(operator, 0, abi.encodeCall(projects.grantOperator, (id, operator, _wideOpen())));
        // Granted again and accepted, it is frozen again.
        _grantAndAccept(operator, _wideOpen());
        vm.expectRevert(ITMPProject.GrantAlreadyAccepted.selector);
        _relay(owner, 0, abi.encodeCall(projects.grantOperator, (id, operator, _wideOpen())));
    }

    function test_Regrant_CanBeRevokedAgain() public {
        _grantAndAccept(operator, _wideOpen());
        _revoke(operator);
        _grantAndAccept(operator, _wideOpen());
        _revoke(operator);
        assertTrue(projects.getGrant(id, operator).revoked);
        vm.expectRevert(ITMPProject.GrantRevoked.selector);
        _relay(owner, 0, abi.encodeCall(projects.revokeOperator, (id, operator)));
    }

    function test_Regrant_RevokeStillRemovesControlAfterTheSecondRevoke() public {
        bytes32 t = _matrix(ITMPProject.RequesterOfRecord.Owner, false, true);
        _revoke(operator);
        _grant(operator, _terms(0, ITMPProject.RequesterOfRecord.Owner, false, true));
        _accept(operator);
        _revoke(operator);
        assertTrue(_canAct(owner, t), "owner takes control");
        assertFalse(_canAct(operator, t), "operator loses control");
    }

    function test_Regrant_OwnerOverrideAndRequesterOfRecordFollowTheNewTerms() public {
        _grantAndAccept(operator, _terms(0, ITMPProject.RequesterOfRecord.Owner, true, true));
        _revoke(operator);
        _grantAndAccept(operator, _terms(0, ITMPProject.RequesterOfRecord.Operator, false, true));
        bytes32 t = _opTask(operator, REWARD);
        assertEq(market.getTask(t).requester, operator);
        assertTrue(_canAct(operator, t));
        assertFalse(_canAct(owner, t), "override is off in the new terms");
    }

    function test_Regrant_ExistingTasksFollowTheGrantsCurrentState() public {
        // The operator's control of a task it created follows its grant: a revoke with
        // revokeRemovesControl passes it to the owner, and a re-grant, which clears the revoke,
        // returns it to the operator.
        bytes32 t = _matrix(ITMPProject.RequesterOfRecord.Owner, false, true);
        _revoke(operator);
        assertFalse(_canAct(operator, t));
        _grant(operator, _terms(0, ITMPProject.RequesterOfRecord.Owner, false, true));
        assertTrue(_canAct(operator, t), "the grant is live again");
        assertFalse(_canAct(owner, t), "override off");
    }

    function test_Regrant_NewOperatorTasksStillRefundToTheProject() public {
        _grantAndAccept(operator, _wideOpen());
        _revoke(operator);
        _grantAndAccept(operator, _wideOpen());
        bytes32 t = _opTask(operator, REWARD);
        assertTrue(_cancel(operator, t));
        assertEq(projects.getProject(id).available, BUDGET);
        assertEq(usdc.balanceOf(operator), 0);
    }

    function test_RaiseCap_Accepted() public {
        _grantAndAccept(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        _opTask(operator, CAP);
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.OperatorCapExceeded.selector, 0, 1e6));
        _relay(operator, 0, _taskCall(1e6));

        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPProject.GrantCapRaised(id, operator, CAP, CAP + 3e6);
        _raise(owner, operator, CAP + 3e6);

        ITMPProject.Grant memory g = projects.getGrant(id, operator);
        assertEq(g.terms.cap, CAP + 3e6);
        assertTrue(g.accepted, "still accepted: no second accept needed");
        assertEq(g.committed, CAP, "committed untouched");
        assertTrue(uint8(g.terms.requesterOfRecord) == 0 && g.terms.ownerOverride && g.terms.revokeRemovesControl);
        _opTask(operator, 3e6);
    }

    function test_RaiseCap_Pending_ChangesTheTermsHashTheOperatorMustAccept() public {
        ITMPProject.GrantTerms memory reviewed = _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true);
        _grant(operator, reviewed);
        bytes32 reviewedHash = keccak256(abi.encode(reviewed));
        _raise(owner, operator, CAP + 1);
        assertFalse(projects.getGrant(id, operator).accepted);
        assertEq(projects.getGrant(id, operator).terms.cap, CAP + 1);

        vm.expectRevert(
            abi.encodeWithSelector(ITMPProject.GrantTermsMismatch.selector, _storedTermsHash(operator), reviewedHash)
        );
        _relay(operator, 0, abi.encodeCall(projects.acceptGrant, (id, reviewedHash)));
        _accept(operator);
        assertTrue(projects.getGrant(id, operator).accepted);
    }

    function test_RaiseCap_AfterRegrant() public {
        _grantAndAccept(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        _revoke(operator);
        _grant(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        _accept(operator);
        _raise(owner, operator, CAP * 2);
        assertEq(projects.getGrant(id, operator).terms.cap, CAP * 2);
    }

    function test_RevertWhen_RaiseCap_NotOwner() public {
        _grantAndAccept(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        _raise(stranger, operator, CAP + 1);
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        _raise(operator, operator, CAP + 1);
        assertEq(projects.getGrant(id, operator).terms.cap, CAP);
    }

    function test_RevertWhen_RaiseCap_LoweredOrEqual() public {
        _grantAndAccept(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantCapNotRaised.selector, CAP, CAP - 1));
        _raise(owner, operator, CAP - 1);
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantCapNotRaised.selector, CAP, CAP));
        _raise(owner, operator, CAP);
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantCapNotRaised.selector, CAP, 0));
        _raise(owner, operator, 0);
        assertEq(projects.getGrant(id, operator).terms.cap, CAP);
    }

    function test_RevertWhen_RaiseCap_FromNoCap() public {
        _grantAndAccept(operator, _wideOpen());
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantCapNotRaised.selector, 0, 5e6));
        _raise(owner, operator, 5e6);
    }

    function test_RevertWhen_RaiseCap_RevokedOrMissing() public {
        _grantAndAccept(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        vm.expectRevert(ITMPProject.GrantNotFound.selector);
        _raise(owner, otherOperator, CAP + 1);
        _revoke(operator);
        vm.expectRevert(ITMPProject.GrantRevoked.selector);
        _raise(owner, operator, CAP + 1);
        // A revoked pending grant is refused the same way.
        _grant(otherOperator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        _revoke(otherOperator);
        vm.expectRevert(ITMPProject.GrantRevoked.selector);
        _raise(owner, otherOperator, CAP + 1);
    }

    function test_RevertWhen_RaiseCap_DirectCallOrUnknownProject() public {
        _grantAndAccept(operator, _terms(CAP, ITMPProject.RequesterOfRecord.Owner, true, true));
        vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
        vm.prank(owner);
        projects.raiseGrantCap(id, operator, CAP + 1);
        vm.expectRevert(ITMPProject.ProjectNotFound.selector);
        _relay(owner, 0, abi.encodeCall(projects.raiseGrantCap, (id + 99, operator, CAP + 1)));
    }

    function test_DirectCalls_AreRefused() public {
        vm.prank(owner);
        vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
        market.cancelTask(bytes32(0), 0);
    }
}
