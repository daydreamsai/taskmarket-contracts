// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPTerms } from "../src/interfaces/ITMPTerms.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { TMP_CLAIM, TMP_PITCH, TMP_AUCTION, TMP_AUCTION_DUTCH, TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { LibAppStorage, AppStorage } from "../src/libraries/LibAppStorage.sol";
import { LibTerms } from "../src/libraries/LibTerms.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev Cut into the test diamond to reach storage no facet exposes: it reconstructs a pre-rev025
///      task by clearing its terms, drives the terms reader, and reads the clocks and raw slots.
contract TermsProbeFacet {
    function probeWipeTerms(bytes32 taskId) external {
        delete LibAppStorage.appStorage().taskTerms[taskId];
    }

    function probeWipeClock(bytes32 taskId) external {
        delete LibAppStorage.appStorage().taskClocks[taskId];
    }

    function probeSetClock(bytes32 taskId, uint64 deliveredAt, uint64 revisionDueAt) external {
        ITMPCore.TaskClock storage c = LibAppStorage.appStorage().taskClocks[taskId];
        c.deliveredAt = deliveredAt;
        c.revisionDueAt = revisionDueAt;
    }

    function probeClearAwarded(bytes32 taskId, address worker) external {
        delete LibAppStorage.appStorage().taskAwarded[taskId][worker];
    }

    function probeTerms(bytes32 taskId) external returns (ITMPCore.TaskTerms memory) {
        return LibTerms.terms(LibAppStorage.appStorage(), taskId);
    }

    function probeClock(bytes32 taskId) external view returns (ITMPCore.TaskClock memory) {
        return LibAppStorage.appStorage().taskClocks[taskId];
    }

    function probeTermsSlots(bytes32 taskId) external returns (uint256 first, uint256 second) {
        ITMPCore.TaskTerms storage t = LibAppStorage.appStorage().taskTerms[taskId];
        t.version = type(uint8).max;
        t.stakeRequired = true;
        t.stakeBps = type(uint16).max;
        t.penaltyTo = ITMPCore.PenaltyTo.Protocol;
        t.reviewWindowSecs = type(uint32).max;
        t.decisionWindowSecs = type(uint32).max;
        t.reopenExtensionSecs = type(uint32).max;
        t.releaseAllowed = ITMPCore.ReleaseAllowed.Disallowed;
        t.releaseGraceBps = type(uint16).max;
        t.rejectOutcome = ITMPCore.RejectOutcome.Refund;
        t.rejectFeeBps = type(uint16).max;
        t.maxRevisions = type(uint8).max;
        t.resolutionWindowSecs = type(uint32).max;
        // rev027: acceptWindowSecs fills the slot's last four bytes.
        t.acceptWindowSecs = type(uint32).max;
        assembly ("memory-safe") {
            first := sload(t.slot)
            second := sload(add(t.slot, 1))
        }
    }

    function probeClockSlots(bytes32 taskId) external returns (uint256 second) {
        ITMPCore.TaskClock storage c = LibAppStorage.appStorage().taskClocks[taskId];
        c.deliveredAt = type(uint64).max;
        c.decisionStartAt = type(uint64).max;
        c.revisionsUsed = type(uint8).max;
        assembly ("memory-safe") {
            second := sload(add(c.slot, 1))
        }
    }
}

interface ITermsProbe {
    function probeWipeTerms(bytes32 taskId) external;
    function probeWipeClock(bytes32 taskId) external;
    function probeSetClock(bytes32 taskId, uint64 deliveredAt, uint64 revisionDueAt) external;
    function probeClearAwarded(bytes32 taskId, address worker) external;
    function probeTerms(bytes32 taskId) external returns (ITMPCore.TaskTerms memory);
    function probeClock(bytes32 taskId) external view returns (ITMPCore.TaskClock memory);
    function probeTermsSlots(bytes32 taskId) external returns (uint256 first, uint256 second);
    function probeClockSlots(bytes32 taskId) external returns (uint256 second);
}

