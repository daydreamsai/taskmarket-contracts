// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { SponsoredTaskFeeBank } from "../src/hooks/sponsored-task/SponsoredTaskFeeBank.sol";
import { SponsoredTaskFeeBankGuard } from "../src/hooks/sponsored-task/SponsoredTaskFeeBankGuard.sol";
import { ISponsoredTaskFeeBank } from "../src/hooks/sponsored-task/interfaces/ISponsoredTaskFeeBank.sol";
import {
    DeployAndActivateSponsoredTaskFeeBankGuard,
    VerifySponsoredTaskFeeBankGuard
} from "../script/DeploySponsoredTaskFeeBankGuard.s.sol";

contract FeeBankGuardCharger {
    ISponsoredTaskFeeBank public immutable feeBank;

    constructor(ISponsoredTaskFeeBank bank_) {
        feeBank = bank_;
    }

    function charge(address manager, bytes32 key) external returns (ISponsoredTaskFeeBank.ChargeReceipt memory) {
        return feeBank.charge(manager, key);
    }
}

contract MutableFeeBankGuardCharger {
    ISponsoredTaskFeeBank public feeBank;

    constructor(ISponsoredTaskFeeBank bank_) {
        feeBank = bank_;
    }

    function setFeeBank(ISponsoredTaskFeeBank newBank) external {
        feeBank = newBank;
    }
}

/// @dev Code-bearing Safe/timelock stand-in. Access policy is outside the guard's unit-test scope.
contract FeeBankGuardAdminHarness {
    function activate(SponsoredTaskFeeBankGuard guard) external {
        guard.acceptFeeBankOwnership();
    }

    function setFutureFeeConfig(SponsoredTaskFeeBankGuard guard, uint256 amount, address recipient) external {
        guard.setFutureFeeConfig(amount, recipient);
    }

    function revokeCharger(SponsoredTaskFeeBankGuard guard, address charger) external {
        guard.revokeCharger(charger);
    }

    function transferGuardOwnership(SponsoredTaskFeeBankGuard guard, address newOwner) external {
        guard.transferOwnership(newOwner);
    }

    function acceptGuardOwnership(SponsoredTaskFeeBankGuard guard) external {
        guard.acceptOwnership();
    }

    function renounceGuardOwnership(SponsoredTaskFeeBankGuard guard) external pure {
        guard.renounceOwnership();
    }

    function callBankSetCharger(SponsoredTaskFeeBank bank, address charger, bool authorized) external {
        bank.setCharger(charger, authorized);
    }
}

contract FeeBankGuardDeploymentScriptHarness is DeployAndActivateSponsoredTaskFeeBankGuard {
    function assertRuntimeHash(address account, bytes32 expected) external view {
        _requireRuntimeHash(account, expected, "runtime mismatch");
    }
}

