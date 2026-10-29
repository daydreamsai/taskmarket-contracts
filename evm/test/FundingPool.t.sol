// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { FundingPool } from "../src/FundingPool.sol";
import { ITMPFundingPool } from "../src/interfaces/ITMPFundingPool.sol";
import { IFundingPoolManager } from "../src/interfaces/IFundingPoolManager.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";

/// @dev The two things the pool reads from its manager: the owner and the payment token.
contract MockPoolDiamond {
    address public owner;
    address public usdcToken;

    constructor(address owner_, address token_) {
        owner = owner_;
        usdcToken = token_;
    }

    function setOwner(address owner_) external {
        owner = owner_;
    }
}

/// @dev A second implementation, to prove an upgrade keeps state and the upgrade function.
contract FundingPoolV2 is FundingPool {
    function version() external pure returns (uint256) {
        return 2;
    }
}

abstract contract FundingPoolBase is Test {
    uint256 internal constant SCALE = 1e12;
    uint256 internal constant BUDGET = 10e6;

    MockUSDC internal usdc;
    MockPoolDiamond internal diamond;
    FundingPool internal impl;
    FundingPool internal pools;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");
    address internal creator = makeAddr("creator");

    bytes32 internal pool = keccak256("pool-1");
    bytes32 internal constant MODULE = keccak256("project");

    function setUp() public virtual {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        diamond = new MockPoolDiamond(owner, address(usdc));
        impl = new FundingPool();
        pools = FundingPool(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(FundingPool.initialize, (address(diamond), address(usdc)))
                )
            )
        );
    }

    // The diamond's side of each call: it moves the tokens first, then books them.

    function _open(bytes32 id, uint64 closesAt) internal {
        vm.prank(address(diamond));
        pools.open(id, address(usdc), MODULE, closesAt);
    }

    function _creditOpening(bytes32 id, address backer, uint256 amount) internal {
        usdc.mint(address(pools), amount);
        vm.prank(address(diamond));
        pools.creditOpening(id, backer, amount);
    }

    function _creditFunding(bytes32 id, address backer, uint256 amount) internal {
        usdc.mint(address(pools), amount);
        vm.prank(address(diamond));
        pools.creditFunding(id, address(diamond), backer, amount);
    }

    function _fund(bytes32 id, address backer, uint256 amount) internal {
        usdc.mint(backer, amount);
        vm.startPrank(backer);
        usdc.approve(address(pools), amount);
        pools.fund(id, amount, address(0));
        vm.stopPrank();
    }

    function _spend(bytes32 id, uint256 amount) internal {
        vm.prank(address(diamond));
        pools.spend(id, amount);
    }

    /// @dev Returns `amount` the diamond holds from an earlier spend, as a task payout does.
    function _refund(bytes32 id, uint256 amount) internal {
        vm.startPrank(address(diamond));
        usdc.transfer(address(pools), amount);
        pools.refund(id, amount);
        vm.stopPrank();
    }

    /// @dev A windfall: money the diamond holds that was never drawn (a forfeited stake).
    function _windfall(bytes32 id, uint256 amount) internal {
        usdc.mint(address(diamond), amount);
        _refund(id, amount);
    }

    /// @dev A task drew `amount` and finished: it paid its worker, so the money left for good.
    function _spendDone(bytes32 id, uint256 amount) internal {
        _spend(id, amount);
        _finish(id, amount);
    }

    function _finish(bytes32 id, uint256 amount) internal {
        vm.prank(address(diamond));
        pools.finish(id, amount);
    }

    function _close(bytes32 id) internal {
        vm.prank(address(diamond));
        pools.close(id);
    }

    function _claim(bytes32 id, address backer) internal returns (uint256) {
        vm.prank(stranger);
        return pools.claim(id, backer);
    }

    function _info(bytes32 id) internal view returns (ITMPFundingPool.PoolInfo memory) {
        return pools.getPool(id);
    }
}

