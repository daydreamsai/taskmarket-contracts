// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { SponsoredTaskFeeBank } from "../src/hooks/sponsored-task/SponsoredTaskFeeBank.sol";
import { SponsoredTaskFeeBankDepositor } from "../src/hooks/sponsored-task/SponsoredTaskFeeBankDepositor.sol";
import { ISponsoredTaskFeeBank } from "../src/hooks/sponsored-task/interfaces/ISponsoredTaskFeeBank.sol";
import { VaultV2Base, VaultV2ContractWallet } from "./SponsoredTasksVaultV2.t.sol";

contract SponsoredTaskFeeBankDepositorTest is VaultV2Base {
    SponsoredTaskFeeBank internal bank;
    SponsoredTaskFeeBankDepositor internal depositor;

    event CreditDepositedWithAuthorization(
        address indexed depositor, address indexed manager, uint256 amount, uint256 managerCreditAfter
    );

    function setUp() public override {
        super.setUp();
        bank = new SponsoredTaskFeeBank(address(this), IERC20(address(token)), 1e6, feeRecipient);
        depositor = new SponsoredTaskFeeBankDepositor(ISponsoredTaskFeeBank(address(bank)));
        token.mint(funder, 100e6);
    }

    function _signDeposit(uint256 key, address from, address m, uint256 amount, bytes32 salt, uint256 validBefore)
        internal
        view
        returns (bytes memory)
    {
        return _receiveAuthorization(
            key, from, address(depositor), amount, validBefore, depositor.authorizationNonce(m, salt)
        );
    }

    function test_DepositWithAuthorization_CreditsTheSignedManager() public {
        uint256 validBefore = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signDeposit(funderKey, funder, manager, 25e6, "s1", validBefore);
        vm.expectEmit(true, true, false, true, address(depositor));
        emit CreditDepositedWithAuthorization(funder, manager, 25e6, 25e6);
        vm.prank(relayer);
        uint256 creditAfter = depositor.depositWithAuthorization(funder, manager, 25e6, 0, validBefore, "s1", sig);

        assertEq(creditAfter, 25e6);
        assertEq(bank.creditOf(manager), 25e6);
        assertEq(bank.totalCreditLiability(), 25e6);
        assertEq(token.balanceOf(address(bank)), 25e6);
        assertEq(token.balanceOf(funder), 75e6);
        assertEq(token.balanceOf(address(depositor)), 0);
        assertEq(token.allowance(address(depositor), address(bank)), 0);
        assertEq(token.balanceOf(relayer), 0);
    }

    function test_RevertWhen_DepositIsRedirectedToAnotherManager() public {
        uint256 validBefore = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signDeposit(funderKey, funder, manager, 25e6, "s1", validBefore);
        vm.prank(relayer);
        vm.expectRevert(MockUSDC.InvalidSignature.selector);
        depositor.depositWithAuthorization(funder, relayer, 25e6, 0, validBefore, "s1", sig);
    }

    function test_RevertWhen_DepositIsReplayed() public {
        uint256 validBefore = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signDeposit(funderKey, funder, manager, 25e6, "s1", validBefore);
        depositor.depositWithAuthorization(funder, manager, 25e6, 0, validBefore, "s1", sig);
        vm.expectRevert(MockUSDC.AuthorizationAlreadyUsed.selector);
        depositor.depositWithAuthorization(funder, manager, 25e6, 0, validBefore, "s1", sig);
        assertEq(bank.creditOf(manager), 25e6);
    }

    function test_RevertWhen_DepositAuthorizationExpired() public {
        uint256 validBefore = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signDeposit(funderKey, funder, manager, 25e6, "s1", validBefore);
        vm.warp(validBefore);
        vm.expectRevert(MockUSDC.AuthorizationExpired.selector);
        depositor.depositWithAuthorization(funder, manager, 25e6, 0, validBefore, "s1", sig);
    }

    function test_RevertWhen_DepositSignedByAnotherKey() public {
        uint256 validBefore = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signDeposit(strangerKey, funder, manager, 25e6, "s1", validBefore);
        vm.expectRevert(MockUSDC.InvalidSignature.selector);
        depositor.depositWithAuthorization(funder, manager, 25e6, 0, validBefore, "s1", sig);
    }

    function test_ContractWalletDepositsThroughErc1271() public {
        VaultV2ContractWallet safe = new VaultV2ContractWallet(funder);
        token.mint(address(safe), 10e6);
        uint256 validBefore = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signDeposit(funderKey, address(safe), address(safe), 10e6, "safe", validBefore);
        depositor.depositWithAuthorization(address(safe), address(safe), 10e6, 0, validBefore, "safe", sig);
        assertEq(bank.creditOf(address(safe)), 10e6);
    }

    function test_RevertWhen_DepositArgumentsAreInvalid() public {
        vm.expectRevert(SponsoredTaskFeeBankDepositor.ZeroAddress.selector);
        depositor.depositWithAuthorization(address(0), manager, 1, 0, vm.getBlockTimestamp(), "s", "");
        vm.expectRevert(SponsoredTaskFeeBankDepositor.ZeroAddress.selector);
        depositor.depositWithAuthorization(funder, address(0), 1, 0, vm.getBlockTimestamp(), "s", "");
        vm.expectRevert(SponsoredTaskFeeBankDepositor.InvalidAmount.selector);
        depositor.depositWithAuthorization(funder, manager, 0, 0, vm.getBlockTimestamp(), "s", "");
    }

    function test_ConstructorReadsTheFeeToken() public {
        assertEq(address(depositor.feeToken()), address(token));
        assertEq(address(depositor.feeBank()), address(bank));
        vm.expectRevert(SponsoredTaskFeeBankDepositor.ZeroAddress.selector);
        new SponsoredTaskFeeBankDepositor(ISponsoredTaskFeeBank(address(0)));
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskFeeBankDepositor.InvalidContract.selector, eoa));
        new SponsoredTaskFeeBankDepositor(ISponsoredTaskFeeBank(eoa));
    }
}
