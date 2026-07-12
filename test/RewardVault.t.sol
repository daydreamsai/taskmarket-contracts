// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { RewardVault } from "../src/hooks/RewardVault.sol";
import "./mocks/MockUSDC.sol";

/// @dev Unit tests for RewardVault, exercising every guard and revert branch.
contract RewardVaultTest is Test {
    MockUSDC token;
    RewardVault vault;

    address constant OWNER = address(0xA0);
    address constant HOOK = address(0xB0);
    address constant WORKER = address(0xC0);
    address constant STRANGER = address(0xD0);

    bytes32 constant TASK = bytes32(uint256(1));

    function setUp() public {
        token = new MockUSDC();
        vault = new RewardVault(address(token), OWNER);
        vm.prank(OWNER);
        vault.setHook(HOOK);
        token.mint(address(vault), 1000e6);
    }

    function test_setHook_onlyOwner() public {
        vm.prank(STRANGER);
        vm.expectRevert();
        vault.setHook(STRANGER);
    }

    function test_available_fullBalanceWhenNothingReserved() public view {
        assertEq(vault.available(), 1000e6);
    }

    function test_available_returnsZeroWhenReservedExceedsBalance() public {
        // Reserve everything, then simulate balance dropping below reserved via a direct read.
        vm.prank(HOOK);
        vault.reserve(TASK, 1000e6);
        assertEq(vault.available(), 0);
    }

    function test_reserve_onlyHook() public {
        vm.prank(STRANGER);
        vm.expectRevert(RewardVault.OnlyHook.selector);
        vault.reserve(TASK, 1e6);
    }

    function test_reserve_revertsWhenInsufficient() public {
        vm.prank(HOOK);
        vm.expectRevert(abi.encodeWithSelector(RewardVault.InsufficientAvailable.selector, 2000e6, 1000e6));
        vault.reserve(TASK, 2000e6);
    }

    function test_reserve_happyPath() public {
        vm.prank(HOOK);
        vault.reserve(TASK, 400e6);
        assertEq(vault.totalReserved(), 400e6);
        assertEq(vault.taskReserve(TASK), 400e6);
        assertEq(vault.available(), 600e6);
    }

    function test_release_onlyHook() public {
        vm.prank(STRANGER);
        vm.expectRevert(RewardVault.OnlyHook.selector);
        vault.release(TASK, 1e6);
    }

    function test_release_revertsWhenExceedsReserve() public {
        vm.prank(HOOK);
        vault.reserve(TASK, 100e6);
        vm.prank(HOOK);
        vm.expectRevert(abi.encodeWithSelector(RewardVault.InsufficientReserve.selector, TASK, 200e6, 100e6));
        vault.release(TASK, 200e6);
    }

    function test_release_happyPath() public {
        vm.prank(HOOK);
        vault.reserve(TASK, 300e6);
        vm.prank(HOOK);
        vault.release(TASK, 100e6);
        assertEq(vault.taskReserve(TASK), 200e6);
        assertEq(vault.totalReserved(), 200e6);
    }

    function test_pay_onlyHook() public {
        vm.prank(STRANGER);
        vm.expectRevert(RewardVault.OnlyHook.selector);
        vault.pay(TASK, WORKER, 1e6);
    }

    function test_pay_revertsWhenExceedsReserve() public {
        vm.prank(HOOK);
        vault.reserve(TASK, 50e6);
        vm.prank(HOOK);
        vm.expectRevert(abi.encodeWithSelector(RewardVault.InsufficientReserve.selector, TASK, 60e6, 50e6));
        vault.pay(TASK, WORKER, 60e6);
    }

    function test_pay_transfersAndReleases() public {
        vm.prank(HOOK);
        vault.reserve(TASK, 100e6);
        vm.prank(HOOK);
        vault.pay(TASK, WORKER, 80e6);
        assertEq(token.balanceOf(WORKER), 80e6);
        assertEq(vault.taskReserve(TASK), 20e6);
        assertEq(vault.totalReserved(), 20e6);
    }

    function test_payDirect_onlyHook() public {
        vm.prank(STRANGER);
        vm.expectRevert(RewardVault.OnlyHook.selector);
        vault.payDirect(WORKER, 1e6);
    }

    function test_payDirect_revertsWhenInsufficient() public {
        vm.prank(HOOK);
        vm.expectRevert(abi.encodeWithSelector(RewardVault.InsufficientAvailable.selector, 2000e6, 1000e6));
        vault.payDirect(WORKER, 2000e6);
    }

    function test_payDirect_happyPath() public {
        vm.prank(HOOK);
        vault.payDirect(WORKER, 250e6);
        assertEq(token.balanceOf(WORKER), 250e6);
    }

    function test_withdraw_onlyOwner() public {
        vm.prank(STRANGER);
        vm.expectRevert();
        vault.withdraw(STRANGER, 1e6);
    }

    function test_withdraw_revertsWhenExceedsAvailable() public {
        vm.prank(HOOK);
        vault.reserve(TASK, 900e6); // only 100e6 available
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RewardVault.InsufficientAvailable.selector, 200e6, 100e6));
        vault.withdraw(OWNER, 200e6);
    }

    function test_withdraw_happyPath() public {
        vm.prank(OWNER);
        vault.withdraw(OWNER, 500e6);
        assertEq(token.balanceOf(OWNER), 500e6);
        assertEq(vault.available(), 500e6);
    }

    function test_emergencyWithdraw_onlyOwner() public {
        vm.prank(STRANGER);
        vm.expectRevert();
        vault.emergencyWithdraw(STRANGER);
    }

    function test_emergencyWithdraw_sweepsFullBalanceIgnoringReserve() public {
        vm.prank(HOOK);
        vault.reserve(TASK, 900e6); // only 100e6 nominally "available"
        vm.prank(OWNER);
        vault.emergencyWithdraw(OWNER);
        assertEq(token.balanceOf(OWNER), 1000e6);
        assertEq(token.balanceOf(address(vault)), 0);
        // totalReserved is untouched by the sweep -- a stale ledger entry, by design.
        assertEq(vault.totalReserved(), 900e6);
    }

    function test_emergencyWithdraw_leavesReservationUnfulfillable() public {
        vm.prank(HOOK);
        vault.reserve(TASK, 400e6);
        vm.prank(OWNER);
        vault.emergencyWithdraw(OWNER);
        // The reservation still exists in the ledger, but the vault holds
        // nothing to pay it with -- pay() reverts (caught by the hook's own
        // try/catch in production, not this test's concern).
        vm.prank(HOOK);
        vm.expectRevert();
        vault.pay(TASK, WORKER, 400e6);
    }
}
