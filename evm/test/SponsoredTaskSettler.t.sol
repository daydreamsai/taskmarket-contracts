// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { SponsoredTaskTypes } from "../src/hooks/sponsored-task/SponsoredTaskTypes.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTaskFactory } from "../src/hooks/sponsored-task/SponsoredTaskFactory.sol";
import { SponsoredTaskFeeConfig } from "./helpers/SponsoredTaskFeeConfig.sol";
import { SponsoredTasksVault } from "../src/hooks/sponsored-task/SponsoredTasksVault.sol";
import { SponsoredTaskSettler } from "../src/hooks/sponsored-task/SponsoredTaskSettler.sol";
import {
    ISponsoredTaskSettlerAuthority
} from "../src/hooks/sponsored-task/interfaces/ISponsoredTaskSettlerAuthority.sol";

contract MockSettlerAuthority is ISponsoredTaskSettlerAuthority {
    mapping(bytes32 digest => bool ok) public approved;

    function approve(bytes32 digest) external {
        approved[digest] = true;
    }

    function isAuthorized(bytes32 digest, bytes[] calldata) external view returns (bool) {
        return approved[digest];
    }
}

contract SponsoredTaskSettlerTest is Test {
    uint256 private constant TASK_CHAIN_ID = 8453;
    uint256 private constant REMOTE_CHAIN_ID = 46_630;
    bytes32 private constant TASK_ID = keccak256("base-task");
    bytes32 private constant TERMS_HASH = keccak256("terms");
    uint64 private constant NONCE = 7;
    uint256 private constant GROSS = 10_000;
    uint16 private constant FEE_BPS = 750;
    address private constant FEE_RECIPIENT = address(0xFEE);
    address private constant MANAGER = address(0xCAFE);
    address private constant WORKER = address(0xB0B);
    address private constant RELAYER = address(0x5E1A);

    uint256 private keyA = 0xA11CE;
    uint256 private keyB = 0xB0B0;
    uint256 private keyC = 0xC0C0;

    address private admin = address(0xAD);
    MockERC20 private token;
    SponsoredTaskFeePolicy private feePolicy;
    SponsoredTaskRegistry private registry;
    SponsoredTaskFactory private factory;
    SponsoredTaskSettler private settler;
    SponsoredTasksVault private vault;
    bytes32 private allocationId;

    function setUp() public {
        vm.chainId(REMOTE_CHAIN_ID);
        token = new MockERC20("Project", "PROJECT", 18, address(this));
        feePolicy = new SponsoredTaskFeePolicy(address(this), FEE_BPS, FEE_RECIPIENT);
        registry = new SponsoredTaskRegistry(address(this));
        settler = new SponsoredTaskSettler(admin, _one(vm.addr(keyA)), 1);
        factory = new SponsoredTaskFactory(
            address(settler), address(feePolicy), registry, SponsoredTaskFeeConfig.none(IERC20(address(token)))
        );
        registry.setFactory(address(factory), true);
        (address v,) = factory.createVault(address(token), address(this), keccak256("remote"));
        vault = SponsoredTasksVault(v);
        vault.configureManager(MANAGER, GROSS * 10, true);
        token.mint(address(this), GROSS * 10);
        token.approve(address(vault), type(uint256).max);
        vault.fund(GROSS * 10);
        allocationId = keccak256(abi.encode(TASK_CHAIN_ID, TASK_ID));
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _one(address a) private pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _sorted(uint256[] memory keys) private pure returns (uint256[] memory) {
        for (uint256 i; i < keys.length; ++i) {
            for (uint256 j = i + 1; j < keys.length; ++j) {
                if (vm.addr(keys[j]) < vm.addr(keys[i])) (keys[i], keys[j]) = (keys[j], keys[i]);
            }
        }
        return keys;
    }

    function _addresses(uint256[] memory keys) private pure returns (address[] memory list) {
        list = new address[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            list[i] = vm.addr(keys[i]);
        }
    }

    function _sign(bytes32 digest, uint256[] memory keys) private pure returns (bytes[] memory sigs) {
        sigs = new bytes[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }

    function _keys1(uint256 k) private pure returns (uint256[] memory keys) {
        keys = new uint256[](1);
        keys[0] = k;
    }

    function _reserveRequest() private view returns (SponsoredTaskSettler.ReserveRequest memory) {
        return SponsoredTaskSettler.ReserveRequest({
            vault: address(vault),
            allocationId: allocationId,
            taskChainId: TASK_CHAIN_ID,
            taskId: TASK_ID,
            commitmentNonce: NONCE,
            manager: MANAGER,
            grossAmount: GROSS,
            epoch: 1,
            feeBps: FEE_BPS,
            feeRecipient: FEE_RECIPIENT,
            termsHash: TERMS_HASH
        });
    }

    function _releaseRequest() private view returns (SponsoredTaskSettler.ReleaseRequest memory) {
        return SponsoredTaskSettler.ReleaseRequest({
            vault: address(vault),
            allocationId: allocationId,
            taskChainId: TASK_CHAIN_ID,
            taskId: TASK_ID,
            commitmentNonce: NONCE
        });
    }

    function _net() private pure returns (uint256) {
        return GROSS - (GROSS * FEE_BPS) / 10_000;
    }

    function _leaf(address worker, uint256 net) private view returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(abi.encode(vault.vaultId(), uint64(1), allocationId, TASK_ID, uint256(0), worker, net))
            )
        );
    }

    function _settleRequest(bytes32 root) private view returns (SponsoredTaskSettler.SettleRequest memory) {
        return SponsoredTaskSettler.SettleRequest({
            vault: address(vault),
            allocationId: allocationId,
            taskChainId: TASK_CHAIN_ID,
            taskId: TASK_ID,
            commitmentNonce: NONCE,
            epoch: 1,
            rewardsRoot: root,
            leafCount: 1,
            sponsoredTaskTotal: _net(),
            feeTotal: GROSS - _net(),
            distributedGross: GROSS
        });
    }

    function _reserve() private {
        SponsoredTaskSettler.ReserveRequest memory r = _reserveRequest();
        bytes[] memory sigs = _sign(settler.reserveDigest(r), _keys1(keyA));
        vm.prank(RELAYER);
        settler.reserve(r, sigs);
    }

    function _settle(SponsoredTaskSettler.SettleRequest memory s, uint256[] memory keys) private {
        bytes[] memory sigs = _sign(settler.settleDigest(s), keys);
        vm.prank(RELAYER);
        settler.settle(s, sigs);
    }

    function _state() private view returns (SponsoredTaskSettler.AllocationState state) {
        (state,,,,,,) = settler.allocationCommitment(address(vault), allocationId);
    }

    function _vaultStatus() private view returns (SponsoredTaskTypes.AllocationStatus status) {
        (,,,,,,, status) = vault.allocationSettlement(allocationId);
    }

    // ---------------------------------------------------------------------------------------------
    // Constructor and configuration
    // ---------------------------------------------------------------------------------------------

    function testConstructorDefaults() public view {
        assertEq(settler.owner(), admin);
        assertEq(settler.threshold(), 1);
        assertEq(settler.settlers().length, 1);
        assertTrue(settler.isSettler(vm.addr(keyA)));
        assertEq(settler.claimDelaySeconds(), 3600);
        assertEq(address(settler.authority()), address(0));
        assertEq(vault.controller(), address(settler));
    }

    function testDomainBindsRemoteChainAndSettler() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Taskmarket Sponsored Settler"),
                keccak256("1"),
                REMOTE_CHAIN_ID,
                address(settler)
            )
        );
        assertEq(settler.domainSeparator(), expected);
        assertEq(settler.allocationIdFor(TASK_CHAIN_ID, TASK_ID), allocationId);
    }

    function testConstructorRejectsBadSettlerSets() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(SponsoredTaskSettler.InvalidSettlers.selector);
        new SponsoredTaskSettler(admin, empty, 1);

        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskSettler.InvalidThreshold.selector, uint8(0), uint256(1)));
        new SponsoredTaskSettler(admin, _one(address(1)), 0);

        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskSettler.InvalidThreshold.selector, uint8(2), uint256(1)));
        new SponsoredTaskSettler(admin, _one(address(1)), 2);

        vm.expectRevert(SponsoredTaskSettler.InvalidSettlers.selector);
        new SponsoredTaskSettler(admin, _one(address(0)), 1);

        address[] memory dup = new address[](2);
        dup[0] = address(1);
        dup[1] = address(1);
        vm.expectRevert(SponsoredTaskSettler.InvalidSettlers.selector);
        new SponsoredTaskSettler(admin, dup, 1);

        address[] memory tooMany = new address[](17);
        for (uint256 i; i < 17; ++i) {
            tooMany[i] = address(uint160(i + 1));
        }
        vm.expectRevert(SponsoredTaskSettler.InvalidSettlers.selector);
        new SponsoredTaskSettler(admin, tooMany, 1);
    }

    function testRenounceOwnershipDisabled() public {
        vm.prank(admin);
        vm.expectRevert(SponsoredTaskSettler.OwnershipRenunciationDisabled.selector);
        settler.renounceOwnership();
    }

    // ---------------------------------------------------------------------------------------------
    // Reserve
    // ---------------------------------------------------------------------------------------------

    function testReserveRecordsCommitmentAndReservesInVault() public {
        _reserve();
        (
            SponsoredTaskSettler.AllocationState state,
            uint256 taskChainId,
            bytes32 taskId,
            uint64 nonce,
            uint64 epoch,
            uint16 feeBps,
            uint256 gross
        ) = settler.allocationCommitment(address(vault), allocationId);
        assertEq(uint8(state), uint8(SponsoredTaskSettler.AllocationState.Reserved));
        assertEq(taskChainId, TASK_CHAIN_ID);
        assertEq(taskId, TASK_ID);
        assertEq(nonce, NONCE);
        assertEq(epoch, 1);
        assertEq(feeBps, FEE_BPS);
        assertEq(gross, GROSS);
        assertEq(uint8(_vaultStatus()), uint8(SponsoredTaskTypes.AllocationStatus.Reserved));
        assertEq(vault.totalReserved(), GROSS);
        (bytes32 vaultTaskId,,,,,,,) = vault.allocationTerms(allocationId);
        assertEq(vaultTaskId, TASK_ID);
    }

    function testReserveReplayOnSameChainFails() public {
        SponsoredTaskSettler.ReserveRequest memory r = _reserveRequest();
        bytes[] memory sigs = _sign(settler.reserveDigest(r), _keys1(keyA));
        settler.reserve(r, sigs);
        vm.expectRevert(
            abi.encodeWithSelector(
                SponsoredTaskSettler.AllocationWrongState.selector,
                address(vault),
                allocationId,
                SponsoredTaskSettler.AllocationState.Reserved
            )
        );
        settler.reserve(r, sigs);
    }

    function testReserveSignatureFromAnotherChainFails() public {
        SponsoredTaskSettler.ReserveRequest memory r = _reserveRequest();
        // Signed while this settler's domain names another chain id.
        vm.chainId(REMOTE_CHAIN_ID + 1);
        bytes[] memory sigs = _sign(settler.reserveDigest(r), _keys1(keyA));
        vm.chainId(REMOTE_CHAIN_ID);
        bytes32 actual = settler.reserveDigest(r);
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(keyA, actual);
        assertTrue(keccak256(sigs[0]) != keccak256(abi.encodePacked(rr, ss, v)));
        vm.expectPartialRevert(SponsoredTaskSettler.NotSettler.selector);
        settler.reserve(r, sigs);
    }

    function testReserveSignatureForAnotherSettlerFails() public {
        SponsoredTaskSettler other = new SponsoredTaskSettler(admin, _one(vm.addr(keyA)), 1);
        SponsoredTaskSettler.ReserveRequest memory r = _reserveRequest();
        bytes[] memory sigs = _sign(other.reserveDigest(r), _keys1(keyA));
        vm.expectPartialRevert(SponsoredTaskSettler.NotSettler.selector);
        settler.reserve(r, sigs);
    }

    function testReserveRejectsTamperedField() public {
        SponsoredTaskSettler.ReserveRequest memory r = _reserveRequest();
        bytes[] memory sigs = _sign(settler.reserveDigest(r), _keys1(keyA));
        r.grossAmount = GROSS * 2;
        vm.expectPartialRevert(SponsoredTaskSettler.NotSettler.selector);
        settler.reserve(r, sigs);
    }

    function testReserveRejectsMalformedSignature() public {
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = hex"1234";
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskSettler.InvalidSignature.selector, uint256(0)));
        settler.reserve(_reserveRequest(), sigs);
    }

    function testReserveRejectsNoSignatures() public {
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskSettler.SettlerThresholdNotMet.selector, uint256(0), uint8(1))
        );
        settler.reserve(_reserveRequest(), new bytes[](0));
    }

    function testReserveRejectsWrongAllocationId() public {
        SponsoredTaskSettler.ReserveRequest memory r = _reserveRequest();
        r.allocationId = TASK_ID;
        bytes[] memory sigs = _sign(settler.reserveDigest(r), _keys1(keyA));
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskSettler.InvalidAllocationId.selector, allocationId, TASK_ID)
        );
        settler.reserve(r, sigs);
    }

    function testReserveRejectsMissingTask() public {
        SponsoredTaskSettler.ReserveRequest memory r = _reserveRequest();
        r.taskId = bytes32(0);
        bytes[] memory sigs = _sign(settler.reserveDigest(r), _keys1(keyA));
        vm.expectRevert(SponsoredTaskSettler.InvalidTask.selector);
        settler.reserve(r, sigs);

        r.taskId = TASK_ID;
        r.taskChainId = 0;
        sigs = _sign(settler.reserveDigest(r), _keys1(keyA));
        vm.expectRevert(SponsoredTaskSettler.InvalidTask.selector);
        settler.reserve(r, sigs);
    }

    function testReserveRejectsVaultNotControlled() public {
        SponsoredTaskFactory otherFactory = new SponsoredTaskFactory(
            address(this), address(feePolicy), registry, SponsoredTaskFeeConfig.none(IERC20(address(token)))
        );
        registry.setFactory(address(otherFactory), true);
        (address otherVault,) = otherFactory.createVault(address(token), address(this), keccak256("other"));
        SponsoredTaskSettler.ReserveRequest memory r = _reserveRequest();
        r.vault = otherVault;
        bytes[] memory sigs = _sign(settler.reserveDigest(r), _keys1(keyA));
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskSettler.VaultNotControlled.selector, otherVault));
        settler.reserve(r, sigs);

        r.vault = address(0x1234);
        sigs = _sign(settler.reserveDigest(r), _keys1(keyA));
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskSettler.InvalidContract.selector, address(0x1234)));
        settler.reserve(r, sigs);
    }

    function testReserveBubblesVaultManagerCap() public {
        SponsoredTaskSettler.ReserveRequest memory r = _reserveRequest();
        r.grossAmount = GROSS * 11;
        bytes[] memory sigs = _sign(settler.reserveDigest(r), _keys1(keyA));
        vm.expectRevert(
            abi.encodeWithSelector(
                SponsoredTasksVault.ManagerAllowanceExceeded.selector, MANAGER, GROSS * 11, GROSS * 10
            )
        );
        settler.reserve(r, sigs);
    }

    function testReserveBlockedWhilePaused() public {
        vm.prank(admin);
        settler.pause();
        SponsoredTaskSettler.ReserveRequest memory r = _reserveRequest();
        bytes[] memory sigs = _sign(settler.reserveDigest(r), _keys1(keyA));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        settler.reserve(r, sigs);
    }

    // ---------------------------------------------------------------------------------------------
    // Release
    // ---------------------------------------------------------------------------------------------

    function testReleaseReturnsReservationAndIsIdempotent() public {
        _reserve();
        SponsoredTaskSettler.ReleaseRequest memory r = _releaseRequest();
        bytes[] memory sigs = _sign(settler.releaseDigest(r), _keys1(keyA));
        settler.release(r, sigs);
        assertEq(uint8(_state()), uint8(SponsoredTaskSettler.AllocationState.Released));
        assertEq(uint8(_vaultStatus()), uint8(SponsoredTaskTypes.AllocationStatus.Released));
        assertEq(vault.totalReserved(), 0);
        // Replaying the same release is a no-op.
        settler.release(r, sigs);
        assertEq(vault.totalReserved(), 0);
    }

    function testReleaseOpenWhilePaused() public {
        _reserve();
        vm.prank(admin);
        settler.pause();
        SponsoredTaskSettler.ReleaseRequest memory r = _releaseRequest();
        settler.release(r, _sign(settler.releaseDigest(r), _keys1(keyA)));
        assertEq(uint8(_state()), uint8(SponsoredTaskSettler.AllocationState.Released));
    }

    function testReleaseRejectsUnknownAllocation() public {
        SponsoredTaskSettler.ReleaseRequest memory r = _releaseRequest();
        bytes[] memory sigs = _sign(settler.releaseDigest(r), _keys1(keyA));
        vm.expectRevert(
            abi.encodeWithSelector(
                SponsoredTaskSettler.AllocationWrongState.selector,
                address(vault),
                allocationId,
                SponsoredTaskSettler.AllocationState.None
            )
        );
        settler.release(r, sigs);
    }

    function testReleaseRejectsWrongCommitment() public {
        _reserve();
        SponsoredTaskSettler.ReleaseRequest memory r = _releaseRequest();
        r.commitmentNonce = NONCE + 1;
        bytes[] memory sigs = _sign(settler.releaseDigest(r), _keys1(keyA));
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskSettler.CommitmentMismatch.selector, address(vault), allocationId)
        );
        settler.release(r, sigs);

        r = _releaseRequest();
        r.taskChainId = TASK_CHAIN_ID + 1;
        sigs = _sign(settler.releaseDigest(r), _keys1(keyA));
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskSettler.CommitmentMismatch.selector, address(vault), allocationId)
        );
        settler.release(r, sigs);
    }

    function testReleaseRejectedWhileSettlementPending() public {
        _reserve();
        _settle(_settleRequest(_leaf(WORKER, _net())), _keys1(keyA));
        SponsoredTaskSettler.ReleaseRequest memory r = _releaseRequest();
        bytes[] memory sigs = _sign(settler.releaseDigest(r), _keys1(keyA));
        vm.expectRevert(
            abi.encodeWithSelector(
                SponsoredTaskSettler.AllocationWrongState.selector,
                address(vault),
                allocationId,
                SponsoredTaskSettler.AllocationState.Pending
            )
        );
        settler.release(r, sigs);
    }

    // ---------------------------------------------------------------------------------------------
    // Settle, finalize and the claim delay
    // ---------------------------------------------------------------------------------------------

    function testSettleIsPendingThenFinalizeAfterDelayOpensClaims() public {
        _reserve();
        bytes32 root = _leaf(WORKER, _net());
        _settle(_settleRequest(root), _keys1(keyA));

        assertEq(uint8(_state()), uint8(SponsoredTaskSettler.AllocationState.Pending));
        // The vault is untouched during the delay.
        assertEq(uint8(_vaultStatus()), uint8(SponsoredTaskTypes.AllocationStatus.Reserved));
        (bytes32 pendingRoot,,,,, uint64 settledAt, uint256 claimableAt) =
            settler.allocationSettlement(address(vault), allocationId);
        assertEq(pendingRoot, root);
        assertEq(claimableAt, uint256(settledAt) + 3600);

        vm.warp(block.timestamp + 3599);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskSettler.ClaimDelayNotElapsed.selector, claimableAt));
        settler.finalize(address(vault), allocationId);

        vm.warp(claimableAt);
        vm.prank(RELAYER);
        settler.finalize(address(vault), allocationId);
        assertEq(uint8(_state()), uint8(SponsoredTaskSettler.AllocationState.Settled));
        assertEq(uint8(_vaultStatus()), uint8(SponsoredTaskTypes.AllocationStatus.Claimable));

        vm.prank(WORKER);
        vault.claim(allocationId, 0, _net(), new bytes32[](0));
        assertEq(token.balanceOf(WORKER), _net());

        vm.expectRevert(
            abi.encodeWithSelector(
                SponsoredTaskSettler.AllocationWrongState.selector,
                address(vault),
                allocationId,
                SponsoredTaskSettler.AllocationState.Settled
            )
        );
        settler.finalize(address(vault), allocationId);
    }

    function testSettleWithNoAwardsReleasesRemainderOnFinalize() public {
        _reserve();
        SponsoredTaskSettler.SettleRequest memory s = _settleRequest(bytes32(0));
        s.leafCount = 0;
        s.sponsoredTaskTotal = 0;
        s.feeTotal = 0;
        s.distributedGross = 0;
        _settle(s, _keys1(keyA));
        vm.warp(block.timestamp + 3600);
        settler.finalize(address(vault), allocationId);
        assertEq(uint8(_vaultStatus()), uint8(SponsoredTaskTypes.AllocationStatus.Settled));
        assertEq(vault.totalReserved(), 0);
    }

    function testSettleReplayOnSameAllocationFails() public {
        _reserve();
        SponsoredTaskSettler.SettleRequest memory s = _settleRequest(_leaf(WORKER, _net()));
        bytes[] memory sigs = _sign(settler.settleDigest(s), _keys1(keyA));
        settler.settle(s, sigs);
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskSettler.SettlementAlreadyUsed.selector, settler.settleDigest(s))
        );
        settler.settle(s, sigs);
    }

    function testSettleSignatureFromAnotherChainFails() public {
        _reserve();
        SponsoredTaskSettler.SettleRequest memory s = _settleRequest(_leaf(WORKER, _net()));
        vm.chainId(TASK_CHAIN_ID);
        bytes[] memory sigs = _sign(settler.settleDigest(s), _keys1(keyA));
        vm.chainId(REMOTE_CHAIN_ID);
        vm.expectPartialRevert(SponsoredTaskSettler.NotSettler.selector);
        settler.settle(s, sigs);
    }

    function testSettleRejectsWrongState() public {
        SponsoredTaskSettler.SettleRequest memory s = _settleRequest(_leaf(WORKER, _net()));
        bytes[] memory sigs = _sign(settler.settleDigest(s), _keys1(keyA));
        vm.expectRevert(
            abi.encodeWithSelector(
                SponsoredTaskSettler.AllocationWrongState.selector,
                address(vault),
                allocationId,
                SponsoredTaskSettler.AllocationState.None
            )
        );
        settler.settle(s, sigs);

        _reserve();
        SponsoredTaskSettler.ReleaseRequest memory r = _releaseRequest();
        settler.release(r, _sign(settler.releaseDigest(r), _keys1(keyA)));
        vm.expectRevert(
            abi.encodeWithSelector(
                SponsoredTaskSettler.AllocationWrongState.selector,
                address(vault),
                allocationId,
                SponsoredTaskSettler.AllocationState.Released
            )
        );
        settler.settle(s, sigs);
    }

    function testSettleRejectsCommitmentAndEpochMismatch() public {
        bytes[] memory sigsX;
        _reserve();
        SponsoredTaskSettler.SettleRequest memory s = _settleRequest(_leaf(WORKER, _net()));
        s.commitmentNonce = NONCE + 1;
        sigsX = _sign(settler.settleDigest(s), _keys1(keyA));
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskSettler.CommitmentMismatch.selector, address(vault), allocationId)
        );
        settler.settle(s, sigsX);

        s = _settleRequest(_leaf(WORKER, _net()));
        s.taskId = keccak256("other");
        sigsX = _sign(settler.settleDigest(s), _keys1(keyA));
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskSettler.CommitmentMismatch.selector, address(vault), allocationId)
        );
        settler.settle(s, sigsX);

        s = _settleRequest(_leaf(WORKER, _net()));
        s.epoch = 2;
        sigsX = _sign(settler.settleDigest(s), _keys1(keyA));
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskSettler.EpochMismatch.selector, uint64(1), uint64(2)));
        settler.settle(s, sigsX);
    }

    function testSettleRejectsBadTotals() public {
        bytes[] memory sigsX;
        _reserve();
        SponsoredTaskSettler.SettleRequest memory s = _settleRequest(_leaf(WORKER, _net()));
        s.distributedGross = GROSS + 1;
        sigsX = _sign(settler.settleDigest(s), _keys1(keyA));
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskSettler.SettlementExceedsAllocation.selector, GROSS + 1, GROSS)
        );
        settler.settle(s, sigsX);

        s = _settleRequest(_leaf(WORKER, _net()));
        s.feeTotal += 1;
        sigsX = _sign(settler.settleDigest(s), _keys1(keyA));
        vm.expectRevert(SponsoredTaskSettler.InvalidSettlementTotals.selector);
        settler.settle(s, sigsX);

        s = _settleRequest(_leaf(WORKER, _net()));
        s.feeTotal += 1;
        s.sponsoredTaskTotal -= 1;
        sigsX = _sign(settler.settleDigest(s), _keys1(keyA));
        vm.expectRevert(
            abi.encodeWithSelector(
                SponsoredTaskSettler.SettlementFeeTooHigh.selector, GROSS - _net() + 1, GROSS - _net()
            )
        );
        settler.settle(s, sigsX);

        s = _settleRequest(bytes32(0));
        sigsX = _sign(settler.settleDigest(s), _keys1(keyA));
        vm.expectRevert(SponsoredTaskSettler.InvalidSettlementTotals.selector);
        settler.settle(s, sigsX);

        s = _settleRequest(_leaf(WORKER, _net()));
        s.leafCount = 0;
        sigsX = _sign(settler.settleDigest(s), _keys1(keyA));
        vm.expectRevert(SponsoredTaskSettler.InvalidSettlementTotals.selector);
        settler.settle(s, sigsX);
    }

    function testSettleAndFinalizeBlockedWhilePaused() public {
        _reserve();
        SponsoredTaskSettler.SettleRequest memory s = _settleRequest(_leaf(WORKER, _net()));
        bytes[] memory sigs = _sign(settler.settleDigest(s), _keys1(keyA));
        vm.prank(admin);
        settler.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        settler.settle(s, sigs);

        vm.prank(admin);
        settler.unpause();
        settler.settle(s, sigs);
        vm.warp(block.timestamp + 3600);
        vm.prank(admin);
        settler.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        settler.finalize(address(vault), allocationId);
        vm.prank(admin);
        settler.unpause();
        settler.finalize(address(vault), allocationId);
    }

    function testFinalizeRejectsWithoutPendingRoot() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                SponsoredTaskSettler.AllocationWrongState.selector,
                address(vault),
                allocationId,
                SponsoredTaskSettler.AllocationState.None
            )
        );
        settler.finalize(address(vault), allocationId);
    }

    // ---------------------------------------------------------------------------------------------
    // Revoke
    // ---------------------------------------------------------------------------------------------

    function testRevokeWithoutPauseThenCorrectedRootSettles() public {
        _reserve();
        SponsoredTaskSettler.SettleRequest memory bad = _settleRequest(_leaf(address(0xBAD), _net()));
        bytes[] memory badSigs = _sign(settler.settleDigest(bad), _keys1(keyA));
        settler.settle(bad, badSigs);

        vm.prank(admin);
        settler.revokeSettlement(address(vault), allocationId);
        assertEq(uint8(_state()), uint8(SponsoredTaskSettler.AllocationState.Reserved));
        (bytes32 root,,,,, uint64 settledAt, uint256 claimableAt) =
            settler.allocationSettlement(address(vault), allocationId);
        assertEq(root, bytes32(0));
        assertEq(settledAt, 0);
        assertEq(claimableAt, 0);

        // The revoked root's signatures cannot be replayed.
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskSettler.SettlementAlreadyUsed.selector, settler.settleDigest(bad))
        );
        settler.settle(bad, badSigs);

        _settle(_settleRequest(_leaf(WORKER, _net())), _keys1(keyA));
        vm.warp(block.timestamp + 3600);
        settler.finalize(address(vault), allocationId);
        vm.prank(WORKER);
        vault.claim(allocationId, 0, _net(), new bytes32[](0));
        assertEq(token.balanceOf(WORKER), _net());
    }

    function testRevokeWorksWhilePausedAndAfterDelay() public {
        _reserve();
        _settle(_settleRequest(_leaf(WORKER, _net())), _keys1(keyA));
        vm.warp(block.timestamp + 7200);
        vm.startPrank(admin);
        settler.pause();
        settler.revokeSettlement(address(vault), allocationId);
        vm.stopPrank();
        assertEq(uint8(_state()), uint8(SponsoredTaskSettler.AllocationState.Reserved));
    }

    function testRevokeOnlyOwnerAndOnlyPending() public {
        _reserve();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        settler.revokeSettlement(address(vault), allocationId);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                SponsoredTaskSettler.AllocationWrongState.selector,
                address(vault),
                allocationId,
                SponsoredTaskSettler.AllocationState.Reserved
            )
        );
        settler.revokeSettlement(address(vault), allocationId);

        _settle(_settleRequest(_leaf(WORKER, _net())), _keys1(keyA));
        vm.warp(block.timestamp + 3600);
        settler.finalize(address(vault), allocationId);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                SponsoredTaskSettler.AllocationWrongState.selector,
                address(vault),
                allocationId,
                SponsoredTaskSettler.AllocationState.Settled
            )
        );
        settler.revokeSettlement(address(vault), allocationId);
    }

    function testPauseOnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        settler.pause();
        vm.prank(admin);
        settler.pause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        settler.unpause();
    }

    // ---------------------------------------------------------------------------------------------
    // Thresholds and settler-set rotation
    // ---------------------------------------------------------------------------------------------

    function _rotateTo(uint256[] memory keys, uint8 newThreshold) private {
        address[] memory list = _addresses(keys);
        vm.prank(admin);
        settler.setSettlers(list, newThreshold);
        vm.warp(block.timestamp + 48 hours);
        settler.applySettlers(list, newThreshold);
    }

    function _threeKeys() private view returns (uint256[] memory keys) {
        keys = new uint256[](3);
        keys[0] = keyA;
        keys[1] = keyB;
        keys[2] = keyC;
        keys = _sorted(keys);
    }

    function testTwoOfThreeThreshold() public {
        uint256[] memory keys = _threeKeys();
        _rotateTo(keys, 2);
        assertEq(settler.threshold(), 2);

        SponsoredTaskSettler.ReserveRequest memory r = _reserveRequest();
        bytes32 digest = settler.reserveDigest(r);

        // One signature is below the threshold.
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskSettler.SettlerThresholdNotMet.selector, uint256(1), uint8(2))
        );
        settler.reserve(r, _sign(digest, _keys1(keys[0])));

        // The same signer twice is rejected as unsorted.
        uint256[] memory dup = new uint256[](2);
        dup[0] = keys[0];
        dup[1] = keys[0];
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskSettler.SignersNotSorted.selector, uint256(1)));
        settler.reserve(r, _sign(digest, dup));

        // Descending order is rejected.
        uint256[] memory desc = new uint256[](2);
        desc[0] = keys[2];
        desc[1] = keys[0];
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskSettler.SignersNotSorted.selector, uint256(1)));
        settler.reserve(r, _sign(digest, desc));

        // An outsider among the signers is rejected.
        uint256[] memory outsider = new uint256[](2);
        outsider[0] = keys[0];
        outsider[1] = 0xD0D0;
        outsider = _sorted(outsider);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskSettler.NotSettler.selector, vm.addr(0xD0D0)));
        settler.reserve(r, _sign(digest, outsider));

        uint256[] memory two = new uint256[](2);
        two[0] = keys[0];
        two[1] = keys[2];
        settler.reserve(r, _sign(digest, two));
        assertEq(uint8(_state()), uint8(SponsoredTaskSettler.AllocationState.Reserved));

        // All three also pass.
        SponsoredTaskSettler.SettleRequest memory s = _settleRequest(_leaf(WORKER, _net()));
        settler.settle(s, _sign(settler.settleDigest(s), keys));
        assertEq(uint8(_state()), uint8(SponsoredTaskSettler.AllocationState.Pending));
    }

    function testRotationTimelockAndOldKeyRejected() public {
        uint256[] memory newKeys = _keys1(keyB);
        address[] memory list = _addresses(newKeys);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        settler.setSettlers(list, 1);

        vm.expectRevert(SponsoredTaskSettler.NothingScheduled.selector);
        settler.applySettlers(list, 1);

        vm.prank(admin);
        settler.setSettlers(list, 1);
        uint64 eta = settler.pendingSettlersEta();
        assertEq(eta, block.timestamp + 48 hours);

        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskSettler.TimelockNotElapsed.selector, uint256(eta)));
        settler.applySettlers(list, 1);

        vm.warp(eta);
        vm.expectRevert(SponsoredTaskSettler.ScheduledChangeMismatch.selector);
        settler.applySettlers(_one(vm.addr(keyC)), 1);

        // The old set still authorizes until the change applies.
        _reserve();
        settler.applySettlers(list, 1);
        assertFalse(settler.isSettler(vm.addr(keyA)));
        assertTrue(settler.isSettler(vm.addr(keyB)));

        SponsoredTaskSettler.SettleRequest memory s = _settleRequest(_leaf(WORKER, _net()));
        bytes[] memory oldSigs = _sign(settler.settleDigest(s), _keys1(keyA));
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskSettler.NotSettler.selector, vm.addr(keyA)));
        settler.settle(s, oldSigs);
        settler.settle(s, _sign(settler.settleDigest(s), _keys1(keyB)));
    }

    function testRotationDoesNotCancelPendingRoot() public {
        _reserve();
        _settle(_settleRequest(_leaf(WORKER, _net())), _keys1(keyA));
        _rotateTo(_keys1(keyB), 1);
        assertEq(uint8(_state()), uint8(SponsoredTaskSettler.AllocationState.Pending));
        settler.finalize(address(vault), allocationId);
        assertEq(uint8(_vaultStatus()), uint8(SponsoredTaskTypes.AllocationStatus.Claimable));
    }

    function testCancelSettlers() public {
        vm.prank(admin);
        vm.expectRevert(SponsoredTaskSettler.NothingScheduled.selector);
        settler.cancelSettlers();

        address[] memory list = _one(vm.addr(keyB));
        vm.prank(admin);
        settler.setSettlers(list, 1);
        vm.prank(admin);
        settler.cancelSettlers();
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(SponsoredTaskSettler.NothingScheduled.selector);
        settler.applySettlers(list, 1);
    }

    function testSetSettlersValidates() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskSettler.InvalidThreshold.selector, uint8(2), uint256(1)));
        settler.setSettlers(_one(vm.addr(keyB)), 2);
    }

    // ---------------------------------------------------------------------------------------------
    // Claim delay
    // ---------------------------------------------------------------------------------------------

    function testRaisingClaimDelayIsImmediate() public {
        vm.prank(admin);
        settler.setClaimDelay(7200);
        assertEq(settler.claimDelaySeconds(), 7200);

        _reserve();
        uint256 start = block.timestamp;
        _settle(_settleRequest(_leaf(WORKER, _net())), _keys1(keyA));
        vm.warp(start + 3600);
        vm.expectPartialRevert(SponsoredTaskSettler.ClaimDelayNotElapsed.selector);
        settler.finalize(address(vault), allocationId);
        vm.warp(start + 7200);
        settler.finalize(address(vault), allocationId);
    }

    function testLoweringClaimDelayIsTimelocked() public {
        vm.prank(admin);
        settler.setClaimDelay(60);
        assertEq(settler.claimDelaySeconds(), 3600);
        assertEq(settler.pendingClaimDelay(), 60);

        uint64 eta = settler.pendingClaimDelayEta();
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskSettler.TimelockNotElapsed.selector, uint256(eta)));
        settler.applyClaimDelay();
        vm.warp(eta);
        settler.applyClaimDelay();
        assertEq(settler.claimDelaySeconds(), 60);

        vm.expectRevert(SponsoredTaskSettler.NothingScheduled.selector);
        settler.applyClaimDelay();
    }

    function testClaimDelayValidationAndCancel() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskSettler.InvalidClaimDelay.selector, uint64(0)));
        settler.setClaimDelay(0);
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskSettler.InvalidClaimDelay.selector, uint64(type(uint32).max) + 1)
        );
        settler.setClaimDelay(uint64(type(uint32).max) + 1);
        vm.expectRevert(SponsoredTaskSettler.NothingScheduled.selector);
        settler.cancelClaimDelay();
        settler.setClaimDelay(60);
        settler.cancelClaimDelay();
        vm.stopPrank();
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(SponsoredTaskSettler.NothingScheduled.selector);
        settler.applyClaimDelay();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        settler.setClaimDelay(7200);
    }

    // ---------------------------------------------------------------------------------------------
    // Authority swap
    // ---------------------------------------------------------------------------------------------

    function testAuthoritySwapIsTimelockedAndDecides() public {
        MockSettlerAuthority auth = new MockSettlerAuthority();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        settler.setAuthority(address(auth));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskSettler.InvalidContract.selector, address(0x1234)));
        settler.setAuthority(address(0x1234));

        vm.prank(admin);
        settler.setAuthority(address(auth));
        uint64 eta = settler.pendingAuthorityEta();
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskSettler.TimelockNotElapsed.selector, uint256(eta)));
        settler.applyAuthority();
        vm.warp(eta);
        settler.applyAuthority();
        assertEq(address(settler.authority()), address(auth));

        SponsoredTaskSettler.ReserveRequest memory r = _reserveRequest();
        bytes32 digest = settler.reserveDigest(r);
        // Settler signatures no longer authorize on their own.
        bytes[] memory sigs = _sign(digest, _keys1(keyA));
        vm.expectRevert(SponsoredTaskSettler.NotAuthorized.selector);
        settler.reserve(r, sigs);

        auth.approve(digest);
        settler.reserve(r, new bytes[](0));
        assertEq(uint8(_state()), uint8(SponsoredTaskSettler.AllocationState.Reserved));

        // Swapping back to the built-in settler set.
        vm.prank(admin);
        settler.setAuthority(address(0));
        vm.warp(block.timestamp + 48 hours);
        settler.applyAuthority();
        assertEq(address(settler.authority()), address(0));
    }

    function testCancelAuthority() public {
        vm.prank(admin);
        vm.expectRevert(SponsoredTaskSettler.NothingScheduled.selector);
        settler.cancelAuthority();
        MockSettlerAuthority auth = new MockSettlerAuthority();
        vm.prank(admin);
        settler.setAuthority(address(auth));
        vm.prank(admin);
        settler.cancelAuthority();
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(SponsoredTaskSettler.NothingScheduled.selector);
        settler.applyAuthority();
    }
}