contract FundingPoolTest is FundingPoolBase {
    function setUp() public override {
        super.setUp();
        _open(pool, 0);
        _creditOpening(pool, creator, BUDGET);
    }

    // ---------------------------------------------------------------- shares

    function test_OpeningBudget_MintsSharesAtTheFirstPrice() public view {
        assertEq(pools.sharesOf(pool, creator), BUDGET * SCALE);
        ITMPFundingPool.PoolInfo memory info = _info(pool);
        assertEq(info.funded, BUDGET);
        assertEq(info.available, BUDGET);
        assertEq(info.totalShares, BUDGET * SCALE);
        assertEq(info.token, address(usdc));
        assertEq(info.module, MODULE);
        assertFalse(info.settled);
        assertEq(pools.totalLiabilities(), BUDGET);
    }

    function test_Fund_PullsFromTheCallerAndBooksIt() public {
        _fund(pool, alice, 5e6);
        assertEq(pools.sharesOf(pool, alice), 5e6 * SCALE);
        assertEq(usdc.balanceOf(address(pools)), BUDGET + 5e6);
        assertEq(pools.totalLiabilities(), BUDGET + 5e6);
    }

    function test_Fund_OnBehalfOfSomeoneElse() public {
        usdc.mint(alice, 5e6);
        vm.startPrank(alice);
        usdc.approve(address(pools), 5e6);
        vm.expectEmit(address(pools));
        emit ITMPFundingPool.PoolFunded(pool, alice, bob, 5e6, 5e6 * SCALE);
        pools.fund(pool, 5e6, bob);
        vm.stopPrank();
        assertEq(pools.sharesOf(pool, bob), 5e6 * SCALE);
        assertEq(pools.sharesOf(pool, alice), 0);
    }

    function test_RevertWhen_Fund_WithoutAllowance() public {
        usdc.mint(alice, 5e6);
        vm.prank(alice);
        vm.expectRevert();
        pools.fund(pool, 5e6, address(0));
    }

    function test_RevertWhen_Fund_ZeroClosedOrPastClosesAt() public {
        vm.prank(alice);
        vm.expectRevert(ITMPFundingPool.PoolAmountZero.selector);
        pools.fund(pool, 0, address(0));

        bytes32 timed = keccak256("timed");
        _open(timed, uint64(block.timestamp + 1 days));
        _creditOpening(timed, creator, 1e6);
        vm.warp(block.timestamp + 1 days);
        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(pools), 1e6);
        vm.expectRevert(ITMPFundingPool.PoolNotOpen.selector);
        pools.fund(timed, 1e6, address(0));
        vm.stopPrank();

        _close(pool);
        vm.startPrank(alice);
        vm.expectRevert(ITMPFundingPool.PoolNotOpen.selector);
        pools.fund(pool, 1e6, address(0));
        vm.stopPrank();
    }

    function test_RevertWhen_UnknownPool() public {
        bytes32 nope = keccak256("nope");
        vm.expectRevert(ITMPFundingPool.PoolNotFound.selector);
        pools.getPool(nope);
        vm.expectRevert(ITMPFundingPool.PoolNotFound.selector);
        pools.sharesOf(nope, alice);
        vm.expectRevert(ITMPFundingPool.PoolNotFound.selector);
        pools.claimable(nope, alice);
        vm.expectRevert(ITMPFundingPool.PoolNotFound.selector);
        pools.claim(nope, alice);
        vm.startPrank(address(diamond));
        vm.expectRevert(ITMPFundingPool.PoolNotFound.selector);
        pools.spend(nope, 1);
        vm.expectRevert(ITMPFundingPool.PoolNotFound.selector);
        pools.refund(nope, 1);
        vm.expectRevert(ITMPFundingPool.PoolNotFound.selector);
        pools.finish(nope, 1);
        vm.expectRevert(ITMPFundingPool.PoolNotFound.selector);
        pools.close(nope);
        vm.stopPrank();
    }

    function test_RevertWhen_Open_TakenOrWrongToken() public {
        vm.startPrank(address(diamond));
        vm.expectRevert(ITMPFundingPool.PoolAlreadyExists.selector);
        pools.open(pool, address(usdc), MODULE, 0);
        vm.expectRevert(IFundingPoolManager.PoolInvalidToken.selector);
        pools.open(keccak256("other"), address(0xdead), MODULE, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_Fund_BackerIsTheDiamondOrThePool() public {
        usdc.mint(alice, 2e6);
        vm.startPrank(alice);
        usdc.approve(address(pools), 2e6);
        vm.expectRevert(ITMPFundingPool.PoolInvalidBacker.selector);
        pools.fund(pool, 1e6, address(diamond));
        vm.expectRevert(ITMPFundingPool.PoolInvalidBacker.selector);
        pools.fund(pool, 1e6, address(pools));
        vm.stopPrank();

        // The diamond funding directly for itself is the same case.
        usdc.mint(address(diamond), 1e6);
        vm.startPrank(address(diamond));
        usdc.approve(address(pools), 1e6);
        vm.expectRevert(ITMPFundingPool.PoolInvalidBacker.selector);
        pools.fund(pool, 1e6, address(0));
        vm.stopPrank();

        // And relayed funding.
        usdc.mint(address(pools), 1e6);
        vm.startPrank(address(diamond));
        vm.expectRevert(ITMPFundingPool.PoolInvalidBacker.selector);
        pools.creditFunding(pool, alice, address(diamond), 1e6);
        vm.expectRevert(ITMPFundingPool.PoolInvalidBacker.selector);
        pools.creditOpening(pool, address(pools), 1e6);
        vm.stopPrank();
    }

    function test_RevertWhen_Credit_NotBackedByMoney() public {
        vm.prank(address(diamond));
        vm.expectRevert(abi.encodeWithSelector(FundingPool.PoolUnderfunded.selector, BUDGET, BUDGET + 1e6));
        pools.creditFunding(pool, alice, alice, 1e6);
    }

    function test_Spend_MovesMoneyToOutstandingAndTheDiamond() public {
        _spend(pool, 4e6);
        ITMPFundingPool.PoolInfo memory info = _info(pool);
        assertEq(info.available, 6e6);
        assertEq(info.outstanding, 4e6);
        assertEq(usdc.balanceOf(address(diamond)), 4e6);
        assertEq(pools.totalLiabilities(), 6e6);
        assertEq(usdc.balanceOf(address(pools)), 6e6);
    }

    function test_RevertWhen_Spend_OverAvailableOrSettled() public {
        vm.prank(address(diamond));
        vm.expectRevert(abi.encodeWithSelector(ITMPFundingPool.PoolBalanceExceeded.selector, BUDGET, BUDGET + 1));
        pools.spend(pool, BUDGET + 1);
        _close(pool);
        vm.prank(address(diamond));
        vm.expectRevert(ITMPFundingPool.PoolNotOpen.selector);
        pools.spend(pool, 1);
    }

    function test_LateBacker_AfterPartOfTheBudgetWasSpent_PaysTheValueLeft() public {
        _spendDone(pool, BUDGET / 2);
        _fund(pool, alice, BUDGET);
        assertEq(pools.sharesOf(pool, alice), 2 * BUDGET * SCALE, "10 buys at 0.5 per share unit");
        _close(pool);
        assertEq(_claim(pool, alice), BUDGET);
        assertEq(_claim(pool, creator), BUDGET / 2);
        assertEq(pools.totalLiabilities(), 0);
    }

    function test_LateBacker_AfterTheBudgetWasSpent_GetsTheirMoneyBack() public {
        _spendDone(pool, BUDGET);
        _fund(pool, alice, BUDGET);
        _close(pool);
        uint256 a = _claim(pool, alice);
        assertGe(a, BUDGET - 1);
        assertLe(a, BUDGET);
        assertEq(pools.claimable(pool, creator), 0);
        assertLe(pools.totalLiabilities(), 1);
    }

    function test_LateBacker_DoesNotCaptureAnEarlierWindfall() public {
        _windfall(pool, 1e6);
        assertEq(_info(pool).available, BUDGET + 1e6);
        _fund(pool, alice, 990e6);
        _close(pool);
        uint256 a = _claim(pool, alice);
        uint256 o = _claim(pool, creator);
        assertLe(a, 990e6);
        assertGe(a, 990e6 - 1);
        assertGe(o, BUDGET + 1e6 - 1);
        assertLe(pools.totalLiabilities(), 2);
    }

    function test_InflationAttack_DoesNotDiluteALaterBacker() public {
        bytes32 id = keccak256("tiny");
        _open(id, 0);
        _creditOpening(id, creator, 1);
        _windfall(id, 1000e6);
        usdc.mint(address(pools), 1000e6); // a donation, never booked
        uint256 amount = 1500e6 + 7;
        _fund(id, alice, amount);
        _close(id);
        uint256 a = _claim(id, alice);
        assertGe(a, amount - 1);
        assertLe(a, amount);
    }

    function test_Donation_DoesNotChangeTheSharePrice() public {
        usdc.mint(address(pools), 50e6);
        _fund(pool, alice, 5e6);
        assertEq(pools.sharesOf(pool, alice), 5e6 * SCALE);
    }

    // ---------------------------------------------------------------- claims

    function test_CloseEarly_SharesTheLeftoverProRata() public {
        _fund(pool, alice, 10e6);
        _spend(pool, 4e6);
        _finish(pool, 4e6);
        _close(pool);
        assertEq(_info(pool).potIn, 16e6);
        assertEq(pools.claimable(pool, creator), 8e6);
        assertEq(_claim(pool, creator), 8e6);
        assertEq(_claim(pool, alice), 8e6);
        assertEq(pools.totalLiabilities(), 0);
        assertEq(usdc.balanceOf(creator), 8e6, "the money goes to the backer, not the caller");
    }

    function test_Settles_AtClosesAtWithoutATransaction() public {
        bytes32 id = keccak256("timed");
        _open(id, uint64(block.timestamp + 30 days));
        _creditOpening(id, creator, 3e6);
        assertEq(pools.claimable(id, creator), 0);
        vm.warp(block.timestamp + 30 days);
        assertTrue(_info(id).settled);
        assertEq(_claim(id, creator), 3e6);
    }

    function test_RefundsAfterSettlement_AddToThePot() public {
        _fund(pool, alice, 10e6);
        _spend(pool, 6e6);
        _close(pool);
        assertEq(_claim(pool, alice), 7e6);
        _finish(pool, 6e6);
        _refund(pool, 6e6);
        assertEq(pools.claimable(pool, alice), 3e6);
        assertEq(pools.claimable(pool, creator), 10e6);
    }

    function test_RevertWhen_Claim_TwiceWhileOpenOrNonBacker() public {
        vm.expectRevert(ITMPFundingPool.NothingToClaim.selector);
        pools.claim(pool, creator);
        _close(pool);
        _claim(pool, creator);
        vm.expectRevert(ITMPFundingPool.NothingToClaim.selector);
        pools.claim(pool, creator);
        vm.expectRevert(ITMPFundingPool.NothingToClaim.selector);
        pools.claim(pool, stranger);
    }

    function test_Dust_StaysBookedAndBounded() public {
        _fund(pool, alice, BUDGET);
        _fund(pool, bob, BUDGET);
        _spend(pool, 4e6);
        _finish(pool, 4e6);
        _close(pool);
        uint256 leftover = 3 * BUDGET - 4e6; // 26,000,000
        assertEq(_info(pool).potIn, leftover);
        uint256 each = leftover / 3;
        assertEq(_claim(pool, creator), each);
        assertEq(_claim(pool, alice), each);
        assertEq(_claim(pool, bob), each);
        assertEq(pools.totalLiabilities(), leftover - 3 * each);
        assertLt(pools.totalLiabilities(), 3);
    }

    function testFuzz_ClaimsNeverExceedThePot(uint96 a, uint96 b, uint96 c, uint256 spend, uint256 back) public {
        a = uint96(bound(a, 1, 1e15));
        b = uint96(bound(b, 1, 1e15));
        c = uint96(bound(c, 1, 1e15));
        _fund(pool, alice, a);
        _fund(pool, bob, b);
        _fund(pool, stranger, c);
        spend = bound(spend, 0, _info(pool).available);
        _spend(pool, spend);
        _finish(pool, spend);
        back = bound(back, 0, spend);
        _close(pool);
        if (back > 0) _refund(pool, back);
        uint256 pot = _info(pool).potIn;
        uint256 paid;
        address[4] memory all = [creator, alice, bob, stranger];
        for (uint256 i; i < 4; ++i) {
            if (pools.claimable(pool, all[i]) > 0) paid += _claim(pool, all[i]);
        }
        assertLe(paid, pot);
        assertLe(pot - paid, 4, "under one base unit per backer stays");
        assertGe(usdc.balanceOf(address(pools)), pools.totalLiabilities());
    }

    // ------------------------------------------------------------ generation

    function test_DrainAndRefill_NeverBricksFunding() public {
        _spendDone(pool, BUDGET);
        for (uint256 i; i < 20; ++i) {
            _fund(pool, alice, 1000e6);
            assertEq(_info(pool).totalShares, 1000e6 * SCALE, "a new generation mints at the first price");
            _spendDone(pool, 1000e6);
        }
        assertEq(_info(pool).generation, 20);
    }

    function test_NewGeneration_OldBackersTakeNothing() public {
        _fund(pool, alice, 5e6);
        _spendDone(pool, 15e6);
        assertEq(pools.sharesOf(pool, alice), 5e6 * SCALE, "shares still read until a new generation");
        usdc.mint(bob, 5e6);
        vm.startPrank(bob);
        usdc.approve(address(pools), 5e6);
        vm.expectEmit(address(pools));
        emit ITMPFundingPool.PoolSharesReset(pool, 1);
        pools.fund(pool, 5e6, address(0));
        vm.stopPrank();
        assertEq(pools.sharesOf(pool, creator), 0);
        assertEq(pools.sharesOf(pool, alice), 0);
        assertEq(pools.sharesOf(pool, bob), 5e6 * SCALE);
        _fund(pool, alice, 5e6);
        _close(pool);
        vm.expectRevert(ITMPFundingPool.NothingToClaim.selector);
        pools.claim(pool, creator);
        assertEq(_claim(pool, alice), 5e6);
        assertEq(_claim(pool, bob), 5e6);
        assertEq(pools.totalLiabilities(), 0);
    }

    function test_ZeroValuePool_KeepsItsGenerationUntilFunded() public {
        _fund(pool, alice, BUDGET);
        _spendDone(pool, 2 * BUDGET);
        _close(pool);
        assertEq(_info(pool).generation, 0);
        assertEq(pools.sharesOf(pool, alice), BUDGET * SCALE);
        assertEq(pools.claimable(pool, alice), 0);
        vm.expectRevert(ITMPFundingPool.NothingToClaim.selector);
        pools.claim(pool, alice);
    }

    // ------------------------------------------------------------ manager only

    function test_RevertWhen_ManagerFunctions_CalledByAnyoneElse() public {
        address[3] memory callers = [stranger, owner, creator];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(IFundingPoolManager.NotManager.selector);
            pools.open(keccak256("x"), address(usdc), MODULE, 0);
            vm.expectRevert(IFundingPoolManager.NotManager.selector);
            pools.creditOpening(pool, alice, 1);
            vm.expectRevert(IFundingPoolManager.NotManager.selector);
            pools.creditFunding(pool, alice, alice, 1);
            vm.expectRevert(IFundingPoolManager.NotManager.selector);
            pools.spend(pool, 1);
            vm.expectRevert(IFundingPoolManager.NotManager.selector);
            pools.refund(pool, 1);
            vm.expectRevert(IFundingPoolManager.NotManager.selector);
            pools.finish(pool, 1);
            vm.expectRevert(IFundingPoolManager.NotManager.selector);
            pools.close(pool);
            vm.stopPrank();
        }
        assertEq(pools.manager(), address(diamond));
    }

    // ------------------------------------------------------------------ pause

    function test_Pause_StopsFundCreditFundingAndClaim_NothingElse() public {
        _fund(pool, alice, 5e6);
        _spend(pool, 2e6);

        vm.prank(stranger);
        vm.expectRevert(FundingPool.NotOwner.selector);
        pools.pause();
        vm.prank(owner);
        pools.pause();
        assertTrue(pools.paused());

        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(pools), 1e6);
        vm.expectRevert(IFundingPoolManager.PoolPaused.selector);
        pools.fund(pool, 1e6, address(0));
        vm.stopPrank();

        usdc.mint(address(pools), 1e6);
        vm.startPrank(address(diamond));
        vm.expectRevert(IFundingPoolManager.PoolPaused.selector);
        pools.creditFunding(pool, alice, alice, 1e6);

        // Never paused: the settlement paths and the opening budget.
        pools.creditOpening(pool, creator, 1e6);
        pools.spend(pool, 1e6);
        usdc.transfer(address(pools), 3e6);
        pools.refund(pool, 3e6);
        pools.finish(pool, 3e6);
        pools.close(pool);
        vm.stopPrank();

        vm.expectRevert(IFundingPoolManager.PoolPaused.selector);
        pools.claim(pool, alice);

        vm.prank(owner);
        pools.unpause();
        assertGt(_claim(pool, alice), 0);
    }

    function test_Owner_FollowsTheDiamond() public {
        assertEq(pools.owner(), owner);
        diamond.setOwner(alice);
        assertEq(pools.owner(), alice);
        vm.prank(owner);
        vm.expectRevert(FundingPool.NotOwner.selector);
        pools.pause();
        vm.prank(alice);
        pools.pause();
    }

    // ----------------------------------------------------------- ledger drift

    function test_Finish_SaturatesAndEmitsMismatch() public {
        _spend(pool, 4e6);
        vm.expectEmit(address(pools));
        emit IFundingPoolManager.PoolLedgerMismatch(pool, 6e6, 4e6);
        _finish(pool, 6e6);
        assertEq(_info(pool).outstanding, 0);

        // A normal finish emits no mismatch and a zero outstanding stays zero.
        vm.recordLogs();
        _finish(pool, 0);
        assertEq(vm.getRecordedLogs().length, 0);
        vm.expectEmit(address(pools));
        emit IFundingPoolManager.PoolLedgerMismatch(pool, 1, 0);
        _finish(pool, 1);
    }

    // ------------------------------------------------------------ solvency

    function test_RevertWhen_Refund_NotBackedByMoney() public {
        vm.prank(address(diamond));
        vm.expectRevert(abi.encodeWithSelector(FundingPool.PoolUnderfunded.selector, BUDGET, BUDGET + 1));
        pools.refund(pool, 1);
    }

    // ------------------------------------------------------- init and upgrade

    function test_Initialize_RunsOnceAndChecksTheToken() public {
        vm.expectRevert();
        pools.initialize(address(diamond), address(usdc));
        vm.expectRevert();
        impl.initialize(address(diamond), address(usdc));

        MockUSDC other = new MockUSDC();
        bytes memory data = abi.encodeCall(FundingPool.initialize, (address(diamond), address(other)));
        vm.expectRevert(IFundingPoolManager.PoolInvalidToken.selector);
        new ERC1967Proxy(address(impl), data);

        data = abi.encodeCall(FundingPool.initialize, (address(0), address(usdc)));
        vm.expectRevert(FundingPool.PoolInvalidManager.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_Upgrade_KeepsStateAndTheUpgradeFunction() public {
        _fund(pool, alice, 5e6);
        _spend(pool, 3e6);
        ITMPFundingPool.PoolInfo memory before_ = _info(pool);
        uint256 liabilities = pools.totalLiabilities();

        FundingPoolV2 v2 = new FundingPoolV2();
        vm.prank(stranger);
        vm.expectRevert(FundingPool.NotOwner.selector);
        pools.upgradeToAndCall(address(v2), "");

        vm.prank(owner);
        pools.upgradeToAndCall(address(v2), "");
        assertEq(FundingPoolV2(address(pools)).version(), 2);
        assertEq(abi.encode(_info(pool)), abi.encode(before_));
        assertEq(pools.totalLiabilities(), liabilities);
        assertEq(pools.sharesOf(pool, alice), 5e6 * SCALE);
        assertEq(pools.manager(), address(diamond));

        // The upgrade function survived: the owner upgrades again, a stranger still cannot.
        FundingPoolV2 v2b = new FundingPoolV2();
        vm.prank(stranger);
        vm.expectRevert(FundingPool.NotOwner.selector);
        pools.upgradeToAndCall(address(v2b), "");
        vm.prank(owner);
        pools.upgradeToAndCall(address(v2b), "");

        // The initialiser cannot run again.
        vm.expectRevert();
        pools.initialize(address(diamond), address(usdc));
        // And the pool still works.
        _close(pool);
        assertEq(_claim(pool, alice), 4e6);
    }

    function test_Upgrade_RevertsForANonUUPSImplementation() public {
        vm.prank(owner);
        vm.expectRevert();
        pools.upgradeToAndCall(address(usdc), "");
    }
}

/// @dev Drives the pool like the diamond and its backers: several pools, interleaved.
contract FundingPoolHandler is Test {
    FundingPool public pools;
    MockUSDC public usdc;
    address public diamond;
    bytes32[3] public ids;
    address[4] public actors;
    /// @dev What the diamond holds of each pool's spent money, the model of taskPoolDraws.
    uint256[3] public held;

    constructor(FundingPool pools_, MockUSDC usdc_, address diamond_) {
        pools = pools_;
        usdc = usdc_;
        diamond = diamond_;
        actors = [address(0xA1), address(0xA2), address(0xA3), address(0xA4)];
        for (uint256 i; i < 3; ++i) {
            ids[i] = keccak256(abi.encode("pool", i));
            vm.startPrank(diamond);
            pools.open(ids[i], address(usdc), keccak256("project"), i == 2 ? uint64(block.timestamp + 5 days) : 0);
            vm.stopPrank();
            usdc.mint(address(pools), 10e6);
            vm.prank(diamond);
            pools.creditOpening(ids[i], actors[0], 10e6);
        }
    }

    function fund(uint256 p, uint256 a, uint256 amount) external {
        p %= 3;
        address backer = actors[a % 4];
        amount = bound(amount, 1, 1e12);
        usdc.mint(backer, amount);
        vm.startPrank(backer);
        usdc.approve(address(pools), amount);
        try pools.fund(ids[p], amount, address(0)) { } catch { }
        vm.stopPrank();
    }

    function creditFunding(uint256 p, uint256 a, uint256 amount) external {
        p %= 3;
        amount = bound(amount, 1, 1e12);
        usdc.mint(address(pools), amount);
        vm.prank(diamond);
        try pools.creditFunding(ids[p], diamond, actors[a % 4], amount) { }
            catch {
            // Not booked: the money is a donation, which the pool never counts.
        }
    }

    function spend(uint256 p, uint256 amount) external {
        p %= 3;
        ITMPFundingPool.PoolInfo memory info = pools.getPool(ids[p]);
        if (info.settled || info.available == 0) return;
        amount = bound(amount, 1, info.available);
        vm.prank(diamond);
        pools.spend(ids[p], amount);
        held[p] += amount;
    }

    function refund(uint256 p, uint256 amount) external {
        p %= 3;
        if (held[p] == 0) return;
        amount = bound(amount, 1, held[p]);
        held[p] -= amount;
        vm.startPrank(diamond);
        usdc.transfer(address(pools), amount);
        pools.refund(ids[p], amount);
        pools.finish(ids[p], amount);
        vm.stopPrank();
    }

    /// @dev A task that pays its worker: the money leaves the diamond for good.
    function payOut(uint256 p, uint256 amount) external {
        p %= 3;
        if (held[p] == 0) return;
        amount = bound(amount, 1, held[p]);
        held[p] -= amount;
        vm.startPrank(diamond);
        usdc.transfer(address(0xDEAD), amount);
        pools.finish(ids[p], amount);
        vm.stopPrank();
    }

    function windfall(uint256 p, uint256 amount) external {
        p %= 3;
        amount = bound(amount, 1, 1e9);
        usdc.mint(diamond, amount);
        vm.startPrank(diamond);
        usdc.transfer(address(pools), amount);
        pools.refund(ids[p], amount);
        vm.stopPrank();
    }

    function close(uint256 p) external {
        p %= 3;
        vm.prank(diamond);
        try pools.close(ids[p]) { } catch { }
    }

    function claim(uint256 p, uint256 a) external {
        p %= 3;
        try pools.claim(ids[p], actors[a % 4]) { } catch { }
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 3 days));
    }

    function sumAvailable() external view returns (uint256 total) {
        for (uint256 i; i < 3; ++i) {
            total += pools.getPool(ids[i]).available;
        }
    }
}

