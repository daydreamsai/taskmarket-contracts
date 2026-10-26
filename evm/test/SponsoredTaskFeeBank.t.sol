// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { SponsoredTaskFeeBank } from "../src/hooks/sponsored-task/SponsoredTaskFeeBank.sol";
import { ISponsoredTaskFeeBank } from "../src/hooks/sponsored-task/interfaces/ISponsoredTaskFeeBank.sol";

contract TaxedFeeToken is MockERC20 {
    bool public taxTransfers;

    constructor(address owner) MockERC20("Taxed mock USDC", "USDC", 6, owner) { }

    function setTaxTransfers(bool enabled) external {
        taxTransfers = enabled;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (taxTransfers && from != address(0) && to != address(0) && amount != 0) {
            super._update(from, to, amount - 1);
            super._update(from, address(0), 1);
            return;
        }
        super._update(from, to, amount);
    }
}

contract AtomicFeeCharger {
    ISponsoredTaskFeeBank private immutable _bank;

    constructor(ISponsoredTaskFeeBank bank_) {
        _bank = bank_;
    }

    function charge(address manager, bytes32 key) external returns (ISponsoredTaskFeeBank.ChargeReceipt memory) {
        return _bank.charge(manager, key);
    }

    function chargeThenRevert(address manager, bytes32 key) external {
        _bank.charge(manager, key);
        revert("task creation reverted");
    }
}

