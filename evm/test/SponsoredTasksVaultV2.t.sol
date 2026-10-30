// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { SponsoredTaskTypes } from "../src/hooks/sponsored-task/SponsoredTaskTypes.sol";
import { SponsoredTaskFactoryV2 } from "../src/hooks/sponsored-task/SponsoredTaskFactoryV2.sol";
import { SponsoredTaskFeeConfig } from "./helpers/SponsoredTaskFeeConfig.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTasksVaultV2 } from "../src/hooks/sponsored-task/SponsoredTasksVaultV2.sol";

contract VaultV2ControllerStandIn { }

/// @dev A token whose receive policy delivers a transfer to another address than the one named, as a
///      Tempo TIP-20 receive policy or a forwarding address can.
contract VaultV2RedirectingToken is ERC20 {
    mapping(address => address) public redirectOf;

    constructor() ERC20("Redirecting token", "RDR") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRedirect(address from, address to) external {
        redirectOf[from] = to;
    }

    function _update(address from, address to, uint256 value) internal override {
        address target = redirectOf[to];
        super._update(from, target == address(0) ? to : target, value);
    }
}

/// @dev A contract wallet (a Safe stand-in) that accepts an ERC-1271 signature from its one key.
contract VaultV2ContractWallet {
    address public immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        return err == ECDSA.RecoverError.NoError && recovered == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @notice Shared vault v2 setup: a v2 factory over MockUSDC (EIP-3009 with ERC-1271 support).
abstract contract VaultV2Base is Test {
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    uint256 internal ownerKey = 0xA11CE;
    address internal vaultOwner;
    uint256 internal funderKey = 0xF00D;
    address internal funder;
    uint256 internal strangerKey = 0xBAD;
    address internal relayer = makeAddr("relayer");
    address internal recipient = makeAddr("recipient");
    address internal manager = makeAddr("manager");
    address internal feeRecipient = makeAddr("feeRecipient");

    MockUSDC internal token;
    SponsoredTaskFeePolicy internal policy;
    SponsoredTaskRegistry internal registry;
    SponsoredTaskFactoryV2 internal factory;
    address internal controller;

    function setUp() public virtual {
        vaultOwner = vm.addr(ownerKey);
        funder = vm.addr(funderKey);
        controller = address(new VaultV2ControllerStandIn());
        token = new MockUSDC();
        policy = new SponsoredTaskFeePolicy(address(this), 50, feeRecipient);
        registry = new SponsoredTaskRegistry(address(this));
        factory = new SponsoredTaskFactoryV2(
            controller, address(policy), registry, SponsoredTaskFeeConfig.none(IERC20(address(token)))
        );
        registry.setFactory(address(factory), true);
        vm.warp(1_000_000);
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _usdcDigest(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("USD Coin")),
                keccak256(bytes("2")),
                block.chainid,
                address(token)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _receiveAuthorization(
        uint256 key,
        address from,
        address to,
        uint256 value,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, 0, validBefore, nonce)
        );
        return _sign(key, _usdcDigest(structHash));
    }
}