contract FundingPoolInvariantTest is StdInvariant, FundingPoolBase {
    FundingPoolHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new FundingPoolHandler(pools, usdc, address(diamond));
        targetContract(address(handler));
    }

    function invariant_PoolHoldsAtLeastItsLiabilities() public view {
        assertGe(usdc.balanceOf(address(pools)), pools.totalLiabilities());
    }

    function invariant_LiabilitiesAreTheSumOfAvailable() public view {
        assertEq(pools.totalLiabilities(), handler.sumAvailable());
    }

    function invariant_OutstandingMatchesTheDiamondDraws() public view {
        for (uint256 i; i < 3; ++i) {
            assertEq(pools.getPool(handler.ids(i)).outstanding, handler.held(i));
        }
    }

    function invariant_ClaimsNeverExceedThePot() public view {
        for (uint256 i; i < 3; ++i) {
            bytes32 id = handler.ids(i);
            ITMPFundingPool.PoolInfo memory info = pools.getPool(id);
            if (!info.settled) {
                assertEq(info.claimed, 0);
                continue;
            }
            uint256 entitled;
            for (uint256 a; a < 4; ++a) {
                address actor = handler.actors(a);
                entitled += pools.claimable(id, actor);
            }
            assertLe(info.claimed + entitled, info.potIn);
        }
    }
}