contract SponsoredTaskFeeBankTest is Test {
    uint256 private constant CREATION_FEE = 1e6;
    bytes32 private constant TASK_KEY = keccak256("sponsored-task");

    address private constant OWNER = address(0xA11CE);
    address private constant MANAGER = address(0xBEEF);
    address private constant OTHER_MANAGER = address(0xB0B);
    address private constant SPONSOR = address(0xCAFE);
    address private constant RECIPIENT = address(0xDAD);
    address private constant WITHDRAWAL_RECIPIENT = address(0xF00D);
    address private constant UNAUTHORIZED = address(0xBAD);

    MockERC20 private usdc;
    SponsoredTaskFeeBank private bank;
    AtomicFeeCharger private charger;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6, address(this));
        bank = new SponsoredTaskFeeBank(OWNER, usdc, CREATION_FEE, RECIPIENT);
        charger = new AtomicFeeCharger(bank);

        vm.prank(OWNER);
        bank.setCharger(address(charger), true);

        usdc.mint(MANAGER, 10e6);
        usdc.mint(SPONSOR, 10e6);
    }

    function testConstructorSetsFeeConfiguration() public view {
        assertEq(address(bank.feeToken()), address(usdc));
        assertEq(bank.owner(), OWNER);
        assertEq(bank.feeAmount(), CREATION_FEE);
        assertEq(bank.feeRecipient(), RECIPIENT);
        assertTrue(bank.authorizedChargers(address(charger)));
    }

    function testManagerCanDepositTopUpAndWithdrawUnchargedCredit() public {
        _deposit(MANAGER, 3e6);
        _deposit(MANAGER, 2e6);

        vm.prank(MANAGER);
        uint256 creditAfter = bank.withdrawCredit(1500_000, WITHDRAWAL_RECIPIENT);

        assertEq(creditAfter, 3500_000);
        assertEq(bank.creditOf(MANAGER), 3500_000);
        assertEq(bank.totalCreditLiability(), 3500_000);
        assertEq(usdc.balanceOf(address(bank)), 3500_000);
        assertEq(usdc.balanceOf(WITHDRAWAL_RECIPIENT), 1500_000);
    }

    function testSponsorCanTopUpManagerButCannotWithdrawManagerCredit() public {
        vm.startPrank(SPONSOR);
        usdc.approve(address(bank), 2e6);
        uint256 creditAfter = bank.depositFor(MANAGER, 2e6);
        vm.stopPrank();

        assertEq(creditAfter, 2e6);
        assertEq(bank.creditOf(MANAGER), 2e6);
        assertEq(bank.creditOf(SPONSOR), 0);

        vm.expectRevert(
            abi.encodeWithSelector(ISponsoredTaskFeeBank.InsufficientCredit.selector, SPONSOR, 0, CREATION_FEE)
        );
        vm.prank(SPONSOR);
        bank.withdrawCredit(CREATION_FEE, SPONSOR);
    }

    function testChargePaysCurrentFeeAndStoresReceipt() public {
        _deposit(MANAGER, 3e6);
        vm.warp(123_456);

        ISponsoredTaskFeeBank.ChargeReceipt memory receipt = charger.charge(MANAGER, TASK_KEY);

        assertEq(receipt.key, TASK_KEY);
        assertEq(receipt.manager, MANAGER);
        assertEq(receipt.charger, address(charger));
        assertEq(receipt.recipient, RECIPIENT);
        assertEq(receipt.amount, CREATION_FEE);
        assertEq(receipt.chargedAt, 123_456);
        assertEq(bank.creditOf(MANAGER), 2e6);
        assertEq(bank.totalCreditLiability(), 2e6);
        assertEq(usdc.balanceOf(RECIPIENT), CREATION_FEE);
        assertTrue(bank.isCharged(TASK_KEY));

        ISponsoredTaskFeeBank.ChargeReceipt memory stored = bank.getReceipt(TASK_KEY);
        assertEq(keccak256(abi.encode(stored)), keccak256(abi.encode(receipt)));
    }

    function testExactReplayIsIdempotentAcrossFeeConfigChanges() public {
        _deposit(MANAGER, 4e6);
        ISponsoredTaskFeeBank.ChargeReceipt memory first = charger.charge(MANAGER, TASK_KEY);

        vm.prank(OWNER);
        bank.setFeeConfig(2e6, WITHDRAWAL_RECIPIENT);
        ISponsoredTaskFeeBank.ChargeReceipt memory replay = charger.charge(MANAGER, TASK_KEY);

        assertEq(keccak256(abi.encode(replay)), keccak256(abi.encode(first)));
        assertEq(bank.creditOf(MANAGER), 3e6);
        assertEq(bank.totalCreditLiability(), 3e6);
        assertEq(usdc.balanceOf(RECIPIENT), CREATION_FEE);
        assertEq(usdc.balanceOf(WITHDRAWAL_RECIPIENT), 0);
    }

    function testSameKeyCannotBeReusedForAnotherManager() public {
        _deposit(MANAGER, 2e6);
        charger.charge(MANAGER, TASK_KEY);

        vm.expectRevert(
            abi.encodeWithSelector(ISponsoredTaskFeeBank.UniqueKeyConflict.selector, TASK_KEY, MANAGER, OTHER_MANAGER)
        );
        charger.charge(OTHER_MANAGER, TASK_KEY);
    }

    function testEnclosingCreationRevertRollsChargeBackAtomically() public {
        _deposit(MANAGER, 2e6);

        vm.expectRevert("task creation reverted");
        charger.chargeThenRevert(MANAGER, TASK_KEY);

        assertEq(bank.creditOf(MANAGER), 2e6);
        assertEq(bank.totalCreditLiability(), 2e6);
        assertEq(usdc.balanceOf(RECIPIENT), 0);
        assertFalse(bank.isCharged(TASK_KEY));
        assertEq(bank.getReceipt(TASK_KEY).key, bytes32(0));
    }

    function testInsufficientCreditDoesNotConsumeKeyAndCanBeRetried() public {
        _deposit(MANAGER, CREATION_FEE - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                ISponsoredTaskFeeBank.InsufficientCredit.selector, MANAGER, CREATION_FEE - 1, CREATION_FEE
            )
        );
        charger.charge(MANAGER, TASK_KEY);
        assertFalse(bank.isCharged(TASK_KEY));

        _deposit(MANAGER, 1);
        charger.charge(MANAGER, TASK_KEY);
        assertTrue(bank.isCharged(TASK_KEY));
        assertEq(bank.creditOf(MANAGER), 0);
    }

    function testUnauthorizedCallerCannotCharge() public {
        _deposit(MANAGER, CREATION_FEE);

        vm.expectRevert(abi.encodeWithSelector(ISponsoredTaskFeeBank.UnauthorizedCharger.selector, UNAUTHORIZED));
        vm.prank(UNAUTHORIZED);
        bank.charge(MANAGER, TASK_KEY);
    }

    function testOwnerCanDisableCharger() public {
        vm.prank(OWNER);
        bank.setCharger(address(charger), false);

        vm.expectRevert(abi.encodeWithSelector(ISponsoredTaskFeeBank.UnauthorizedCharger.selector, address(charger)));
        charger.charge(MANAGER, TASK_KEY);
    }

    function testOnlyOwnerCanChangeConfiguration() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, UNAUTHORIZED));
        vm.prank(UNAUTHORIZED);
        bank.setFeeConfig(2e6, WITHDRAWAL_RECIPIENT);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, UNAUTHORIZED));
        vm.prank(UNAUTHORIZED);
        bank.setCharger(UNAUTHORIZED, true);
    }

    function testZeroFeeStillConsumesKeyWithoutMovingCredit() public {
        vm.prank(OWNER);
        bank.setFeeConfig(0, address(0));

        ISponsoredTaskFeeBank.ChargeReceipt memory receipt = charger.charge(MANAGER, TASK_KEY);

        assertTrue(bank.isCharged(TASK_KEY));
        assertEq(receipt.amount, 0);
        assertEq(receipt.recipient, address(0));
        assertEq(bank.creditOf(MANAGER), 0);
    }

    function testTaxedDepositRevertsWithoutCreatingCredit() public {
        TaxedFeeToken taxed = new TaxedFeeToken(address(this));
        SponsoredTaskFeeBank taxedBank = new SponsoredTaskFeeBank(OWNER, taxed, CREATION_FEE, RECIPIENT);
        taxed.mint(MANAGER, 2e6);
        taxed.setTaxTransfers(true);

        vm.startPrank(MANAGER);
        taxed.approve(address(taxedBank), CREATION_FEE);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISponsoredTaskFeeBank.TokenTransferAmountMismatch.selector, CREATION_FEE, CREATION_FEE - 1
            )
        );
        taxedBank.deposit(CREATION_FEE);
        vm.stopPrank();

        assertEq(taxedBank.creditOf(MANAGER), 0);
        assertEq(taxedBank.totalCreditLiability(), 0);
        assertEq(taxed.balanceOf(address(taxedBank)), 0);
        assertEq(taxed.balanceOf(MANAGER), 2e6);
    }

    function testTaxActivatedAfterDepositCannotShortPayRecipient() public {
        TaxedFeeToken taxed = new TaxedFeeToken(address(this));
        SponsoredTaskFeeBank taxedBank = new SponsoredTaskFeeBank(OWNER, taxed, CREATION_FEE, RECIPIENT);
        AtomicFeeCharger taxedCharger = new AtomicFeeCharger(taxedBank);
        vm.prank(OWNER);
        taxedBank.setCharger(address(taxedCharger), true);
        taxed.mint(MANAGER, 2e6);

        vm.startPrank(MANAGER);
        taxed.approve(address(taxedBank), 2e6);
        taxedBank.deposit(2e6);
        vm.stopPrank();
        taxed.setTaxTransfers(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                ISponsoredTaskFeeBank.TokenRecipientAmountMismatch.selector, CREATION_FEE, CREATION_FEE - 1
            )
        );
        taxedCharger.charge(MANAGER, TASK_KEY);

        assertEq(taxedBank.creditOf(MANAGER), 2e6);
        assertEq(taxedBank.totalCreditLiability(), 2e6);
        assertEq(taxed.balanceOf(address(taxedBank)), 2e6);
        assertEq(taxed.balanceOf(RECIPIENT), 0);
        assertFalse(taxedBank.isCharged(TASK_KEY));
    }

    function testConstructorAndSettersRejectInvalidConfiguration() public {
        vm.expectRevert(ISponsoredTaskFeeBank.FeeTokenRequired.selector);
        new SponsoredTaskFeeBank(OWNER, MockERC20(address(0)), CREATION_FEE, RECIPIENT);

        vm.expectRevert(ISponsoredTaskFeeBank.FeeRecipientRequired.selector);
        new SponsoredTaskFeeBank(OWNER, usdc, CREATION_FEE, address(0));

        vm.expectRevert(ISponsoredTaskFeeBank.FeeRecipientIsBank.selector);
        vm.prank(OWNER);
        bank.setFeeConfig(CREATION_FEE, address(bank));

        vm.expectRevert(ISponsoredTaskFeeBank.ChargerRequired.selector);
        vm.prank(OWNER);
        bank.setCharger(address(0), true);
    }

    function testWithdrawRejectsInvalidDestinationAndInsufficientCredit() public {
        _deposit(MANAGER, CREATION_FEE);

        vm.expectRevert(ISponsoredTaskFeeBank.InvalidRecipient.selector);
        vm.prank(MANAGER);
        bank.withdrawCredit(1, address(0));

        vm.expectRevert(ISponsoredTaskFeeBank.InvalidAmount.selector);
        vm.prank(MANAGER);
        bank.withdrawCredit(0, MANAGER);

        vm.expectRevert(
            abi.encodeWithSelector(
                ISponsoredTaskFeeBank.InsufficientCredit.selector, MANAGER, CREATION_FEE, CREATION_FEE + 1
            )
        );
        vm.prank(MANAGER);
        bank.withdrawCredit(CREATION_FEE + 1, MANAGER);
    }

    function testChargeRejectsInvalidInputs() public {
        vm.expectRevert(ISponsoredTaskFeeBank.InvalidManager.selector);
        charger.charge(address(0), TASK_KEY);

        vm.expectRevert(ISponsoredTaskFeeBank.InvalidUniqueKey.selector);
        charger.charge(MANAGER, bytes32(0));
    }

    function _deposit(address manager, uint256 amount) private {
        vm.startPrank(manager);
        usdc.approve(address(bank), amount);
        bank.deposit(amount);
        vm.stopPrank();
    }
}