contract SponsoredTaskFeeBankGuardTest is Test {
    uint256 private constant DEFAULT_FEE = 1e6;
    uint256 private constant FEE_CEILING = 2e6;
    bytes32 private constant TASK_KEY = keccak256("guarded-sponsored-task");

    address private constant BOOTSTRAP_OWNER = address(0xA11CE);
    address private constant MANAGER = address(0xBEEF);
    address private constant RECIPIENT = address(0xDAD);
    address private constant NEXT_RECIPIENT = address(0xF00D);
    address private constant ATTACKER = address(0xBAD);

    MockERC20 private usdc;
    SponsoredTaskFeeBank private bank;
    FeeBankGuardCharger private hook;
    FeeBankGuardAdminHarness private admin;
    FeeBankGuardAdminHarness private successor;
    SponsoredTaskFeeBankGuard private guard;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6, address(this));
        bank = new SponsoredTaskFeeBank(BOOTSTRAP_OWNER, usdc, DEFAULT_FEE, RECIPIENT);
        hook = new FeeBankGuardCharger(bank);
        admin = new FeeBankGuardAdminHarness();
        successor = new FeeBankGuardAdminHarness();

        vm.prank(BOOTSTRAP_OWNER);
        bank.setCharger(address(hook), true);

        guard = new SponsoredTaskFeeBankGuard(address(admin), bank, address(hook), FEE_CEILING);
        vm.prank(BOOTSTRAP_OWNER);
        bank.transferOwnership(address(guard));
        admin.activate(guard);
    }

    function testActivationPinsExactBankHookCeilingAndContractAdmin() public view {
        assertEq(address(guard.feeBank()), address(bank));
        assertEq(guard.hook(), address(hook));
        assertEq(guard.feeCeiling(), FEE_CEILING);
        assertEq(guard.owner(), address(admin));
        assertTrue(guard.feeBankOwnershipAccepted());
        assertEq(bank.owner(), address(guard));
        assertEq(bank.pendingOwner(), address(0));
        assertTrue(bank.authorizedChargers(address(hook)));
    }

    function testActivationRequiresPendingFeeBankOwnership() public {
        SponsoredTaskFeeBank freshBank = _newBank(DEFAULT_FEE);
        FeeBankGuardCharger freshHook = new FeeBankGuardCharger(freshBank);
        vm.prank(BOOTSTRAP_OWNER);
        freshBank.setCharger(address(freshHook), true);
        SponsoredTaskFeeBankGuard freshGuard =
            new SponsoredTaskFeeBankGuard(address(admin), freshBank, address(freshHook), FEE_CEILING);

        vm.expectRevert(
            abi.encodeWithSelector(
                SponsoredTaskFeeBankGuard.FeeBankPendingOwnerMismatch.selector, address(freshGuard), address(0)
            )
        );
        admin.activate(freshGuard);
    }

    function testActivationRequiresExactHookAuthorizationAfterProposal() public {
        SponsoredTaskFeeBank freshBank = _newBank(DEFAULT_FEE);
        FeeBankGuardCharger freshHook = new FeeBankGuardCharger(freshBank);
        SponsoredTaskFeeBankGuard freshGuard =
            new SponsoredTaskFeeBankGuard(address(admin), freshBank, address(freshHook), FEE_CEILING);
        vm.prank(BOOTSTRAP_OWNER);
        freshBank.transferOwnership(address(freshGuard));

        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskFeeBankGuard.HookNotAuthorized.selector, address(freshHook))
        );
        admin.activate(freshGuard);

        assertEq(freshBank.owner(), BOOTSTRAP_OWNER);
        assertFalse(freshGuard.feeBankOwnershipAccepted());
    }

    function testActivationRechecksHookFeeBankLinkAfterProposal() public {
        SponsoredTaskFeeBank freshBank = _newBank(DEFAULT_FEE);
        SponsoredTaskFeeBank otherBank = _newBank(DEFAULT_FEE);
        MutableFeeBankGuardCharger mutableHook = new MutableFeeBankGuardCharger(freshBank);
        vm.prank(BOOTSTRAP_OWNER);
        freshBank.setCharger(address(mutableHook), true);
        SponsoredTaskFeeBankGuard freshGuard =
            new SponsoredTaskFeeBankGuard(address(admin), freshBank, address(mutableHook), FEE_CEILING);
        vm.prank(BOOTSTRAP_OWNER);
        freshBank.transferOwnership(address(freshGuard));
        mutableHook.setFeeBank(otherBank);

        vm.expectRevert(
            abi.encodeWithSelector(
                SponsoredTaskFeeBankGuard.HookFeeBankMismatch.selector, address(freshBank), address(otherBank)
            )
        );
        vm.prank(ATTACKER);
        freshGuard.acceptFeeBankOwnership();

        assertEq(freshBank.owner(), BOOTSTRAP_OWNER);
        assertFalse(freshGuard.feeBankOwnershipAccepted());
    }

    function testActivationRejectsCurrentFeeAboveImmutableCeiling() public {
        SponsoredTaskFeeBank freshBank = _newBank(DEFAULT_FEE);
        FeeBankGuardCharger freshHook = new FeeBankGuardCharger(freshBank);
        vm.prank(BOOTSTRAP_OWNER);
        freshBank.setCharger(address(freshHook), true);
        SponsoredTaskFeeBankGuard freshGuard =
            new SponsoredTaskFeeBankGuard(address(admin), freshBank, address(freshHook), DEFAULT_FEE - 1);
        vm.prank(BOOTSTRAP_OWNER);
        freshBank.transferOwnership(address(freshGuard));

        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskFeeBankGuard.FeeCeilingExceeded.selector, DEFAULT_FEE, DEFAULT_FEE - 1)
        );
        admin.activate(freshGuard);
    }

    function testAcceptanceIsPermissionlessAfterAllCommitmentChecksAndCannotReplay() public {
        SponsoredTaskFeeBank freshBank = _newBank(DEFAULT_FEE);
        FeeBankGuardCharger freshHook = new FeeBankGuardCharger(freshBank);
        vm.prank(BOOTSTRAP_OWNER);
        freshBank.setCharger(address(freshHook), true);
        SponsoredTaskFeeBankGuard freshGuard =
            new SponsoredTaskFeeBankGuard(address(admin), freshBank, address(freshHook), FEE_CEILING);
        vm.prank(BOOTSTRAP_OWNER);
        freshBank.transferOwnership(address(freshGuard));

        vm.prank(ATTACKER);
        freshGuard.acceptFeeBankOwnership();
        assertEq(freshBank.owner(), address(freshGuard));
        assertEq(freshGuard.owner(), address(admin));
        assertTrue(freshGuard.feeBankOwnershipAccepted());

        vm.expectRevert(SponsoredTaskFeeBankGuard.AlreadyAcceptedFeeBankOwnership.selector);
        vm.prank(ATTACKER);
        freshGuard.acceptFeeBankOwnership();
    }

    function testGuardedFeeUpdateCannotExceedCeilingAndUsesBankRecipientRules() public {
        admin.setFutureFeeConfig(guard, FEE_CEILING, NEXT_RECIPIENT);
        assertEq(bank.feeAmount(), FEE_CEILING);
        assertEq(bank.feeRecipient(), NEXT_RECIPIENT);

        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskFeeBankGuard.FeeCeilingExceeded.selector, FEE_CEILING + 1, FEE_CEILING)
        );
        admin.setFutureFeeConfig(guard, FEE_CEILING + 1, NEXT_RECIPIENT);

        vm.expectRevert(ISponsoredTaskFeeBank.FeeRecipientRequired.selector);
        admin.setFutureFeeConfig(guard, 1, address(0));

        vm.expectRevert(ISponsoredTaskFeeBank.FeeRecipientIsBank.selector);
        admin.setFutureFeeConfig(guard, 1, address(bank));

        admin.setFutureFeeConfig(guard, 0, address(0));
        assertEq(bank.feeAmount(), 0);
        assertEq(bank.feeRecipient(), address(0));
    }

    function testUnauthorizedCallerCannotChangeFeeOrRevokeCharger() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ATTACKER));
        vm.prank(ATTACKER);
        guard.setFutureFeeConfig(0, address(0));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ATTACKER));
        vm.prank(ATTACKER);
        guard.revokeCharger(address(hook));
    }

    function testConfigurationAndRevocationRequireAcceptedControl() public {
        SponsoredTaskFeeBank freshBank = _newBank(DEFAULT_FEE);
        FeeBankGuardCharger freshHook = new FeeBankGuardCharger(freshBank);
        SponsoredTaskFeeBankGuard freshGuard =
            new SponsoredTaskFeeBankGuard(address(admin), freshBank, address(freshHook), FEE_CEILING);

        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskFeeBankGuard.FeeBankNotControlled.selector, BOOTSTRAP_OWNER)
        );
        admin.setFutureFeeConfig(freshGuard, 0, address(0));

        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskFeeBankGuard.FeeBankNotControlled.selector, BOOTSTRAP_OWNER)
        );
        admin.revokeCharger(freshGuard, address(freshHook));
    }

    function testExactHookKeepsChargingAfterActivation() public {
        usdc.mint(MANAGER, DEFAULT_FEE);
        vm.startPrank(MANAGER);
        usdc.approve(address(bank), DEFAULT_FEE);
        bank.deposit(DEFAULT_FEE);
        vm.stopPrank();

        hook.charge(MANAGER, TASK_KEY);

        assertTrue(bank.isCharged(TASK_KEY));
        assertEq(bank.creditOf(MANAGER), 0);
        assertEq(usdc.balanceOf(RECIPIENT), DEFAULT_FEE);
    }

    function testHookRevocationIsOneWayAndStopsCharges() public {
        admin.revokeCharger(guard, address(hook));
        assertFalse(bank.authorizedChargers(address(hook)));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(admin)));
        admin.callBankSetCharger(bank, address(hook), true);

        (bool setChargerCallSucceeded,) =
            address(guard).call(abi.encodeWithSignature("setCharger(address,bool)", address(hook), true));
        assertFalse(setChargerCallSucceeded);

        vm.expectRevert(abi.encodeWithSelector(ISponsoredTaskFeeBank.UnauthorizedCharger.selector, address(hook)));
        hook.charge(MANAGER, TASK_KEY);
    }

    function testAnyKnownPreauthorizedChargerCanBeRevokedButCannotBeEnumerated() public {
        SponsoredTaskFeeBank freshBank = _newBank(DEFAULT_FEE);
        FeeBankGuardCharger freshHook = new FeeBankGuardCharger(freshBank);
        FeeBankGuardCharger rogue = new FeeBankGuardCharger(freshBank);
        vm.startPrank(BOOTSTRAP_OWNER);
        freshBank.setCharger(address(freshHook), true);
        freshBank.setCharger(address(rogue), true);
        vm.stopPrank();

        SponsoredTaskFeeBankGuard freshGuard =
            new SponsoredTaskFeeBankGuard(address(admin), freshBank, address(freshHook), FEE_CEILING);
        vm.prank(BOOTSTRAP_OWNER);
        freshBank.transferOwnership(address(freshGuard));
        admin.activate(freshGuard);

        // Acceptance can prove the exact Hook is authorized, but the FeeBank exposes no charger list.
        assertTrue(freshBank.authorizedChargers(address(rogue)));
        admin.revokeCharger(freshGuard, address(rogue));
        assertFalse(freshBank.authorizedChargers(address(rogue)));
        assertTrue(freshBank.authorizedChargers(address(freshHook)));
    }

    function testNoArbitraryExecutionOrFeeBankOwnershipTransferPath() public {
        (bool executeSucceeded,) =
            address(guard).call(abi.encodeWithSignature("execute(address,uint256,bytes)", address(bank), 0, bytes("")));
        assertFalse(executeSucceeded);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ATTACKER));
        vm.prank(ATTACKER);
        bank.transferOwnership(ATTACKER);

        assertEq(bank.owner(), address(guard));
        assertEq(bank.pendingOwner(), address(0));
    }

    function testGuardOwnershipRotationRequiresAnotherContractAndTwoSteps() public {
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskFeeBankGuard.AdminMustBeContract.selector, ATTACKER));
        admin.transferGuardOwnership(guard, ATTACKER);

        admin.transferGuardOwnership(guard, address(successor));
        assertEq(guard.owner(), address(admin));
        assertEq(guard.pendingOwner(), address(successor));

        successor.acceptGuardOwnership(guard);
        assertEq(guard.owner(), address(successor));
        assertEq(guard.pendingOwner(), address(0));

        successor.setFutureFeeConfig(guard, FEE_CEILING, NEXT_RECIPIENT);
        assertEq(bank.feeAmount(), FEE_CEILING);
    }

    function testPendingGuardOwnershipTransferCanBeCancelled() public {
        admin.transferGuardOwnership(guard, address(successor));
        admin.transferGuardOwnership(guard, address(0));
        assertEq(guard.owner(), address(admin));
        assertEq(guard.pendingOwner(), address(0));
    }

    function testPendingGuardAdminCodeIsRecheckedAtAcceptance() public {
        admin.transferGuardOwnership(guard, address(successor));
        vm.etch(address(successor), bytes(""));

        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskFeeBankGuard.AdminMustBeContract.selector, address(successor))
        );
        vm.prank(address(successor));
        guard.acceptOwnership();

        assertEq(guard.owner(), address(admin));
        assertEq(guard.pendingOwner(), address(successor));
    }

    function testRenouncingGuardOwnershipIsDisabled() public {
        vm.expectRevert(SponsoredTaskFeeBankGuard.OwnershipRenunciationDisabled.selector);
        admin.renounceGuardOwnership(guard);
        assertEq(guard.owner(), address(admin));
    }

    function testConstructorRejectsEOAAdminAndNonContracts() public {
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskFeeBankGuard.AdminMustBeContract.selector, ATTACKER));
        new SponsoredTaskFeeBankGuard(ATTACKER, bank, address(hook), FEE_CEILING);

        vm.expectRevert(SponsoredTaskFeeBankGuard.FeeBankRequired.selector);
        new SponsoredTaskFeeBankGuard(
            address(admin), SponsoredTaskFeeBank(payable(address(0x1234))), address(hook), FEE_CEILING
        );

        vm.expectRevert(SponsoredTaskFeeBankGuard.HookRequired.selector);
        new SponsoredTaskFeeBankGuard(address(admin), bank, address(0x1234), FEE_CEILING);
    }

    function testConstructorRequiresHookGetterToLinkTheExactFeeBank() public {
        SponsoredTaskFeeBank otherBank = _newBank(DEFAULT_FEE);
        FeeBankGuardCharger mismatchedHook = new FeeBankGuardCharger(otherBank);

        vm.expectRevert(
            abi.encodeWithSelector(
                SponsoredTaskFeeBankGuard.HookFeeBankMismatch.selector, address(bank), address(otherBank)
            )
        );
        new SponsoredTaskFeeBankGuard(address(admin), bank, address(mismatchedHook), FEE_CEILING);

        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskFeeBankGuard.HookFeeBankQueryFailed.selector, address(admin))
        );
        new SponsoredTaskFeeBankGuard(address(successor), bank, address(admin), FEE_CEILING);
    }

    function testDeploymentRuntimePinRejectsLookalikeOrMisbinding() public {
        FeeBankGuardDeploymentScriptHarness harness = new FeeBankGuardDeploymentScriptHarness();
        harness.assertRuntimeHash(address(hook), address(hook).codehash);

        vm.expectRevert("runtime mismatch");
        harness.assertRuntimeHash(address(hook), bytes32(uint256(1)));

        vm.expectRevert("runtime mismatch");
        harness.assertRuntimeHash(address(bank), address(hook).codehash);
    }

    function testFuzzFutureFeeNeverExceedsCeiling(uint256 requested) public {
        requested = bound(requested, 0, FEE_CEILING);
        address recipient = requested == 0 ? address(0) : NEXT_RECIPIENT;
        admin.setFutureFeeConfig(guard, requested, recipient);
        assertEq(bank.feeAmount(), requested);
        assertLe(bank.feeAmount(), guard.feeCeiling());
    }

    function _newBank(uint256 feeAmount) private returns (SponsoredTaskFeeBank freshBank) {
        freshBank = new SponsoredTaskFeeBank(BOOTSTRAP_OWNER, usdc, feeAmount, RECIPIENT);
    }
}