contract TaskTermsTest is DiamondTestHelper {
    ITMPDiamond internal market;
    ITermsProbe internal probe;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);

    uint256 internal constant REWARD = 100e6;
    uint256 internal constant DURATION = 7 days;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));

        bytes4[] memory sels = new bytes4[](8);
        sels[0] = TermsProbeFacet.probeWipeTerms.selector;
        sels[1] = TermsProbeFacet.probeTerms.selector;
        sels[2] = TermsProbeFacet.probeClock.selector;
        sels[3] = TermsProbeFacet.probeTermsSlots.selector;
        sels[4] = TermsProbeFacet.probeClockSlots.selector;
        sels[5] = TermsProbeFacet.probeClearAwarded.selector;
        sels[6] = TermsProbeFacet.probeWipeClock.selector;
        sels[7] = TermsProbeFacet.probeSetClock.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(new TermsProbeFacet()), IDiamondCut.FacetCutAction.Add, sels);
        IDiamondCut(address(market)).diamondCut(cuts, address(0), "");
        vm.stopPrank();
        probe = ITermsProbe(address(market));

        usdc.mint(address(forwarder), 100_000e6);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _hooks() internal pure returns (ITMPCore.HookConfig memory) {
        return ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" });
    }

    function _content() internal pure returns (ITMPCore.TaskContent memory) {
        return ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) });
    }

    function _config(bytes4 mode) internal pure returns (ITMPCore.TaskConfig memory) {
        if (mode == TMP_PITCH) return taskConfig(REWARD, DURATION, mode, 1 days, 0, bytes4(0));
        if (mode == TMP_AUCTION) return taskConfig(REWARD, DURATION, mode, 0, 1 days, TMP_AUCTION_DUTCH);
        return taskConfig(REWARD, DURATION, mode);
    }

    function _createWithStake(bytes4 mode, bool stakeRequired, uint16 stakeBps) internal returns (bytes32) {
        return abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (_config(mode), _hooks(), _content(), noEvaluatorConfig(), stakeTerms(stakeRequired, stakeBps))
                )
            ),
            (bytes32)
        );
    }

    function _createData(bytes4 mode, ITMPCore.TaskTerms memory terms) internal pure returns (bytes memory) {
        return abi.encodeCall(ITMPTerms.createTask, (_config(mode), _hooks(), _content(), noEvaluatorConfig(), terms));
    }

    function _createWithTerms(bytes4 mode, ITMPCore.TaskTerms memory terms) internal returns (bytes32) {
        return abi.decode(_relay(requester, REWARD, _createData(mode, terms)), (bytes32));
    }

    function _expectInvalid(bytes4 mode, ITMPCore.TaskTerms memory terms) internal {
        bytes memory data = _createData(mode, terms);
        vm.expectRevert(ITMPCore.InvalidTerms.selector);
        forwarder.relay(address(market), requester, REWARD, data);
    }

    function _assertTermsEq(ITMPCore.TaskTerms memory a, ITMPCore.TaskTerms memory b) internal pure {
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)), "terms differ");
    }

    /// @dev A task as a pre-rev025 diamond would have left it: no terms record at all.
    function _legacyTask(bytes4 mode) internal returns (bytes32 taskId) {
        taskId = _createWithStake(mode, true, 1500);
        probe.probeWipeTerms(taskId);
    }

    // -------------------------------------------------------------------------
    // Layout
    // -------------------------------------------------------------------------

    function test_TaskTerms_FitsOneSlot() public {
        (uint256 first, uint256 second) = probe.probeTermsSlots(keccak256("layout"));
        assertEq(second, 0, "TaskTerms must not spill into a second slot");
        assertEq((first >> 184) & 0xff, 0xff, "maxRevisions is the 24th byte");
        assertEq((first >> 192) & 0xffffffff, 0xffffffff, "resolutionWindowSecs is bytes 25 to 28");
        // rev027: acceptWindowSecs takes the last four bytes, so the slot is full.
        assertEq(first >> 224, 0xffffffff, "acceptWindowSecs is bytes 29 to 32");
    }

    function test_TaskClock_FitsOneSlot() public {
        assertEq(probe.probeClockSlots(keccak256("layout")), 0, "TaskClock must not spill into a second slot");
    }

    // -------------------------------------------------------------------------
    // createTask
    // -------------------------------------------------------------------------

    function test_CreateTaskWithTerms_StoresTermsAndLegacyStake() public {
        ITMPCore.TaskTerms memory t = ITMPCore.TaskTerms({
            version: 7,
            stakeRequired: true,
            stakeBps: 2500,
            penaltyTo: ITMPCore.PenaltyTo.Protocol,
            reviewWindowSecs: 2 days,
            decisionWindowSecs: 10 days,
            reopenExtensionSecs: 1 days,
            releaseAllowed: ITMPCore.ReleaseAllowed.Disallowed,
            releaseGraceBps: 1,
            rejectOutcome: ITMPCore.RejectOutcome.Refund,
            rejectFeeBps: 1,
            maxRevisions: 1,
            resolutionWindowSecs: 0,
            acceptWindowSecs: 0
        });
        bytes32 expectedId = keccak256(abi.encode(block.chainid, address(market), requester, uint256(0)));
        ITMPCore.TaskTerms memory stored = t;
        stored.version = 2;
        vm.expectEmit(true, false, false, true, address(market));
        emit ITMPCore.TaskTermsSet(expectedId, stored);
        bytes32 taskId = _createWithTerms(TMP_CLAIM, t);

        _assertTermsEq(market.getTaskTerms(taskId), stored);
        assertTrue(market.getTask(taskId).stakeRequired, "legacy stakeRequired written");
        assertEq(market.getTask(taskId).stakeBps, 2500, "legacy stakeBps written");
    }

    function test_CreateTaskWithTerms_AcceptsBoundaryValues() public {
        ITMPCore.TaskTerms memory t;
        t.reviewWindowSecs = 24 hours;
        t.decisionWindowSecs = 30 days;
        t.reopenExtensionSecs = 30 days;
        t.releaseGraceBps = 10001;
        t.rejectFeeBps = 5001;
        t.maxRevisions = 6;
        t.stakeBps = 5000;
        bytes32 taskId = _createWithTerms(TMP_PITCH, t);
        assertEq(market.getTaskTerms(taskId).rejectFeeBps, 5001, "50% reject fee stored as 5001");
        assertEq(market.getTaskTerms(taskId).maxRevisions, 6, "five revisions stored as 6");
    }

    function test_CreateTaskWithTerms_RefundOnAuction() public {
        ITMPCore.TaskTerms memory t;
        t.rejectOutcome = ITMPCore.RejectOutcome.Refund;
        bytes32 taskId = _createWithTerms(TMP_AUCTION, t);
        assertEq(uint8(market.getTaskTerms(taskId).rejectOutcome), uint8(ITMPCore.RejectOutcome.Refund), "refund");
    }

    // -------------------------------------------------------------------------
    // Bounds
    // -------------------------------------------------------------------------

    function test_InvalidTerms_WindowOutsideBounds() public {
        ITMPCore.TaskTerms memory t;
        t.reviewWindowSecs = 24 hours - 1;
        _expectInvalid(TMP_CLAIM, t);
        t.reviewWindowSecs = 0;
        t.decisionWindowSecs = 30 days + 1;
        _expectInvalid(TMP_BOUNTY, t);
        t.decisionWindowSecs = 0;
        t.reopenExtensionSecs = 1;
        _expectInvalid(TMP_CLAIM, t);
    }

    function test_InvalidTerms_ResolutionWindowOutsideBounds() public {
        ITMPCore.TaskTerms memory t;
        t.resolutionWindowSecs = 1 hours;
        _expectInvalid(TMP_CLAIM, t);
        t.resolutionWindowSecs = 30 days + 1;
        _expectInvalid(TMP_CLAIM, t);
        t.resolutionWindowSecs = 2 days;
        assertEq(market.getTaskTerms(_createWithTerms(TMP_CLAIM, t)).resolutionWindowSecs, 2 days, "stored");
    }

    function test_InvalidTerms_GraceAboveFullSpan() public {
        ITMPCore.TaskTerms memory t;
        t.releaseGraceBps = 10002;
        _expectInvalid(TMP_CLAIM, t);
    }

    function test_InvalidTerms_RejectFeeAboveBound() public {
        ITMPCore.TaskTerms memory t;
        t.rejectFeeBps = 5002;
        _expectInvalid(TMP_CLAIM, t);
    }

    function test_InvalidTerms_MaxRevisionsAboveBound() public {
        ITMPCore.TaskTerms memory t;
        t.maxRevisions = 7;
        _expectInvalid(TMP_CLAIM, t);
    }

    function test_InvalidTerms_ReopenOnAuction() public {
        ITMPCore.TaskTerms memory t;
        t.rejectOutcome = ITMPCore.RejectOutcome.Reopen;
        _expectInvalid(TMP_AUCTION, t);
    }

    function test_CreateTaskWithTerms_StakeBpsTooHigh() public {
        ITMPCore.TaskTerms memory t;
        t.stakeBps = 5001;
        bytes memory data = _createData(TMP_CLAIM, t);
        vm.expectRevert(ITMPCore.StakeBpsTooHigh.selector);
        forwarder.relay(address(market), requester, REWARD, data);
    }

    function test_TermsBounds_DefaultUntilSet() public view {
        (uint32 minW, uint32 maxW, uint16 maxFee, uint8 maxRev) = market.termsBounds();
        assertEq(minW, 24 hours, "min window");
        assertEq(maxW, 30 days, "max window");
        assertEq(maxFee, 5000, "max reject fee");
        assertEq(maxRev, 5, "max revisions");
    }

    function test_TermsBounds_OwnerCanNarrowToZero() public {
        vm.expectEmit(false, false, false, true, address(market));
        emit ITMPCore.TermsBoundsUpdated(2 days, 3 days, 0, 0);
        vm.prank(owner);
        market.setTermsBounds(2 days, 3 days, 0, 0);
        (uint32 minW, uint32 maxW, uint16 maxFee, uint8 maxRev) = market.termsBounds();
        assertEq(minW, 2 days, "min window");
        assertEq(maxW, 3 days, "max window");
        assertEq(maxFee, 0, "zero fee bound is expressible");
        assertEq(maxRev, 0, "zero revisions bound is expressible");

        ITMPCore.TaskTerms memory t;
        t.rejectFeeBps = 2;
        _expectInvalid(TMP_CLAIM, t);
        t.rejectFeeBps = 1;
        t.maxRevisions = 2;
        _expectInvalid(TMP_CLAIM, t);
        t.maxRevisions = 1;
        t.reviewWindowSecs = 1 days;
        _expectInvalid(TMP_CLAIM, t);
        t.reviewWindowSecs = 2 days;
        _createWithTerms(TMP_CLAIM, t);
    }

    function test_SetTermsBounds_RejectsInvalid() public {
        vm.startPrank(owner);
        vm.expectRevert(ITMPCore.InvalidTermsBounds.selector);
        market.setTermsBounds(0, 1 days, 0, 0);
        vm.expectRevert(ITMPCore.InvalidTermsBounds.selector);
        market.setTermsBounds(2 days, 1 days, 0, 0);
        vm.expectRevert(ITMPCore.InvalidTermsBounds.selector);
        market.setTermsBounds(1 days, 2 days, 10001, 0);
        vm.expectRevert(ITMPCore.InvalidTermsBounds.selector);
        market.setTermsBounds(1 days, 2 days, 0, 255);
        vm.stopPrank();
    }

    function test_SetTermsBounds_OnlyOwner() public {
        vm.prank(requester);
        vm.expectRevert();
        market.setTermsBounds(1 days, 2 days, 0, 0);
    }

    // -------------------------------------------------------------------------
    // Pre-rev025 records
    // -------------------------------------------------------------------------

    /// @dev rev026 removed normalization: a version-0 record (a task terminal at the rev025 cut)
    ///      reads as stored and is never rewritten.
    function test_VersionZeroTerms_ReadAsStored() public {
        bytes32 taskId = _legacyTask(TMP_CLAIM);
        ITMPCore.TaskTerms memory zero;
        _assertTermsEq(market.getTaskTerms(taskId), zero);

        vm.recordLogs();
        _assertTermsEq(probe.probeTerms(taskId), zero);
        assertEq(vm.getRecordedLogs().length, 0, "a read writes nothing");
        assertEq(market.getTaskTerms(taskId).version, 0, "still version 0");
    }

    function test_ReviewDeadline_NoDeliveryClock_IsZero() public {
        bytes32 taskId = _createWithStake(TMP_CLAIM, false, 0);
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        probe.probeWipeTerms(taskId);
        probe.probeWipeClock(taskId);
        assertEq(market.reviewDeadline(taskId), 0, "no clock, no review window");
    }

    // -------------------------------------------------------------------------
    // Claim stake enforcement
    // -------------------------------------------------------------------------

    function _createStaked(uint256 reward, uint16 bps) internal returns (bytes32) {
        return abi.decode(
            _relay(
                requester,
                reward,
                abi.encodeCall(
                    market.createTask,
                    (
                        taskConfig(reward, DURATION, TMP_CLAIM),
                        _hooks(),
                        _content(),
                        noEvaluatorConfig(),
                        stakeTerms(true, bps)
                    )
                )
            ),
            (bytes32)
        );
    }

    function _claimWith(bytes32 taskId, uint256 stake) internal {
        _relay(worker, stake, abi.encodeCall(market.claimTask, (taskId, stake)));
    }

    function test_ClaimStake_ExactCeilMinimum_Succeeds() public {
        bytes32 taskId = _createStaked(REWARD + 1, 1500);
        _claimWith(taskId, 15_000_001);
        assertEq(market.getTask(taskId).stakeAmount, 15_000_001);
    }

    function test_ClaimStake_BelowCeilMinimum_Reverts() public {
        bytes32 taskId = _createStaked(REWARD + 1, 1500);
        vm.expectRevert(ITMPCore.StakePaymentMismatch.selector);
        _claimWith(taskId, 15_000_000);
    }

    function test_ClaimStake_AboveMinimum_Succeeds() public {
        bytes32 taskId = _createStaked(REWARD, 1500);
        _claimWith(taskId, 20e6);
        assertEq(market.getTask(taskId).stakeAmount, 20e6);
    }

    function test_ClaimStake_NotRequired_ZeroStakeOk() public {
        bytes32 taskId = _createWithStake(TMP_CLAIM, false, 0);
        _claimWith(taskId, 0);
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Claimed));
    }

    function test_ClaimStake_RequiredZeroBps_ZeroStakeOk() public {
        bytes32 taskId = _createStaked(REWARD, 0);
        _claimWith(taskId, 0);
        assertEq(market.getTask(taskId).worker, worker);
    }

    function test_ClaimStake_PaymentDiffersFromStake_Reverts() public {
        bytes32 taskId = _createStaked(REWARD, 1500);
        vm.expectRevert(ITMPCore.StakePaymentMismatch.selector);
        _relay(worker, 15e6 - 1, abi.encodeCall(market.claimTask, (taskId, 15e6)));
    }

    function test_ClaimStake_AcceptReturnsExactlyRecordedStake() public {
        bytes32 taskId = _createStaked(REWARD, 1500);
        _claimWith(taskId, 15e6);
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        uint256 before = usdc.balanceOf(worker);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));
        uint256 fee = (REWARD * 500) / 10000;
        assertEq(usdc.balanceOf(worker) - before, REWARD - fee + 15e6);
    }

    function test_StakeBps_AboveHalf_Reverts() public {
        vm.expectRevert(ITMPCore.StakeBpsTooHigh.selector);
        _relay(
            requester,
            REWARD,
            abi.encodeCall(
                market.createTask,
                (_config(TMP_CLAIM), _hooks(), _content(), noEvaluatorConfig(), stakeTerms(true, 5001))
            )
        );
    }

    function test_StakeBps_HalfAccepted() public {
        bytes32 taskId = _createWithStake(TMP_CLAIM, true, 5000);
        assertEq(market.getTask(taskId).stakeBps, 5000);
    }

    // -------------------------------------------------------------------------
    // rateTask on a task accepted before rev025 (no award record)
    // -------------------------------------------------------------------------

    function _rate(bytes32 taskId, address who) internal {
        _relay(requester, 0, abi.encodeCall(ITMPDiamond.rateTask, (taskId, who, 50, 0, 0, "", bytes32(0))));
    }

    function _expectRate(bytes32 taskId, address who, bytes4 err) internal {
        bytes memory data = abi.encodeCall(ITMPDiamond.rateTask, (taskId, who, 50, 0, 0, "", bytes32(0)));
        vm.expectRevert(err);
        forwarder.relay(address(market), requester, 0, data);
    }

    function test_RateTask_PreRev025Bounty_FallsBackToSubmitters() public {
        address loser = address(0xC1);
        bytes32 taskId = _createWithStake(TMP_BOUNTY, false, 0);
        _relay(loser, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("L"))));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("W"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("W"), 0)));
        probe.probeWipeTerms(taskId);
        probe.probeClearAwarded(taskId, worker);

        _rate(taskId, worker);
        _rate(taskId, loser);
        _expectRate(taskId, worker, ITMPCore.WorkerAlreadyRated.selector);
        _expectRate(taskId, address(0xBEEF), ITMPCore.NotAwarded.selector);
        _expectRate(taskId, address(0), ITMPCore.WorkerRequired.selector);
    }

    function test_RateTask_PreRev025Claim_FallsBackToTaskWorker() public {
        bytes32 taskId = _createWithStake(TMP_CLAIM, false, 0);
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("W"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("W"), 0)));
        probe.probeWipeTerms(taskId);
        probe.probeClearAwarded(taskId, worker);

        _expectRate(taskId, address(0xBEEF), ITMPCore.WorkerMismatch.selector);
        _rate(taskId, worker);
        _expectRate(taskId, worker, ITMPCore.WorkerAlreadyRated.selector);
    }

    function test_RateTask_Rev025Task_NoFallback() public {
        address loser = address(0xC1);
        bytes32 taskId = _createWithStake(TMP_BOUNTY, false, 0);
        _relay(loser, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("L"))));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("W"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("W"), 0)));
        _expectRate(taskId, loser, ITMPCore.NotAwarded.selector);
        _rate(taskId, worker);
    }
}