contract SponsoredTasksVaultV2Test is VaultV2Base {
    SponsoredTasksVaultV2 internal vault;

    event VaultFunded(address indexed funder, uint256 amount);
    event AvailableWithdrawn(address indexed owner, address indexed recipient, uint256 amount);
    event ManagerConfigured(address indexed manager, uint256 cap, uint256 reserved, uint256 spent, bool active);
    event OwnerSignatureUsed(address indexed owner, uint256 indexed nonce);

    function setUp() public override {
        super.setUp();
        (address vaultAddress,) = factory.createVault(address(token), vaultOwner, keccak256("v2"));
        vault = SponsoredTasksVaultV2(vaultAddress);
        token.mint(funder, 1_000e6);
    }

    // ---- signing helpers -------------------------------------------------------------------

    function _configureSig(uint256 key, address m, uint256 cap, bool active, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(vault.CONFIGURE_MANAGER_TYPEHASH(), vault.vaultId(), m, cap, active, nonce, deadline)
        );
        return _sign(key, vault.ownerActionDigest(structHash));
    }

    function _withdrawSig(uint256 key, address to, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(vault.WITHDRAW_AVAILABLE_TYPEHASH(), vault.vaultId(), to, amount, nonce, deadline)
        );
        return _sign(key, vault.ownerActionDigest(structHash));
    }

    function _exitSig(uint256 key, address to, uint256 nonce, uint256 deadline) internal view returns (bytes memory) {
        bytes32 structHash =
            keccak256(abi.encode(vault.EMERGENCY_EXIT_TYPEHASH(), vault.vaultId(), to, nonce, deadline));
        return _sign(key, vault.ownerActionDigest(structHash));
    }

    function _fundWithAuthorization(uint256 amount, bytes32 nonce) internal {
        bytes memory sig =
            _receiveAuthorization(funderKey, funder, address(vault), amount, vm.getBlockTimestamp() + 1 hours, nonce);
        vm.prank(relayer);
        vault.fundWithAuthorization(funder, amount, 0, vm.getBlockTimestamp() + 1 hours, nonce, sig);
    }

    // ---- identity ---------------------------------------------------------------------------

    function test_FactoryClonesTheV2Implementation() public view {
        assertEq(vault.VAULT_VERSION(), 2);
        assertEq(vault.owner(), vaultOwner);
        assertEq(vault.ownerNonce(), 0);
        assertEq(uint256(vault.status()), uint256(SponsoredTaskTypes.VaultStatus.Active));
    }

    // ---- signed owner actions ---------------------------------------------------------------

    function test_ConfigureManagerBySig_RelayerSubmitsTheOwnersAction() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _configureSig(ownerKey, manager, 500e6, true, 0, deadline);
        vm.expectEmit(true, true, false, false, address(vault));
        emit OwnerSignatureUsed(vaultOwner, 0);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ManagerConfigured(manager, 500e6, 0, 0, true);
        vm.prank(relayer);
        vault.configureManagerBySig(manager, 500e6, true, deadline, sig);

        SponsoredTaskTypes.ManagerAccount memory account = vault.managerAccount(manager);
        assertEq(account.cap, 500e6);
        assertTrue(account.active);
        assertEq(vault.ownerNonce(), 1);
    }

    function test_RevertWhen_SignedActionIsReplayed() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _configureSig(ownerKey, manager, 500e6, true, 0, deadline);
        vault.configureManagerBySig(manager, 500e6, true, deadline, sig);
        vm.expectRevert(SponsoredTasksVaultV2.InvalidOwnerSignature.selector);
        vault.configureManagerBySig(manager, 500e6, true, deadline, sig);
    }

    function test_RevertWhen_SignedActionIsPastItsDeadline() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _configureSig(ownerKey, manager, 500e6, true, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVaultV2.OwnerSignatureExpired.selector, deadline));
        vault.configureManagerBySig(manager, 500e6, true, deadline, sig);
    }

    function test_SignedActionIsValidAtItsDeadline() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _configureSig(ownerKey, manager, 1, true, 0, deadline);
        vm.warp(deadline);
        vault.configureManagerBySig(manager, 1, true, deadline, sig);
        assertEq(vault.ownerNonce(), 1);
    }

    function test_RevertWhen_SignedByAnotherKey() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _configureSig(strangerKey, manager, 500e6, true, 0, deadline);
        vm.expectRevert(SponsoredTasksVaultV2.InvalidOwnerSignature.selector);
        vault.configureManagerBySig(manager, 500e6, true, deadline, sig);
    }

    function test_RevertWhen_SignedFieldsAreChanged() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _configureSig(ownerKey, manager, 500e6, true, 0, deadline);
        vm.expectRevert(SponsoredTasksVaultV2.InvalidOwnerSignature.selector);
        vault.configureManagerBySig(manager, 900e6, true, deadline, sig);
        vm.expectRevert(SponsoredTasksVaultV2.InvalidOwnerSignature.selector);
        vault.configureManagerBySig(relayer, 500e6, true, deadline, sig);
    }

    function test_RevertWhen_SignatureIsForAnotherVault() public {
        (address otherAddress,) = factory.createVault(address(token), vaultOwner, keccak256("other"));
        SponsoredTasksVaultV2 other = SponsoredTasksVaultV2(otherAddress);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _configureSig(ownerKey, manager, 500e6, true, 0, deadline);
        vm.expectRevert(SponsoredTasksVaultV2.InvalidOwnerSignature.selector);
        other.configureManagerBySig(manager, 500e6, true, deadline, sig);
    }

    function test_RevertWhen_SignerIsNoLongerTheOwner() public {
        uint256 newOwnerKey = 0xC0FFEE;
        address newOwner = vm.addr(newOwnerKey);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory oldOwnerSig = _configureSig(ownerKey, manager, 500e6, true, 0, deadline);
        vm.prank(vaultOwner);
        vault.transferOwnership(newOwner);
        vm.prank(newOwner);
        vault.acceptOwnership();

        vm.expectRevert(SponsoredTasksVaultV2.InvalidOwnerSignature.selector);
        vault.configureManagerBySig(manager, 500e6, true, deadline, oldOwnerSig);
        vault.configureManagerBySig(
            manager, 500e6, true, deadline, _configureSig(newOwnerKey, manager, 500e6, true, 1, deadline)
        );
        assertEq(vault.managerAccount(manager).cap, 500e6);
    }

    function _handOver(address from, address to) internal {
        vm.prank(from);
        vault.transferOwnership(to);
        vm.prank(to);
        vault.acceptOwnership();
    }

    function test_AcceptOwnershipAdvancesTheNonce() public {
        address newOwner = vm.addr(0xC0FFEE);
        vm.prank(vaultOwner);
        vault.transferOwnership(newOwner);
        assertEq(vault.ownerNonce(), 0);
        vm.expectEmit(true, true, false, false, address(vault));
        emit OwnerSignatureUsed(vaultOwner, 0);
        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.ownerNonce(), 1);
    }

    function test_PendingTransferKeepsTheOwnersSignaturesValid() public {
        address newOwner = vm.addr(0xC0FFEE);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _configureSig(ownerKey, manager, 500e6, true, 0, deadline);
        vm.prank(vaultOwner);
        vault.transferOwnership(newOwner);
        vault.configureManagerBySig(manager, 500e6, true, deadline, sig);
        assertEq(vault.managerAccount(manager).cap, 500e6);
    }

    function test_RevertWhen_FormerOwnerSignatureIsReplayedAfterOwnershipReturns() public {
        uint256 otherKey = 0xC0FFEE;
        address other = vm.addr(otherKey);
        vm.prank(funder);
        token.approve(address(vault), 100e6);
        vm.prank(funder);
        vault.fund(100e6);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory staleSig = _withdrawSig(ownerKey, vaultOwner, 100e6, 0, deadline);

        _handOver(vaultOwner, other);
        _handOver(other, vaultOwner);
        assertEq(vault.owner(), vaultOwner);
        assertEq(vault.ownerNonce(), 2);

        vm.expectRevert(SponsoredTasksVaultV2.InvalidOwnerSignature.selector);
        vault.withdrawAvailableBySig(vaultOwner, 100e6, deadline, staleSig);

        vault.withdrawAvailableBySig(
            vaultOwner, 100e6, deadline, _withdrawSig(ownerKey, vaultOwner, 100e6, 2, deadline)
        );
        assertEq(vault.ownerNonce(), 3);
    }

    function test_CancelOwnerSignaturesRevokesOutstandingActions() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _configureSig(ownerKey, manager, 500e6, true, 0, deadline);
        vm.prank(vaultOwner);
        vault.cancelOwnerSignatures();
        assertEq(vault.ownerNonce(), 1);
        vm.expectRevert(SponsoredTasksVaultV2.InvalidOwnerSignature.selector);
        vault.configureManagerBySig(manager, 500e6, true, deadline, sig);
    }

    function test_RevertWhen_NonOwnerCancelsSignatures() public {
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, relayer));
        vault.cancelOwnerSignatures();
    }

    function test_WithdrawAvailableBySig_PaysTheSignedRecipient() public {
        _fundWithAuthorization(100e6, keccak256("fund-1"));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _withdrawSig(ownerKey, recipient, 40e6, 0, deadline);
        vm.expectEmit(true, true, false, true, address(vault));
        emit AvailableWithdrawn(vaultOwner, recipient, 40e6);
        vm.prank(relayer);
        vault.withdrawAvailableBySig(recipient, 40e6, deadline, sig);
        assertEq(token.balanceOf(recipient), 40e6);
        assertEq(token.balanceOf(relayer), 0);
        assertEq(vault.totalWithdrawn(), 40e6);
        assertEq(vault.available(), 60e6);
    }

    function test_RevertWhen_WithdrawSigIsRedirected() public {
        _fundWithAuthorization(100e6, keccak256("fund-1"));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _withdrawSig(ownerKey, recipient, 40e6, 0, deadline);
        vm.prank(relayer);
        vm.expectRevert(SponsoredTasksVaultV2.InvalidOwnerSignature.selector);
        vault.withdrawAvailableBySig(relayer, 40e6, deadline, sig);
    }

    function test_EmergencyExitVaultBySig_ClosesTheVault() public {
        _fundWithAuthorization(100e6, keccak256("fund-1"));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _exitSig(ownerKey, recipient, 0, deadline);
        vm.prank(relayer);
        uint256 amount = vault.emergencyExitVaultBySig(recipient, deadline, sig);
        assertEq(amount, 100e6);
        assertEq(token.balanceOf(recipient), 100e6);
        assertEq(uint256(vault.status()), uint256(SponsoredTaskTypes.VaultStatus.Exited));
        assertEq(vault.epoch(), 2);

        // Exited: every signed action is refused, whatever its signature.
        bytes memory next = _configureSig(ownerKey, manager, 1, true, 1, deadline);
        vm.expectRevert(SponsoredTasksVaultV2.VaultNotActive.selector);
        vault.configureManagerBySig(manager, 1, true, deadline, next);
    }

    // ---- ERC-1271 owner (a Safe) --------------------------------------------------------------

    function test_ContractWalletOwnerSignsThroughErc1271() public {
        VaultV2ContractWallet safe = new VaultV2ContractWallet(vm.addr(ownerKey));
        (address safeVaultAddress,) = factory.createVault(address(token), address(safe), keccak256("safe"));
        SponsoredTasksVaultV2 safeVault = SponsoredTasksVaultV2(safeVaultAddress);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(safeVault.CONFIGURE_MANAGER_TYPEHASH(), safeVault.vaultId(), manager, 7, true, 0, deadline)
        );
        bytes memory sig = _sign(ownerKey, safeVault.ownerActionDigest(structHash));
        vm.prank(relayer);
        safeVault.configureManagerBySig(manager, 7, true, deadline, sig);
        assertEq(safeVault.managerAccount(manager).cap, 7);

        bytes memory bad = _sign(strangerKey, safeVault.ownerActionDigest(structHash));
        vm.expectRevert(SponsoredTasksVaultV2.InvalidOwnerSignature.selector);
        safeVault.configureManagerBySig(manager, 7, true, deadline, bad);
    }

    // ---- EIP-3009 funding ---------------------------------------------------------------------

    function test_FundWithAuthorization_RecordsTheFunderNotTheRelayer() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit VaultFunded(funder, 250e6);
        _fundWithAuthorization(250e6, keccak256("fund-1"));
        assertEq(vault.totalFunded(), 250e6);
        assertEq(vault.available(), 250e6);
        assertEq(token.balanceOf(address(vault)), 250e6);
        assertEq(token.balanceOf(funder), 750e6);
        assertEq(token.balanceOf(relayer), 0);
    }

    function test_FundWithAuthorizationAndFundAccumulateTotalFunded() public {
        _fundWithAuthorization(100e6, keccak256("fund-1"));
        vm.startPrank(funder);
        token.approve(address(vault), 50e6);
        vault.fund(50e6);
        vm.stopPrank();
        assertEq(vault.totalFunded(), 150e6);
    }

    function test_RevertWhen_FundingAuthorizationIsReplayed() public {
        bytes32 nonce = keccak256("fund-1");
        bytes memory sig =
            _receiveAuthorization(funderKey, funder, address(vault), 10e6, vm.getBlockTimestamp() + 1 hours, nonce);
        vault.fundWithAuthorization(funder, 10e6, 0, vm.getBlockTimestamp() + 1 hours, nonce, sig);
        vm.expectRevert(MockUSDC.AuthorizationAlreadyUsed.selector);
        vault.fundWithAuthorization(funder, 10e6, 0, vm.getBlockTimestamp() + 1 hours, nonce, sig);
        assertEq(vault.totalFunded(), 10e6);
    }

    function test_RevertWhen_FundingAuthorizationExpired() public {
        bytes32 nonce = keccak256("fund-1");
        uint256 validBefore = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _receiveAuthorization(funderKey, funder, address(vault), 10e6, validBefore, nonce);
        vm.warp(validBefore);
        vm.expectRevert(MockUSDC.AuthorizationExpired.selector);
        vault.fundWithAuthorization(funder, 10e6, 0, validBefore, nonce, sig);
    }

    function test_RevertWhen_FundingAuthorizationIsSignedByAnotherKey() public {
        bytes32 nonce = keccak256("fund-1");
        bytes memory sig =
            _receiveAuthorization(strangerKey, funder, address(vault), 10e6, vm.getBlockTimestamp() + 1 hours, nonce);
        vm.expectRevert(MockUSDC.InvalidSignature.selector);
        vault.fundWithAuthorization(funder, 10e6, 0, vm.getBlockTimestamp() + 1 hours, nonce, sig);
    }

    function test_RevertWhen_FundingAuthorizationNamesAnotherVault() public {
        (address otherAddress,) = factory.createVault(address(token), vaultOwner, keccak256("other"));
        bytes32 nonce = keccak256("fund-1");
        bytes memory sig =
            _receiveAuthorization(funderKey, funder, otherAddress, 10e6, vm.getBlockTimestamp() + 1 hours, nonce);
        vm.expectRevert(MockUSDC.InvalidSignature.selector);
        vault.fundWithAuthorization(funder, 10e6, 0, vm.getBlockTimestamp() + 1 hours, nonce, sig);
    }

    function test_RevertWhen_FundingAmountIsZeroOrFunderIsZero() public {
        vm.expectRevert(SponsoredTasksVaultV2.GrossAmountRequired.selector);
        vault.fundWithAuthorization(funder, 0, 0, vm.getBlockTimestamp() + 1 hours, bytes32(0), "");
        vm.expectRevert(SponsoredTasksVaultV2.ZeroAddress.selector);
        vault.fundWithAuthorization(address(0), 1, 0, vm.getBlockTimestamp() + 1 hours, bytes32(0), "");
    }

    function test_ContractWalletFundsThroughErc1271() public {
        VaultV2ContractWallet safe = new VaultV2ContractWallet(vm.addr(funderKey));
        token.mint(address(safe), 30e6);
        bytes32 nonce = keccak256("safe-fund");
        bytes memory sig = _receiveAuthorization(
            funderKey, address(safe), address(vault), 30e6, vm.getBlockTimestamp() + 1 hours, nonce
        );
        vm.expectEmit(true, false, false, true, address(vault));
        emit VaultFunded(address(safe), 30e6);
        vm.prank(relayer);
        vault.fundWithAuthorization(address(safe), 30e6, 0, vm.getBlockTimestamp() + 1 hours, nonce, sig);
        assertEq(vault.totalFunded(), 30e6);
    }

    function test_RevertWhen_VaultExitedBeforeFunding() public {
        vm.prank(vaultOwner);
        vault.emergencyExitVault(recipient);
        bytes32 nonce = keccak256("fund-1");
        bytes memory sig =
            _receiveAuthorization(funderKey, funder, address(vault), 10e6, vm.getBlockTimestamp() + 1 hours, nonce);
        vm.expectRevert(SponsoredTasksVaultV2.VaultNotActive.selector);
        vault.fundWithAuthorization(funder, 10e6, 0, vm.getBlockTimestamp() + 1 hours, nonce, sig);
    }

    // ---- v1 entry points are unchanged ----------------------------------------------------------

    function test_OwnerCallsStillWorkDirectly() public {
        _fundWithAuthorization(100e6, keccak256("fund-1"));
        vm.startPrank(vaultOwner);
        vault.configureManager(manager, 10e6, true);
        vault.withdrawAvailable(recipient, 5e6);
        vm.stopPrank();
        assertEq(vault.managerAccount(manager).cap, 10e6);
        assertEq(token.balanceOf(recipient), 5e6);
        assertEq(vault.ownerNonce(), 0);
    }
}