contract SponsoredTaskFeeBankGuardDeploymentScriptTest is Test {
    uint256 private constant DEFAULT_FEE = 1e6;
    uint256 private constant FEE_CEILING = 2e6;
    address private constant BOOTSTRAP_OWNER = address(0xA11CE);
    address private constant RECIPIENT = address(0xDAD);

    MockERC20 private usdc;
    SponsoredTaskFeeBank private bank;
    FeeBankGuardCharger private hook;
    FeeBankGuardAdminHarness private admin;

    function setUp() public {
        vm.chainId(8453);
        vm.deal(BOOTSTRAP_OWNER, 100 ether);
        usdc = new MockERC20("Mock USDC", "USDC", 6, address(this));
        bank = new SponsoredTaskFeeBank(BOOTSTRAP_OWNER, usdc, DEFAULT_FEE, RECIPIENT);
        hook = new FeeBankGuardCharger(bank);
        admin = new FeeBankGuardAdminHarness();

        vm.startPrank(BOOTSTRAP_OWNER);
        bank.setCharger(address(hook), true);
        // Mirrors the existing Base deploy script's pending final-owner state.
        bank.transferOwnership(address(admin));
        vm.stopPrank();

        vm.setEnv("SPONSORED_TASK_BASE_FEE_BANK", vm.toString(address(bank)));
        vm.setEnv("SPONSORED_TASK_BASE_HOOK", vm.toString(address(hook)));
        vm.setEnv("SPONSORED_TASK_ADMIN_SENDER", vm.toString(BOOTSTRAP_OWNER));
        vm.setEnv("SPONSORED_TASK_FEE_BANK_GUARD_ADMIN", vm.toString(address(admin)));
        vm.setEnv("SPONSORED_TASK_CREATION_FEE_CEILING_USDC_BASE_UNITS", vm.toString(FEE_CEILING));
        vm.setEnv("SPONSORED_TASK_EXPECTED_FEE_BANK_RUNTIME_HASH", vm.toString(address(bank).codehash));
        vm.setEnv("SPONSORED_TASK_EXPECTED_HOOK_RUNTIME_HASH", vm.toString(address(hook).codehash));
        SponsoredTaskFeeBankGuard runtimeReference =
            new SponsoredTaskFeeBankGuard(address(admin), bank, address(hook), FEE_CEILING);
        vm.setEnv(
            "SPONSORED_TASK_EXPECTED_FEE_BANK_GUARD_RUNTIME_HASH", vm.toString(address(runtimeReference).codehash)
        );
    }

    function testMainnetScriptDeploysPinsAndActivates() public {
        SponsoredTaskFeeBankGuard guard = new DeployAndActivateSponsoredTaskFeeBankGuard().run();

        assertEq(guard.owner(), address(admin));
        assertEq(address(guard.feeBank()), address(bank));
        assertEq(guard.hook(), address(hook));
        assertEq(guard.feeCeiling(), FEE_CEILING);
        assertEq(bank.owner(), address(guard));
        assertEq(bank.pendingOwner(), address(0));
        assertTrue(guard.feeBankOwnershipAccepted());

        vm.setEnv("SPONSORED_TASK_FEE_BANK_GUARD", vm.toString(address(guard)));
        new VerifySponsoredTaskFeeBankGuard().run();
    }

    function testDeploymentScriptRefusesNonMainnet() public {
        vm.chainId(84_532);
        DeployAndActivateSponsoredTaskFeeBankGuard deploymentScript = new DeployAndActivateSponsoredTaskFeeBankGuard();
        vm.expectRevert("Sponsored Task guard: Base Mainnet only");
        deploymentScript.run();
    }

    function testDeploymentScriptRefusesUnexpectedPendingOwner() public {
        vm.prank(BOOTSTRAP_OWNER);
        bank.transferOwnership(address(0xBAD));
        DeployAndActivateSponsoredTaskFeeBankGuard deploymentScript = new DeployAndActivateSponsoredTaskFeeBankGuard();
        vm.expectRevert("Sponsored Task guard: unexpected pending owner");
        deploymentScript.run();
    }

    function testDeploymentScriptRejectsHookRuntimeMisbinding() public {
        vm.etch(address(hook), hex"00");
        DeployAndActivateSponsoredTaskFeeBankGuard deploymentScript = new DeployAndActivateSponsoredTaskFeeBankGuard();
        vm.expectRevert("Sponsored Task guard: Hook runtime mismatch");
        deploymentScript.run();
    }

    function testDeploymentScriptRejectsFeeBankRuntimeMisbinding() public {
        vm.etch(address(bank), hex"00");
        DeployAndActivateSponsoredTaskFeeBankGuard deploymentScript = new DeployAndActivateSponsoredTaskFeeBankGuard();
        vm.expectRevert("Sponsored Task guard: FeeBank runtime mismatch");
        deploymentScript.run();
    }

    function testPermissionlessDepositCannotBlockGuardActivation() public {
        usdc.mint(BOOTSTRAP_OWNER, DEFAULT_FEE);
        vm.startPrank(BOOTSTRAP_OWNER);
        usdc.approve(address(bank), DEFAULT_FEE);
        bank.deposit(DEFAULT_FEE);
        vm.stopPrank();

        SponsoredTaskFeeBankGuard guard = new DeployAndActivateSponsoredTaskFeeBankGuard().run();

        assertEq(bank.owner(), address(guard));
        assertTrue(guard.feeBankOwnershipAccepted());
        assertEq(bank.creditOf(BOOTSTRAP_OWNER), DEFAULT_FEE);
        assertEq(bank.totalCreditLiability(), DEFAULT_FEE);
    }
}
