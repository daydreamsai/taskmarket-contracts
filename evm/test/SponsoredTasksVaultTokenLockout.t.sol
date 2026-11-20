// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, Vm } from "forge-std/Test.sol";
import { OwnableUpgradeable } from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { SponsoredTaskTypes } from "../src/hooks/sponsored-task/SponsoredTaskTypes.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTasksVaultV2 } from "../src/hooks/sponsored-task/SponsoredTasksVaultV2.sol";

/// @dev An upgradeable-style token whose admin can switch on a 1% transfer fee after launch.
contract SwitchableFeeToken is ERC20 {
    bool public feeOn;

    constructor() ERC20("Switchable fee token", "SWFEE") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeOn(bool on) external {
        feeOn = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (feeOn && from != address(0) && to != address(0) && value != 0) {
            uint256 fee = value / 100;
            if (fee == 0) fee = 1;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @title SponsoredTasksVaultTokenLockoutTest
/// @dev A vault funded with a token that later starts charging a transfer fee. Every outgoing
///      path checks the exact amount received, so claims, fee claims and withdrawals all revert,
///      and so does emergencyExitVault, the owner's last resort: no path is left that moves the
///      balance. The exit test asserts the owner can still recover it, and fails until the exit
///      path tolerates an inexact delivery.
contract SponsoredTasksVaultTokenLockoutTest is Test {
    uint16 internal constant FEE_BPS = 50;
    uint256 internal constant FUNDED = 1_000 ether;
    uint256 internal constant GROSS = 100 ether;
    bytes32 internal constant TERMS_HASH = keccak256("lockout-terms");
    bytes32 internal constant ALLOCATION_ID = keccak256("lockout-allocation");
    bytes32 internal constant TASK_ID = keccak256("lockout-task");

    address internal owner = makeAddr("vaultOwner");
    address internal controller = makeAddr("controller");
    address internal manager = makeAddr("manager");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal treasury = makeAddr("treasury");
    address internal worker = makeAddr("worker");

    SwitchableFeeToken internal token;
    SponsoredTasksVaultV2 internal vault;

    function setUp() public {
        token = new SwitchableFeeToken();
        SponsoredTaskFeePolicy policy = new SponsoredTaskFeePolicy(makeAddr("policyOwner"), FEE_BPS, feeRecipient);
        SponsoredTasksVaultV2 implementation = new SponsoredTasksVaultV2();
        vault = SponsoredTasksVaultV2(Clones.clone(address(implementation)));
        vault.initialize(keccak256("lockout-vault"), address(token), owner, controller, address(policy));

        token.mint(owner, FUNDED);
        vm.startPrank(owner);
        token.approve(address(vault), type(uint256).max);
        vault.fund(FUNDED);
        vault.configureManager(manager, 800 ether, true);
        vm.stopPrank();

        // A sponsored task is reserved and settled while the token still transfers exactly.
        vm.prank(controller);
        vault.reserveTask(ALLOCATION_ID, TASK_ID, manager, GROSS, 1, FEE_BPS, feeRecipient, TERMS_HASH);
        bytes32 root = vault.claimLeaf(ALLOCATION_ID, TASK_ID, 1, 0, worker, 99.5 ether);
        vm.prank(controller);
        vault.installSettlement(ALLOCATION_ID, TASK_ID, root, 1, 99.5 ether, 0.5 ether, GROSS);

        // Then the token starts charging a transfer fee.
        token.setFeeOn(true);
    }

    /// Passes today: every routine outgoing path reverts once the fee is on.
    function test_FeeSwitchedOnAfterFunding_BlocksClaimsFeesAndWithdrawals() public {
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(worker);
        vm.expectPartialRevert(SponsoredTasksVaultV2.TokenRecipientAmountMismatch.selector);
        vault.claim(ALLOCATION_ID, 0, 99.5 ether, proof);

        vm.prank(feeRecipient);
        vm.expectPartialRevert(SponsoredTasksVaultV2.TokenRecipientAmountMismatch.selector);
        vault.claimFee(ALLOCATION_ID, treasury);

        vm.prank(owner);
        vm.expectPartialRevert(SponsoredTasksVaultV2.TokenRecipientAmountMismatch.selector);
        vault.withdrawAvailable(treasury, 10 ether);

        assertEq(token.balanceOf(address(vault)), FUNDED, "nothing has left the vault");
    }

    /// Fails today: emergencyExitVault reverts TokenRecipientAmountMismatch too, so the vault's
    /// whole balance is stuck. The owner should be able to move it out, net of the token's fee.
    function test_FeeSwitchedOnAfterFunding_OwnerCanStillExit() public {
        vm.prank(owner);
        vault.emergencyExitVault(treasury);

        assertEq(token.balanceOf(address(vault)), 0, "vault emptied");
        assertGt(token.balanceOf(treasury), 0, "owner's recipient received the balance net of the fee");
        assertEq(uint256(vault.status()), uint256(SponsoredTaskTypes.VaultStatus.Exited));
    }

    /// The exit records what the recipient received, not the balance before the token's fee.
    function test_FeeSwitchedOnAfterFunding_ExitRecordsWhatArrived() public {
        vm.recordLogs();
        vm.prank(owner);
        uint256 returned = vault.emergencyExitVault(treasury);

        uint256 arrived = token.balanceOf(treasury);
        assertLt(arrived, FUNDED, "the token took a fee");
        assertEq(vault.totalWithdrawn(), arrived, "totalWithdrawn is what arrived");
        assertEq(returned, arrived, "the exit returns what arrived");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != SponsoredTasksVaultV2.VaultEmergencyExited.selector) continue;
            (,, uint256 amountWithdrawn,,) = abi.decode(logs[i].data, (uint64, uint64, uint256, uint256, uint256));
            assertEq(amountWithdrawn, arrived, "the exit event records what arrived");
            seen = true;
        }
        assertTrue(seen, "exit event emitted");
    }

    /// Tokens sent to a vault after its exit are not locked: the owner sweeps them out.
    function test_TokensSentAfterExit_OwnerCanSweep() public {
        vm.prank(owner);
        vault.emergencyExitVault(treasury);
        uint256 afterExit = token.balanceOf(treasury);
        uint256 withdrawnAtExit = vault.totalWithdrawn();

        token.setFeeOn(false);
        token.mint(address(vault), 25 ether);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, makeAddr("stranger"))
        );
        vault.sweepExited(treasury);

        vm.prank(owner);
        uint256 swept = vault.sweepExited(treasury);

        assertEq(swept, 25 ether, "sweep returns what arrived");
        assertEq(token.balanceOf(address(vault)), 0, "vault emptied");
        assertEq(token.balanceOf(treasury), afterExit + 25 ether, "recipient received the stray tokens");
        assertEq(vault.totalWithdrawn(), withdrawnAtExit + 25 ether, "totalWithdrawn counts the sweep");
    }

    /// The sweep is only for an exited vault; an active vault uses withdrawAvailable.
    function test_SweepExited_RevertsWhileActive() public {
        vm.prank(owner);
        vm.expectRevert(SponsoredTasksVaultV2.VaultNotExited.selector);
        vault.sweepExited(treasury);
    }
}