/// @notice Vault v2 under a redirecting receive policy. Every outgoing path checks the named
///         recipient's balance, so a redirect reverts the whole call: nothing leaves the vault, no
///         claim is marked, and a relayed owner signature is not used up, so the same signature
///         works once the destination stops redirecting.
contract SponsoredTasksVaultV2RedirectTest is VaultV2Base {
    uint16 internal constant FEE_BPS = 50;
    bytes32 internal constant TERMS_HASH = keccak256("v2-redirect-terms");

    VaultV2RedirectingToken internal rToken;
    SponsoredTasksVaultV2 internal vault;
    address internal elsewhere = makeAddr("redirectTarget");

    function setUp() public override {
        super.setUp();
        rToken = new VaultV2RedirectingToken();
        (address vaultAddress,) = factory.createVault(address(rToken), vaultOwner, keccak256("v2-redirect"));
        vault = SponsoredTasksVaultV2(vaultAddress);
        rToken.mint(address(this), 200e6);
        rToken.approve(address(vault), 200e6);
        vault.fund(200e6);
    }

    function _withdrawSig(address to, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(vault.WITHDRAW_AVAILABLE_TYPEHASH(), vault.vaultId(), to, amount, nonce, deadline)
        );
        return _sign(ownerKey, vault.ownerActionDigest(structHash));
    }

    function _exitSig(address to, uint256 nonce, uint256 deadline) internal view returns (bytes memory) {
        bytes32 structHash =
            keccak256(abi.encode(vault.EMERGENCY_EXIT_TYPEHASH(), vault.vaultId(), to, nonce, deadline));
        return _sign(ownerKey, vault.ownerActionDigest(structHash));
    }

    function test_RedirectedClaimClaimToAndClaimFeeRevertAndLeaveTheAwardClaimable() public {
        vm.prank(vaultOwner);
        vault.configureManager(manager, 200e6, true);

        uint256 workerKey = 0xBEEF;
        address worker = vm.addr(workerKey);
        address destination = makeAddr("destination");
        bytes32 allocationId = keccak256("v2-redirect-allocation");
        bytes32 taskId = keccak256("v2-redirect-task");
        uint256 feeTotal = 100e6 * uint256(FEE_BPS) / 10_000;
        uint256 award = 100e6 - feeTotal;
        vm.prank(controller);
        vault.reserveTask(allocationId, taskId, manager, 100e6, 1, FEE_BPS, feeRecipient, TERMS_HASH);
        bytes32 root = vault.claimLeaf(allocationId, taskId, 1, 0, worker, award);
        vm.prank(controller);
        vault.installSettlement(allocationId, taskId, root, 1, award, feeTotal, 100e6);
        bytes32[] memory proof = new bytes32[](0);

        rToken.setRedirect(worker, elsewhere);
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVaultV2.TokenRecipientAmountMismatch.selector, award, 0));
        vault.claim(allocationId, 0, award, proof);

        rToken.setRedirect(destination, elsewhere);
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes memory signature =
            _sign(workerKey, vault.claimDigest(allocationId, 0, worker, destination, award, 0, deadline));
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVaultV2.TokenRecipientAmountMismatch.selector, award, 0));
        vault.claimTo(allocationId, 0, worker, destination, award, 0, deadline, signature, proof);

        vm.prank(feeRecipient);
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTasksVaultV2.TokenRecipientAmountMismatch.selector, feeTotal, 0)
        );
        vault.claimFee(allocationId, destination);

        assertEq(vault.claimNonces(worker), 0);
        assertFalse(vault.isClaimed(allocationId, 0));
        assertEq(rToken.balanceOf(elsewhere), 0);
        assertEq(rToken.balanceOf(address(vault)), 200e6);

        // The worker's claim signature was not used up: it pays once the destination stops redirecting.
        rToken.setRedirect(destination, address(0));
        vm.prank(relayer);
        vault.claimTo(allocationId, 0, worker, destination, award, 0, deadline, signature, proof);
        assertEq(rToken.balanceOf(destination), award);
        assertTrue(vault.isClaimed(allocationId, 0));
    }

    function test_RedirectedWithdrawAvailableBySigRevertsWithoutUsingTheOwnersSignature() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _withdrawSig(recipient, 40e6, 0, deadline);
        rToken.setRedirect(recipient, elsewhere);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVaultV2.TokenRecipientAmountMismatch.selector, 40e6, 0));
        vault.withdrawAvailableBySig(recipient, 40e6, deadline, sig);
        assertEq(vault.ownerNonce(), 0);
        assertEq(vault.available(), 200e6);
        assertEq(rToken.balanceOf(elsewhere), 0);

        rToken.setRedirect(recipient, address(0));
        vm.prank(relayer);
        vault.withdrawAvailableBySig(recipient, 40e6, deadline, sig);
        assertEq(vault.ownerNonce(), 1);
        assertEq(rToken.balanceOf(recipient), 40e6);
    }

    function test_RedirectedEmergencyExitVaultBySigRevertsAndKeepsTheVaultActive() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _exitSig(recipient, 0, deadline);
        rToken.setRedirect(recipient, elsewhere);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVaultV2.TokenRecipientAmountMismatch.selector, 200e6, 0));
        vault.emergencyExitVaultBySig(recipient, deadline, sig);
        assertEq(uint256(vault.status()), uint256(SponsoredTaskTypes.VaultStatus.Active));
        assertEq(vault.ownerNonce(), 0);
        assertEq(rToken.balanceOf(address(vault)), 200e6);

        rToken.setRedirect(recipient, address(0));
        vm.prank(relayer);
        assertEq(vault.emergencyExitVaultBySig(recipient, deadline, sig), 200e6);
        assertEq(uint256(vault.status()), uint256(SponsoredTaskTypes.VaultStatus.Exited));
        assertEq(rToken.balanceOf(recipient), 200e6);
    }
}
