// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { IFundingPoolManager } from "../src/interfaces/IFundingPoolManager.sol";
import { FundingPool } from "../src/FundingPool.sol";
import { ITMPFundingPool } from "../src/interfaces/ITMPFundingPool.sol";
import { TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev rev029: a project's owner changes hands in two steps, and its end date moves later.
///      Covers the two-step flow and each refusal, what moves in the pool (the owner's own backing
///      only), who acts for tasks created before the transfer, and every guarantee an extension
///      keeps for backers.
contract ProjectOwnerTest is DiamondTestHelper {
    ITMPDiamond internal market;
    ITMPProject internal projects;
    ITMPFundingPool internal pools;
    FundingPool internal mockPool;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal admin = address(0xA0);
    address internal owner = address(0xB0);
    address internal newOwner = address(0xB5);
    address internal operator = address(0xB1);
    address internal backer = address(0xD1);
    address internal stranger = address(0xC1);

    uint256 internal constant BUDGET = 10e6;
    uint256 internal constant REWARD = 2e6;
    uint64 internal endsAt;
    uint256 internal id;
    bytes32 internal poolId;

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
        endsAt = uint64(block.timestamp + 30 days);
        id = abi.decode(
            _relay(owner, BUDGET, abi.encodeCall(projects.createProject, (address(usdc), BUDGET, endsAt, 30 days))),
            (uint256)
        );
        poolId = projects.projectPoolId(id);
        // A backer funds 5e6 on top of the owner's 10e6.
        _relay(backer, 5e6, abi.encodeCall(projects.fund, (poolId, 5e6, address(0))));
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _propose(address from, address to) internal {
        _relay(from, 0, abi.encodeCall(projects.proposeProjectOwner, (id, to)));
    }

    function _accept(address who) internal {
        _relay(who, 0, abi.encodeCall(projects.acceptProjectOwner, (id)));
    }

    function _transfer(address to) internal {
        _propose(projects.getProject(id).owner, to);
        _accept(to);
    }

    function _extend(address who, uint64 to) internal {
        _relay(who, 0, abi.encodeCall(projects.extendProject, (id, to)));
    }

    function _ok(address who, bytes memory data) internal returns (bool ok) {
        try forwarder.relay(address(market), who, 0, data) {
            return true;
        } catch {
            return false;
        }
    }

    function _taskCall() internal view returns (bytes memory) {
        ITMPCore.TaskTerms memory t;
        t.version = 2;
        return abi.encodeCall(
            projects.createProjectTask,
            (
                id,
                taskConfig(REWARD, 7 days, TMP_BOUNTY),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                t,
                address(0)
            )
        );
    }

    function _task(address who) internal returns (bytes32) {
        return abi.decode(_relay(who, 0, _taskCall()), (bytes32));
    }

    function _cancel(address who, bytes32 taskId) internal returns (bool) {
        return _ok(who, abi.encodeCall(market.cancelTask, (taskId, 0)));
    }

    function _terms(bool ownerOverride) internal pure returns (ITMPProject.GrantTerms memory) {
        return ITMPProject.GrantTerms({
            cap: 0,
            requesterOfRecord: ITMPProject.RequesterOfRecord.Owner,
            ownerOverride: ownerOverride,
            revokeRemovesControl: true
        });
    }

    // ---------------------------------------------------------------------
    // Two-step owner transfer
    // ---------------------------------------------------------------------

    function test_Transfer_ProposeThenAcceptMovesTheOwner() public {
        vm.expectEmit(true, true, true, true, address(market));
        emit ITMPProject.ProjectOwnerProposed(id, owner, newOwner);
        _propose(owner, newOwner);
        assertEq(projects.pendingProjectOwner(id), newOwner);
        assertEq(projects.getProject(id).owner, owner, "nothing changes before accept");

        vm.expectEmit(true, true, true, true, address(market));
        emit ITMPProject.ProjectOwnerChanged(id, owner, newOwner, 10e6 * 1e12);
        _accept(newOwner);
        assertEq(projects.getProject(id).owner, newOwner);
        assertEq(projects.pendingProjectOwner(id), address(0), "pending cleared");
    }

    function test_Transfer_MovesOnlyTheOwnersBacking() public {
        ITMPFundingPool.PoolInfo memory before_ = pools.getPool(poolId);
        uint256 ownerShares = pools.sharesOf(poolId, owner);
        uint256 backerShares = pools.sharesOf(poolId, backer);
        assertGt(ownerShares, 0);
        assertGt(backerShares, 0);

        _transfer(newOwner);

        assertEq(pools.sharesOf(poolId, owner), 0, "previous owner holds none");
        assertEq(pools.sharesOf(poolId, newOwner), ownerShares, "new owner holds the owner's shares");
        assertEq(pools.sharesOf(poolId, backer), backerShares, "a backer's shares never move");
        ITMPFundingPool.PoolInfo memory after_ = pools.getPool(poolId);
        assertEq(after_.totalShares, before_.totalShares, "supply unchanged");
        assertEq(after_.available, before_.available, "value unchanged");
        assertEq(after_.funded, before_.funded, "funded unchanged");
    }

    function test_Transfer_PotGoesToTheNewOwnerAfterClose() public {
        _transfer(newOwner);
        vm.warp(endsAt);
        projects.closeProject(id); // anyone after the end date
        uint256 newClaim = pools.claimable(poolId, newOwner);
        assertEq(newClaim, 10e6, "the owner's two thirds");
        assertEq(pools.claimable(poolId, owner), 0, "previous owner has nothing");
        assertEq(pools.claimable(poolId, backer), 5e6, "backer's third");
        vm.expectRevert(ITMPFundingPool.NothingToClaim.selector);
        projects.claim(poolId, owner);
        assertEq(projects.claim(poolId, newOwner), 10e6);
        assertEq(usdc.balanceOf(newOwner), 10e6);
    }

    function test_Transfer_NewOwnerThatAlreadyBacksMergesShares() public {
        _relay(newOwner, 3e6, abi.encodeCall(projects.fund, (poolId, 3e6, address(0))));
        uint256 had = pools.sharesOf(poolId, newOwner);
        uint256 ownerShares = pools.sharesOf(poolId, owner);
        _transfer(newOwner);
        assertEq(pools.sharesOf(poolId, newOwner), had + ownerShares);
        vm.warp(endsAt);
        projects.closeProject(id);
        assertEq(pools.claimable(poolId, newOwner), 13e6);
    }

    function test_Transfer_PreviousOwnerLosesOwnerRights() public {
        _transfer(newOwner);
        assertFalse(_ok(owner, abi.encodeCall(projects.grantOperator, (id, operator, _terms(true)))));
        assertFalse(_ok(owner, abi.encodeCall(projects.closeProject, (id))));
        assertFalse(_ok(owner, abi.encodeCall(projects.proposeProjectOwner, (id, stranger))));
        assertFalse(_ok(owner, abi.encodeCall(projects.extendProject, (id, uint64(block.timestamp + 40 days)))));
        assertFalse(_ok(owner, _taskCall()), "cannot draw on the budget");
        assertTrue(_ok(newOwner, abi.encodeCall(projects.grantOperator, (id, operator, _terms(true)))));
        assertTrue(_ok(newOwner, _taskCall()), "the new owner draws on the budget");
    }

    function test_Transfer_CancelBeforeAcceptance() public {
        _propose(owner, newOwner);
        vm.expectEmit(true, true, true, true, address(market));
        emit ITMPProject.ProjectOwnerProposalCancelled(id, owner, newOwner);
        _relay(owner, 0, abi.encodeCall(projects.cancelProjectOwner, (id)));
        assertEq(projects.pendingProjectOwner(id), address(0));
        vm.expectRevert(ITMPProject.NoPendingProjectOwner.selector);
        _accept(newOwner);
        assertEq(projects.getProject(id).owner, owner);
    }

    function test_Transfer_CancelWithNothingPendingReverts() public {
        vm.expectRevert(ITMPProject.NoPendingProjectOwner.selector);
        _relay(owner, 0, abi.encodeCall(projects.cancelProjectOwner, (id)));
    }

    function test_Transfer_OnlyTheOwnerProposesOrCancels() public {
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        _propose(stranger, stranger);
        _propose(owner, newOwner);
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        _relay(stranger, 0, abi.encodeCall(projects.cancelProjectOwner, (id)));
        // The pending owner holds no owner right until it accepts.
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        _relay(newOwner, 0, abi.encodeCall(projects.cancelProjectOwner, (id)));
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        _propose(newOwner, stranger);
    }

    function test_Transfer_InvalidTargetsRevert() public {
        vm.expectRevert(ITMPProject.InvalidProjectOwner.selector);
        _propose(owner, address(0));
        vm.expectRevert(ITMPProject.InvalidProjectOwner.selector);
        _propose(owner, owner);
        vm.expectRevert(ITMPProject.InvalidProjectOwner.selector);
        _propose(owner, address(market));
        vm.expectRevert(ITMPProject.InvalidProjectOwner.selector);
        _propose(owner, address(mockPool));
    }

    function test_Transfer_UnknownProjectReverts() public {
        vm.expectRevert(ITMPProject.ProjectNotFound.selector);
        _relay(owner, 0, abi.encodeCall(projects.proposeProjectOwner, (99, newOwner)));
        vm.expectRevert(ITMPProject.ProjectNotFound.selector);
        _relay(owner, 0, abi.encodeCall(projects.acceptProjectOwner, (99)));
    }

    function test_Transfer_OnlyTheNamedAddressAccepts() public {
        _propose(owner, newOwner);
        // A front-runner, the previous owner and a bystander cannot take it.
        vm.expectRevert(ITMPProject.NotPendingProjectOwner.selector);
        _accept(stranger);
        vm.expectRevert(ITMPProject.NotPendingProjectOwner.selector);
        _accept(owner);
        assertEq(projects.getProject(id).owner, owner);
    }

    function test_Transfer_NewProposalReplacesTheOld() public {
        _propose(owner, newOwner);
        _propose(owner, stranger);
        vm.expectRevert(ITMPProject.NotPendingProjectOwner.selector);
        _accept(newOwner);
        _accept(stranger);
        assertEq(projects.getProject(id).owner, stranger);
    }

    function test_Transfer_AcceptedOnlyOnce() public {
        _transfer(newOwner);
        vm.expectRevert(ITMPProject.NoPendingProjectOwner.selector);
        _accept(newOwner);
    }

    function test_Transfer_RefusedOnAClosedProject() public {
        _relay(owner, 0, abi.encodeCall(projects.closeProject, (id)));
        vm.expectRevert(ITMPProject.ProjectNotOpen.selector);
        _propose(owner, newOwner);
    }

    function test_Transfer_RefusedOnceTheEndDatePassed() public {
        vm.warp(endsAt);
        vm.expectRevert(ITMPProject.ProjectNotOpen.selector);
        _propose(owner, newOwner);
    }

    function test_Transfer_AcceptRefusedAfterTheProjectClosed() public {
        _propose(owner, newOwner);
        _relay(owner, 0, abi.encodeCall(projects.closeProject, (id)));
        vm.expectRevert(ITMPProject.ProjectNotOpen.selector);
        _accept(newOwner);
        assertEq(pools.sharesOf(poolId, newOwner), 0, "no shares moved");
        // The owner can still clear the stale proposal.
        _relay(owner, 0, abi.encodeCall(projects.cancelProjectOwner, (id)));
        assertEq(projects.pendingProjectOwner(id), address(0));
    }

    function test_Transfer_AcceptRefusedAfterTheEndDate() public {
        _propose(owner, newOwner);
        vm.warp(endsAt);
        vm.expectRevert(ITMPProject.ProjectNotOpen.selector);
        _accept(newOwner);
    }

    function test_Transfer_NeedsAForwarderAndNoPayment() public {
        vm.prank(owner);
        vm.expectRevert();
        projects.proposeProjectOwner(id, newOwner);
        _propose(owner, newOwner);
        vm.prank(newOwner);
        vm.expectRevert();
        projects.acceptProjectOwner(id);
        vm.expectRevert();
        _relay(newOwner, 1, abi.encodeCall(projects.acceptProjectOwner, (id)));
        vm.expectRevert();
        _relay(owner, 1, abi.encodeCall(projects.proposeProjectOwner, (id, stranger)));
    }

    function test_Transfer_ToAContractIsAllowedButItMustAccept() public {
        address wallet = address(new MockUSDC()); // any address with code
        _propose(owner, wallet);
        assertEq(projects.getProject(id).owner, owner, "a contract that never accepts changes nothing");
        _accept(wallet);
        assertEq(projects.getProject(id).owner, wallet);
    }

    function test_Transfer_WhileTasksAreInFlight_NewOwnerActsForThem() public {
        bytes32 t = _task(owner);
        assertEq(market.getTask(t).requester, owner);
        _transfer(newOwner);
        assertEq(market.getTask(t).requester, owner, "the recorded requester is fixed per task");
        assertFalse(_cancel(owner, t), "the previous owner no longer acts for it");
        uint256 availableBefore = pools.getPool(poolId).available;
        assertTrue(_cancel(newOwner, t), "the current owner does");
        assertEq(pools.getPool(poolId).available, availableBefore + REWARD, "the refund returns to the pool");
        assertEq(usdc.balanceOf(owner), 0, "nothing was paid to the previous owner");
    }

    function test_Transfer_HookRolesFollowTheCurrentOwner() public {
        bytes32 t = _task(owner);
        uint32 requesterRole = 1 << 0;
        assertTrue(ITMPHooksV2(address(market)).taskCallerRoles(t, owner) & requesterRole != 0);
        _transfer(newOwner);
        assertTrue(ITMPHooksV2(address(market)).taskCallerRoles(t, owner) & requesterRole == 0);
        assertTrue(ITMPHooksV2(address(market)).taskCallerRoles(t, newOwner) & requesterRole != 0);
    }

    function test_Transfer_OperatorGrantsAndTasksFollowTheProject() public {
        _relay(owner, 0, abi.encodeCall(projects.grantOperator, (id, operator, _terms(true))));
        _relay(operator, 0, abi.encodeCall(projects.acceptGrant, (id, keccak256(abi.encode(_terms(true))))));
        bytes32 opTask = _task(operator);
        _transfer(newOwner);
        // The grant survives; the operator still spends and the new owner revokes and overrides.
        assertTrue(projects.getGrant(id, operator).accepted);
        assertTrue(_ok(operator, _taskCall()), "the operator keeps spending");
        assertTrue(_cancel(newOwner, opTask), "ownerOverride passes to the current owner");
        assertFalse(_cancel(owner, opTask), "and not to the previous one");
        assertTrue(_ok(newOwner, abi.encodeCall(projects.revokeOperator, (id, operator))));
    }

    function test_Transfer_NewOwnerHoldingALiveGrantHasItRevoked() public {
        ITMPProject.GrantTerms memory terms = _terms(false);
        _relay(owner, 0, abi.encodeCall(projects.grantOperator, (id, newOwner, terms)));
        _relay(newOwner, 0, abi.encodeCall(projects.acceptGrant, (id, keccak256(abi.encode(terms)))));
        bytes32 asOperator = _task(newOwner);
        uint256 committed = projects.getGrant(id, newOwner).committed;
        assertEq(committed, REWARD);

        _propose(owner, newOwner);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPProject.OperatorRevoked(id, newOwner);
        _accept(newOwner);

        ITMPProject.Grant memory g = projects.getGrant(id, newOwner);
        assertTrue(g.revoked, "the grant ended");
        assertEq(g.committed, committed, "what its tasks hold is still counted");
        assertTrue(_cancel(newOwner, asOperator), "and it still acts for them");
        assertEq(projects.getGrant(id, newOwner).committed, 0, "the refund gave the count back");
        assertTrue(_ok(newOwner, _taskCall()), "as owner it spends");
    }

    function test_Transfer_AGrantHeldByThePreviousOwnerIsNotInherited() public {
        // The previous owner may be made an operator by the new owner, under terms the new owner picks.
        _transfer(newOwner);
        ITMPProject.GrantTerms memory terms = _terms(true);
        _relay(newOwner, 0, abi.encodeCall(projects.grantOperator, (id, owner, terms)));
        assertFalse(_ok(owner, _taskCall()), "not accepted yet");
    }

    function test_Transfer_ChainsToASecondTransfer() public {
        _transfer(newOwner);
        _transfer(stranger);
        assertEq(projects.getProject(id).owner, stranger);
        assertEq(pools.sharesOf(poolId, newOwner), 0);
        assertGt(pools.sharesOf(poolId, stranger), 0);
    }

    function test_Transfer_NewOwnerPurchasesAfterTransferGetsFreshShares() public {
        _transfer(newOwner);
        uint256 backerShares = pools.sharesOf(poolId, backer);
        _relay(owner, 1e6, abi.encodeCall(projects.fund, (poolId, 1e6, address(0))));
        assertGt(pools.sharesOf(poolId, owner), 0, "the previous owner may back the project like anyone");
        assertEq(pools.sharesOf(poolId, backer), backerShares);
    }

    function test_Pool_ManagerFunctionsAreManagerOnly() public {
        vm.expectRevert(IFundingPoolManager.NotManager.selector);
        IFundingPoolManager(address(mockPool)).moveBacking(poolId, owner, stranger);
        vm.expectRevert(IFundingPoolManager.NotManager.selector);
        IFundingPoolManager(address(mockPool)).extendClosesAt(poolId, uint64(block.timestamp + 60 days));
        assertEq(IFundingPoolManager(address(mockPool)).fundingPoolRevision(), 29);
    }

    function test_Pool_MoveBackingRefusesInvalidTargets() public {
        vm.startPrank(address(market));
        vm.expectRevert(ITMPFundingPool.PoolInvalidBacker.selector);
        IFundingPoolManager(address(mockPool)).moveBacking(poolId, owner, owner);
        vm.expectRevert(ITMPFundingPool.PoolInvalidBacker.selector);
        IFundingPoolManager(address(mockPool)).moveBacking(poolId, owner, address(0));
        vm.expectRevert(ITMPFundingPool.PoolInvalidBacker.selector);
        IFundingPoolManager(address(mockPool)).moveBacking(poolId, owner, address(market));
        vm.expectRevert(ITMPFundingPool.PoolInvalidBacker.selector);
        IFundingPoolManager(address(mockPool)).moveBacking(poolId, owner, address(mockPool));
        // Nothing to move from an address with no backing.
        assertEq(IFundingPoolManager(address(mockPool)).moveBacking(poolId, stranger, newOwner), 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // End-date extension
    // ---------------------------------------------------------------------

    function test_Extend_MovesTheEndDateAndThePool() public {
        uint64 newEnd = endsAt + 60 days;
        vm.expectEmit(true, false, false, true, address(market));
        emit ITMPProject.ProjectEndExtended(id, endsAt, newEnd);
        _extend(owner, newEnd);
        assertEq(projects.getProject(id).endsAt, newEnd);
        assertEq(pools.getPool(poolId).closesAt, newEnd, "the pool's closing date moves with it");
        assertFalse(pools.getPool(poolId).settled);
    }

    function test_Extend_KeepsTheProjectOpenPastTheOldEnd() public {
        _extend(owner, endsAt + 60 days);
        vm.warp(endsAt + 1 days);
        assertFalse(pools.getPool(poolId).settled, "not settled at the old end date");
        assertTrue(_ok(owner, _taskCall()), "tasks can still be created");
        // Funding continues until the new date, at the pool's current value.
        _relay(backer, 1e6, abi.encodeCall(projects.fund, (poolId, 1e6, address(0))));
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        projects.closeProject(id); // a stranger cannot close early
    }

    function test_Extend_TaskGraceMovesWithTheEndDate() public {
        // A task expiring past old end + grace is refused before, allowed after.
        ITMPCore.TaskTerms memory t;
        t.version = 2;
        ITMPCore.TaskConfig memory cfg = taskConfig(REWARD, 62 days, TMP_BOUNTY);
        bytes memory call_ = abi.encodeCall(
            projects.createProjectTask,
            (
                id,
                cfg,
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                t,
                address(0)
            )
        );
        assertFalse(_ok(owner, call_));
        _extend(owner, endsAt + 30 days);
        assertTrue(_ok(owner, call_));
    }

    function test_Extend_DoesNotChangeSharesOrValue() public {
        ITMPFundingPool.PoolInfo memory before_ = pools.getPool(poolId);
        uint256 ownerShares = pools.sharesOf(poolId, owner);
        uint256 backerShares = pools.sharesOf(poolId, backer);
        _extend(owner, endsAt + 90 days);
        ITMPFundingPool.PoolInfo memory after_ = pools.getPool(poolId);
        assertEq(after_.totalShares, before_.totalShares);
        assertEq(after_.available, before_.available);
        assertEq(after_.outstanding, before_.outstanding);
        assertEq(after_.funded, before_.funded);
        assertEq(after_.generation, before_.generation);
        assertEq(pools.sharesOf(poolId, owner), ownerShares);
        assertEq(pools.sharesOf(poolId, backer), backerShares);
    }

    function test_Extend_BackersClaimAtTheNewEndDateNotBefore() public {
        uint64 newEnd = endsAt + 30 days;
        _extend(owner, newEnd);
        vm.warp(endsAt + 1);
        assertEq(pools.claimable(poolId, backer), 0, "nothing claimable at the old date");
        vm.warp(newEnd);
        projects.closeProject(id);
        assertEq(pools.claimable(poolId, backer), 5e6);
        assertEq(projects.claim(poolId, backer), 5e6);
    }

    function test_Extend_BackersCanStillBeSettledByAnEarlyClose() public {
        _extend(owner, endsAt + 300 days);
        // The owner's own right to close early is unchanged: the backers' pot opens at once.
        _relay(owner, 0, abi.encodeCall(projects.closeProject, (id)));
        assertEq(pools.claimable(poolId, backer), 5e6);
    }

    function test_Extend_RefusesAnEarlierOrEqualDate() public {
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.ProjectEndNotExtended.selector, endsAt, endsAt));
        _extend(owner, endsAt);
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.ProjectEndNotExtended.selector, endsAt, endsAt - 1));
        _extend(owner, endsAt - 1);
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.ProjectEndNotExtended.selector, endsAt, uint64(0)));
        _extend(owner, 0);
    }

    function test_Extend_BoundIsOneYearFromNow() public {
        uint64 limit = uint64(block.timestamp + 365 days);
        vm.expectRevert(ITMPProject.ProjectEndTooFar.selector);
        _extend(owner, limit + 1);
        _extend(owner, limit);
        assertEq(projects.getProject(id).endsAt, limit);
        // The bound moves with the clock, so a later extension can go further, never past a year from then.
        vm.warp(vm.getBlockTimestamp() + 100 days);
        uint256 nowTs = vm.getBlockTimestamp();
        vm.expectRevert(ITMPProject.ProjectEndTooFar.selector);
        _extend(owner, uint64(nowTs + 365 days + 1));
        _extend(owner, uint64(nowTs + 365 days));
    }

    function test_Extend_OnlyTheOwner() public {
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        _extend(stranger, endsAt + 1 days);
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        _extend(backer, endsAt + 1 days);
        vm.expectRevert(ITMPProject.ProjectNotFound.selector);
        _relay(owner, 0, abi.encodeCall(projects.extendProject, (99, endsAt + 1 days)));
    }

    function test_Extend_RefusedOnAClosedProject() public {
        _relay(owner, 0, abi.encodeCall(projects.closeProject, (id)));
        vm.expectRevert(ITMPProject.ProjectNotOpen.selector);
        _extend(owner, endsAt + 1 days);
    }

    function test_Extend_CannotReviveAProjectPastItsEnd() public {
        vm.warp(endsAt);
        vm.expectRevert(ITMPProject.ProjectNotOpen.selector);
        _extend(owner, endsAt + 10 days);
    }

    function test_Extend_NeedsAForwarderAndNoPayment() public {
        vm.prank(owner);
        vm.expectRevert();
        projects.extendProject(id, endsAt + 1 days);
        vm.expectRevert();
        _relay(owner, 1, abi.encodeCall(projects.extendProject, (id, endsAt + 1 days)));
    }

    function test_Extend_ByTheNewOwnerAfterATransfer() public {
        _transfer(newOwner);
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        _extend(owner, endsAt + 1 days);
        _extend(newOwner, endsAt + 1 days);
        assertEq(projects.getProject(id).endsAt, endsAt + 1 days);
    }

    function test_Extend_TwiceInARow() public {
        _extend(owner, endsAt + 10 days);
        _extend(owner, endsAt + 20 days);
        assertEq(pools.getPool(poolId).closesAt, endsAt + 20 days);
    }
}
