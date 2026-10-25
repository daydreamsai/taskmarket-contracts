// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ERC1271WalletMock } from "@openzeppelin/contracts/mocks/ERC1271WalletMock.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { SponsoredTaskTypes } from "../src/hooks/sponsored-task/SponsoredTaskTypes.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTasksVault } from "../src/hooks/sponsored-task/SponsoredTasksVault.sol";

contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee token", "FEE") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value != 0) {
            uint256 fee = value / 100;
            if (fee == 0) fee = 1;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

contract SenderTaxToken is ERC20 {
    constructor() ERC20("Sender tax token", "STAX") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != address(0) && value != 0) {
            uint256 extra = value / 100;
            if (extra == 0) extra = 1;
            super._update(from, address(0), extra);
        }
    }
}

contract RedirectingReceiveToken is ERC20 {
    mapping(address => address) public redirectOf;

    constructor() ERC20("Redirecting token", "RDR") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRedirect(address recipient, address target) external {
        redirectOf[recipient] = target;
    }

    function _update(address from, address to, uint256 value) internal override {
        address target = redirectOf[to];
        super._update(from, target == address(0) ? to : target, value);
    }
}

// allocationSettlement/allocationTerms return tuples, not the Allocation struct -- the
// whole-struct external getter tripped forge coverage --ir-minimum's stack-too-deep limit on its
// own ABI encoding (see SponsoredTasksVault.allocationSettlement's own doc comment). Reconstructs
// the full struct so every existing field-access call site stays unchanged. A free function, not
// a contract member, since every contract in this file (the test, the invariant handler, and the
// invariant test itself) needs it and none of them inherit from one another.
function _vaultAllocation(SponsoredTasksVault v, bytes32 allocationId)
    view
    returns (SponsoredTaskTypes.Allocation memory a)
{
    (a.taskId, a.termsHash, a.manager, a.epoch, a.feeBps, a.feeRecipient, a.grossAmount, a.distributedGross) =
        v.allocationTerms(allocationId);
    (
        a.sponsoredTaskOutstanding,
        a.sponsoredTaskPaid,
        a.feeOutstanding,
        a.feePaid,
        a.releasedAmount,
        a.rewardsRoot,
        a.leafCount,
        a.status
    ) = v.allocationSettlement(allocationId);
}

contract SponsoredTasksVaultTest is Test {
    uint16 internal constant FEE_BPS = 50;
    uint256 internal constant FUNDED = 1_000 ether;
    uint256 internal constant MANAGER_CAP = 800 ether;
    bytes32 internal constant VAULT_ID = keccak256("vault-one");
    bytes32 internal constant TERMS_HASH = keccak256("terms-one");
    bytes32 internal constant ALLOCATION_ID = keccak256("allocation-one");
    bytes32 internal constant TASK_ID = keccak256("task-one");

    address internal owner = makeAddr("vaultOwner");
    address internal controller = makeAddr("controller");
    address internal manager = makeAddr("manager");
    address internal policyOwner = makeAddr("policyOwner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal treasury = makeAddr("treasury");

    MockERC20 internal token;
    SponsoredTaskFeePolicy internal policy;
    SponsoredTasksVault internal implementation;
    SponsoredTasksVault internal vault;

    function setUp() public {
        token = new MockERC20("Project", "PROJECT", 18, address(this));
        policy = new SponsoredTaskFeePolicy(policyOwner, FEE_BPS, feeRecipient);
        implementation = new SponsoredTasksVault();
        vault = SponsoredTasksVault(Clones.clone(address(implementation)));
        vault.initialize(VAULT_ID, address(token), owner, controller, address(policy));

        token.mint(owner, FUNDED);
        vm.startPrank(owner);
        token.approve(address(vault), type(uint256).max);
        vault.fund(FUNDED);
        vault.configureManager(manager, MANAGER_CAP, true);
        vm.stopPrank();
    }

    function test_InitializationAndIntegrationViews() public view {
        assertEq(vault.vaultId(), VAULT_ID);
        assertEq(vault.token(), address(token));
        assertEq(address(vault.projectToken()), address(token));
        assertEq(vault.settlementChain(), block.chainid);
        assertEq(vault.owner(), owner);
        assertEq(vault.controller(), controller);
        assertEq(address(vault.feePolicy()), address(policy));
        assertEq(vault.epoch(), 1);
        assertEq(uint256(vault.status()), uint256(SponsoredTaskTypes.VaultStatus.Active));
        assertEq(vault.totalFunded(), FUNDED);
        assertEq(vault.available(), FUNDED);
    }

    function test_ImplementationAndCloneCannotBeInitializedAgain() public {
        vm.expectRevert();
        implementation.initialize(VAULT_ID, address(token), owner, controller, address(policy));

        vm.expectRevert();
        vault.initialize(VAULT_ID, address(token), owner, controller, address(policy));
    }

    function test_FundingRejectsFeeOnTransferTokenAtomically() public {
        FeeOnTransferToken taxedToken = new FeeOnTransferToken();
        SponsoredTasksVault taxedVault = SponsoredTasksVault(Clones.clone(address(implementation)));
        taxedVault.initialize(keccak256("taxed"), address(taxedToken), owner, controller, address(policy));
        taxedToken.mint(owner, 100 ether);

        vm.startPrank(owner);
        taxedToken.approve(address(taxedVault), 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTasksVault.TokenTransferAmountMismatch.selector, 100 ether, 99 ether)
        );
        taxedVault.fund(100 ether);
        vm.stopPrank();

        assertEq(taxedVault.totalFunded(), 0);
        assertEq(taxedToken.balanceOf(address(taxedVault)), 0);
        assertEq(taxedToken.balanceOf(owner), 100 ether);
    }

    function test_FundingRejectsExtraSenderDebitAtomically() public {
        SenderTaxToken taxedToken = new SenderTaxToken();
        SponsoredTasksVault taxedVault = SponsoredTasksVault(Clones.clone(address(implementation)));
        taxedVault.initialize(keccak256("sender-taxed"), address(taxedToken), owner, controller, address(policy));
        taxedToken.mint(owner, 101 ether);

        vm.startPrank(owner);
        taxedToken.approve(address(taxedVault), 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTasksVault.TokenSenderAmountMismatch.selector, 100 ether, 101 ether)
        );
        taxedVault.fund(100 ether);
        vm.stopPrank();

        assertEq(taxedVault.totalFunded(), 0);
        assertEq(taxedToken.balanceOf(address(taxedVault)), 0);
        assertEq(taxedToken.balanceOf(owner), 101 ether);
    }

    function test_InexactOutgoingTransfersRollbackClaimsWithdrawalsFeesAndExit() public {
        FeeOnTransferToken taxedToken = new FeeOnTransferToken();
        SponsoredTasksVault taxedVault = SponsoredTasksVault(Clones.clone(address(implementation)));
        bytes32 taxedVaultId = keccak256("outgoing-taxed");
        taxedVault.initialize(taxedVaultId, address(taxedToken), owner, controller, address(policy));
        taxedToken.mint(address(taxedVault), 200 ether);

        vm.startPrank(owner);
        taxedVault.configureManager(manager, 100 ether, true);
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTasksVault.TokenRecipientAmountMismatch.selector, 10 ether, 9.9 ether)
        );
        taxedVault.withdrawAvailable(treasury, 10 ether);
        vm.stopPrank();
        assertEq(taxedToken.balanceOf(address(taxedVault)), 200 ether);
        assertEq(taxedVault.totalWithdrawn(), 0);

        bytes32 allocationId = keccak256("outgoing-taxed-allocation");
        bytes32 taskId = keccak256("outgoing-taxed-task");
        address worker = makeAddr("taxedWorker");
        vm.prank(controller);
        taxedVault.reserveTask(allocationId, taskId, manager, 100 ether, 1, FEE_BPS, feeRecipient, TERMS_HASH);
        uint256 feeTotal = 0.5 ether;
        uint256 sponsoredTaskTotal = 99.5 ether;
        bytes32 root = taxedVault.claimLeaf(allocationId, taskId, 1, 0, worker, sponsoredTaskTotal);
        vm.prank(controller);
        taxedVault.installSettlement(allocationId, taskId, root, 1, sponsoredTaskTotal, feeTotal, 100 ether);

        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(worker);
        vm.expectRevert(
            abi.encodeWithSelector(
                SponsoredTasksVault.TokenRecipientAmountMismatch.selector, sponsoredTaskTotal, 98.505 ether
            )
        );
        taxedVault.claim(allocationId, 0, sponsoredTaskTotal, emptyProof);
        assertFalse(taxedVault.isClaimed(allocationId, 0));
        assertEq(_vaultAllocation(taxedVault, allocationId).sponsoredTaskOutstanding, sponsoredTaskTotal);

        vm.prank(feeRecipient);
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTasksVault.TokenRecipientAmountMismatch.selector, feeTotal, 0.495 ether)
        );
        taxedVault.claimFee(allocationId, treasury);
        assertEq(_vaultAllocation(taxedVault, allocationId).feeOutstanding, feeTotal);

        // The exit is the one path that accepts an inexact delivery: the balance leaves net of the
        // token's fee rather than staying locked.
        vm.prank(owner);
        taxedVault.emergencyExitVault(treasury);
        assertEq(uint256(taxedVault.status()), uint256(SponsoredTaskTypes.VaultStatus.Exited));
        assertEq(taxedVault.epoch(), 2);
        assertEq(taxedToken.balanceOf(address(taxedVault)), 0);
        assertEq(taxedToken.balanceOf(treasury), 198 ether);
    }

    /// A receive policy that delivers a transfer to a different address than the one named credits
    /// the named recipient with nothing, so every outgoing claim path reverts and rolls back.
    function test_RedirectingReceivePolicyRevertsClaimClaimToAndClaimFee() public {
        RedirectingReceiveToken rToken = new RedirectingReceiveToken();
        SponsoredTasksVault rVault = SponsoredTasksVault(Clones.clone(address(implementation)));
        rVault.initialize(keccak256("redirecting"), address(rToken), owner, controller, address(policy));
        rToken.mint(address(rVault), 200e6);
        vm.prank(owner);
        rVault.configureManager(manager, 200e6, true);

        uint256 workerKey = 0xBEEF;
        address worker = vm.addr(workerKey);
        address destination = makeAddr("redirectedDestination");
        address elsewhere = makeAddr("redirectTarget");
        bytes32 allocationId = keccak256("redirect-allocation");
        bytes32 taskId = keccak256("redirect-task");
        vm.prank(controller);
        rVault.reserveTask(allocationId, taskId, manager, 100e6, 1, FEE_BPS, feeRecipient, TERMS_HASH);
        uint256 grossAmount = 100e6;
        uint256 feeTotal = grossAmount * FEE_BPS / 10_000;
        uint256 sponsoredTaskTotal = 100e6 - feeTotal;
        bytes32 root = rVault.claimLeaf(allocationId, taskId, 1, 0, worker, sponsoredTaskTotal);
        vm.prank(controller);
        rVault.installSettlement(allocationId, taskId, root, 1, sponsoredTaskTotal, feeTotal, 100e6);
        bytes32[] memory emptyProof = new bytes32[](0);

        rToken.setRedirect(worker, elsewhere);
        vm.prank(worker);
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTasksVault.TokenRecipientAmountMismatch.selector, sponsoredTaskTotal, 0)
        );
        rVault.claim(allocationId, 0, sponsoredTaskTotal, emptyProof);
        rToken.setRedirect(worker, address(0));

        rToken.setRedirect(destination, elsewhere);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signDigest(
            workerKey, rVault.claimDigest(allocationId, 0, worker, destination, sponsoredTaskTotal, 0, deadline)
        );
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTasksVault.TokenRecipientAmountMismatch.selector, sponsoredTaskTotal, 0)
        );
        rVault.claimTo(allocationId, 0, worker, destination, sponsoredTaskTotal, 0, deadline, signature, emptyProof);
        assertEq(rVault.claimNonces(worker), 0);
        assertFalse(rVault.isClaimed(allocationId, 0));

        vm.prank(feeRecipient);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.TokenRecipientAmountMismatch.selector, feeTotal, 0));
        rVault.claimFee(allocationId, destination);
        assertEq(_vaultAllocation(rVault, allocationId).feeOutstanding, feeTotal);
        assertEq(_vaultAllocation(rVault, allocationId).sponsoredTaskOutstanding, sponsoredTaskTotal);
        assertEq(rToken.balanceOf(elsewhere), 0);
        assertEq(rToken.balanceOf(address(rVault)), 200e6);

        rToken.setRedirect(destination, address(0));
        rVault.claimTo(allocationId, 0, worker, destination, sponsoredTaskTotal, 0, deadline, signature, emptyProof);
        assertEq(rToken.balanceOf(destination), sponsoredTaskTotal);
    }

    function test_ExactTransfersRejectVaultAsItsOwnRecipientWithoutMutatingAccounting() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.TokenSenderAmountMismatch.selector, 1 ether, 0));
        vault.withdrawAvailable(address(vault), 1 ether);
        assertEq(vault.totalWithdrawn(), 0);
        assertEq(vault.available(), FUNDED);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.TokenSenderAmountMismatch.selector, FUNDED, 0));
        vault.emergencyExitVault(address(vault));
        assertEq(uint256(vault.status()), uint256(SponsoredTaskTypes.VaultStatus.Active));
        assertEq(vault.epoch(), 1);
        assertEq(token.balanceOf(address(vault)), FUNDED);
    }

    function testFuzz_TopUpAndAvailableWithdrawal(uint128 topUpSeed, uint128 withdrawalSeed) public {
        uint256 topUp = bound(uint256(topUpSeed), 1, 10_000 ether);
        uint256 withdrawal = bound(uint256(withdrawalSeed), 0, FUNDED + topUp);
        token.mint(owner, topUp);

        vm.startPrank(owner);
        vault.fund(topUp);
        vault.withdrawAvailable(treasury, withdrawal);
        vm.stopPrank();

        assertEq(vault.totalFunded(), FUNDED + topUp);
        assertEq(vault.totalWithdrawn(), withdrawal);
        assertEq(token.balanceOf(treasury), withdrawal);
        assertEq(vault.available(), FUNDED + topUp - withdrawal);
        _assertSolvent();
    }

    function test_OnlyOwnerCanConfigureManagersOrWithdraw() public {
        vm.prank(manager);
        vm.expectRevert();
        vault.configureManager(manager, MANAGER_CAP, false);

        vm.prank(manager);
        vm.expectRevert();
        vault.withdrawAvailable(manager, 1);
    }

    function test_MultipleManagersCanBeGrantedAdjustedRevokedAndReactivatedWithoutSharingCaps() public {
        address managerTwo = makeAddr("managerTwo");
        address managerThree = makeAddr("managerThree");

        vm.startPrank(owner);
        vault.configureManager(managerTwo, 300 ether, true);
        vault.configureManager(managerThree, 400 ether, true);
        vault.configureManager(managerTwo, 500 ether, true);
        vm.stopPrank();

        _assertManager(manager, MANAGER_CAP, 0, 0, true, MANAGER_CAP);
        _assertManager(managerTwo, 500 ether, 0, 0, true, 500 ether);
        _assertManager(managerThree, 400 ether, 0, 0, true, 400 ether);

        bytes32 managerOneAllocation = keccak256("manager-one-allocation");
        bytes32 managerTwoAllocation = keccak256("manager-two-allocation");
        bytes32 managerThreeAllocation = keccak256("manager-three-allocation");
        vm.startPrank(controller);
        vault.reserveTask(
            managerOneAllocation,
            keccak256("manager-one-task"),
            manager,
            200 ether,
            1,
            FEE_BPS,
            feeRecipient,
            TERMS_HASH
        );
        vault.reserveTask(
            managerTwoAllocation,
            keccak256("manager-two-task"),
            managerTwo,
            150 ether,
            1,
            FEE_BPS,
            feeRecipient,
            TERMS_HASH
        );
        vault.reserveTask(
            managerThreeAllocation,
            keccak256("manager-three-task"),
            managerThree,
            100 ether,
            1,
            FEE_BPS,
            feeRecipient,
            TERMS_HASH
        );
        vm.stopPrank();

        vm.startPrank(owner);
        vault.configureManager(manager, 600 ether, true);
        vault.configureManager(managerTwo, 250 ether, true);
        vault.configureManager(managerThree, 100 ether, true);
        vault.configureManager(managerTwo, 250 ether, false);
        vm.stopPrank();

        _assertManager(manager, 600 ether, 200 ether, 0, true, 400 ether);
        _assertManager(managerTwo, 250 ether, 150 ether, 0, false, 100 ether);
        _assertManager(managerThree, 100 ether, 100 ether, 0, true, 0);

        bytes32 rejectedAllocation = keccak256("revoked-manager-allocation");
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.ManagerNotActive.selector, managerTwo));
        vault.reserveTask(
            rejectedAllocation,
            keccak256("revoked-manager-task"),
            managerTwo,
            1 ether,
            1,
            FEE_BPS,
            feeRecipient,
            TERMS_HASH
        );
        assertEq(
            uint256(_vaultAllocation(vault, rejectedAllocation).status),
            uint256(SponsoredTaskTypes.AllocationStatus.None)
        );

        vm.prank(controller);
        assertTrue(vault.releaseTask(managerTwoAllocation));
        _assertManager(managerTwo, 250 ether, 0, 0, false, 250 ether);

        vm.prank(owner);
        vault.configureManager(managerTwo, 350 ether, true);
        bytes32 reactivatedAllocation = keccak256("reactivated-manager-allocation");
        vm.prank(controller);
        vault.reserveTask(
            reactivatedAllocation,
            keccak256("reactivated-manager-task"),
            managerTwo,
            200 ether,
            1,
            FEE_BPS,
            feeRecipient,
            TERMS_HASH
        );

        _assertManager(manager, 600 ether, 200 ether, 0, true, 400 ether);
        _assertManager(managerTwo, 350 ether, 200 ether, 0, true, 150 ether);
        _assertManager(managerThree, 100 ether, 100 ether, 0, true, 0);
        assertEq(vault.totalReserved(), 500 ether);
        assertEq(vault.available(), 500 ether);
        _assertSolvent();
    }

    function test_ManagerCapReserveBindAndReleaseRestoreCapacity() public {
        _reserve(ALLOCATION_ID, bytes32(0), 500 ether);

        SponsoredTaskTypes.ManagerAccount memory account = vault.managerAccount(manager);
        assertEq(account.cap, MANAGER_CAP);
        assertEq(account.reserved, 500 ether);
        assertEq(account.spent, 0);
        assertTrue(account.active);
        assertEq(vault.managerRemaining(manager), 300 ether);
        assertEq(vault.totalReserved(), 500 ether);
        assertEq(vault.available(), 500 ether);

        vm.prank(controller);
        assertTrue(vault.bindTask(ALLOCATION_ID, TASK_ID));
        vm.prank(controller);
        assertFalse(vault.bindTask(ALLOCATION_ID, TASK_ID));

        vm.prank(controller);
        assertTrue(vault.releaseTask(ALLOCATION_ID));
        vm.prank(controller);
        assertFalse(vault.releaseTask(ALLOCATION_ID));

        account = vault.managerAccount(manager);
        assertEq(account.reserved, 0);
        assertEq(account.spent, 0);
        assertEq(vault.managerRemaining(manager), MANAGER_CAP);
        assertEq(vault.totalReserved(), 0);
        assertEq(vault.available(), FUNDED);

        SponsoredTaskTypes.Allocation memory item = _vaultAllocation(vault, ALLOCATION_ID);
        assertEq(item.taskId, TASK_ID);
        assertEq(item.releasedAmount, 500 ether);
        assertEq(uint256(item.status), uint256(SponsoredTaskTypes.AllocationStatus.Released));
        _assertSolvent();
    }

    function test_ManagerCapCannotBeReducedBelowReservedPlusSpent() public {
        _reserve(ALLOCATION_ID, TASK_ID, 500 ether);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.InvalidManagerCap.selector, 500 ether, 499 ether));
        vault.configureManager(manager, 499 ether, true);

        _installSingle(ALLOCATION_ID, TASK_ID, 300 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.InvalidManagerCap.selector, 300 ether, 299 ether));
        vault.configureManager(manager, 299 ether, true);

        vm.prank(owner);
        vault.configureManager(manager, 300 ether, true);
        assertEq(vault.managerRemaining(manager), 0);
    }

    function test_ManagerRevocationBlocksNewReservationsButNotExistingSettlement() public {
        _reserve(ALLOCATION_ID, TASK_ID, 400 ether);
        vm.prank(owner);
        vault.configureManager(manager, MANAGER_CAP, false);

        uint64 currentEpoch = vault.epoch();
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.ManagerNotActive.selector, manager));
        vault.reserveTask(
            keccak256("next"), keccak256("next-task"), manager, 1 ether, currentEpoch, FEE_BPS, feeRecipient, TERMS_HASH
        );

        _installSingle(ALLOCATION_ID, TASK_ID, 300 ether);
        SponsoredTaskTypes.ManagerAccount memory account = vault.managerAccount(manager);
        assertFalse(account.active);
        assertEq(account.reserved, 0);
        assertEq(account.spent, 300 ether);
    }

    function test_ReserveChecksControllerEpochFeeCapAndAvailable() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.OnlyController.selector, manager));
        vault.reserveTask(ALLOCATION_ID, TASK_ID, manager, 1 ether, 1, FEE_BPS, feeRecipient, TERMS_HASH);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.AllocationEpochMismatch.selector, 2, 1));
        vault.reserveTask(ALLOCATION_ID, TASK_ID, manager, 1 ether, 2, FEE_BPS, feeRecipient, TERMS_HASH);

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(
                SponsoredTasksVault.FeeTermsMismatch.selector, uint16(51), feeRecipient, FEE_BPS, feeRecipient
            )
        );
        vault.reserveTask(ALLOCATION_ID, TASK_ID, manager, 1 ether, 1, 51, feeRecipient, TERMS_HASH);

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(
                SponsoredTasksVault.ManagerAllowanceExceeded.selector, manager, MANAGER_CAP + 1, MANAGER_CAP
            )
        );
        vault.reserveTask(ALLOCATION_ID, TASK_ID, manager, MANAGER_CAP + 1, 1, FEE_BPS, feeRecipient, TERMS_HASH);

        address largeManager = makeAddr("largeManager");
        vm.prank(owner);
        vault.configureManager(largeManager, FUNDED + 1, true);
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.InsufficientAvailable.selector, FUNDED + 1, FUNDED));
        vault.reserveTask(ALLOCATION_ID, TASK_ID, largeManager, FUNDED + 1, 1, FEE_BPS, feeRecipient, TERMS_HASH);
    }

    function test_FeeSnapshotSurvivesPolicyChange() public {
        _reserve(ALLOCATION_ID, TASK_ID, 400 ether);
        address newRecipient = makeAddr("newFeeRecipient");
        vm.prank(policyOwner);
        policy.setFeeTerms(100, newRecipient);

        SponsoredTaskTypes.Allocation memory oldItem = _vaultAllocation(vault, ALLOCATION_ID);
        assertEq(oldItem.feeBps, FEE_BPS);
        assertEq(oldItem.feeRecipient, feeRecipient);

        bytes32 newAllocation = keccak256("new-allocation");
        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(
                SponsoredTasksVault.FeeTermsMismatch.selector, FEE_BPS, feeRecipient, uint16(100), newRecipient
            )
        );
        vault.reserveTask(
            newAllocation, keccak256("new-task"), manager, 100 ether, 1, FEE_BPS, feeRecipient, TERMS_HASH
        );

        vm.prank(controller);
        vault.reserveTask(newAllocation, keccak256("new-task"), manager, 100 ether, 1, 100, newRecipient, TERMS_HASH);
        SponsoredTaskTypes.Allocation memory newItem = _vaultAllocation(vault, newAllocation);
        assertEq(newItem.feeBps, 100);
        assertEq(newItem.feeRecipient, newRecipient);
    }

    function test_PartialSettlementSpendsDistributedGrossAndReleasesRemainder() public {
        _reserve(ALLOCATION_ID, TASK_ID, 500 ether);
        (bytes32 root, uint256 sponsoredTaskTotal, uint256 feeTotal) =
            _singleSettlementValues(ALLOCATION_ID, TASK_ID, 300 ether, makeAddr("worker"));

        vm.prank(controller);
        assertTrue(vault.installSettlement(ALLOCATION_ID, TASK_ID, root, 1, sponsoredTaskTotal, feeTotal, 300 ether));

        SponsoredTaskTypes.Allocation memory item = _vaultAllocation(vault, ALLOCATION_ID);
        assertEq(item.grossAmount, 500 ether);
        assertEq(item.distributedGross, 300 ether);
        assertEq(item.sponsoredTaskOutstanding, sponsoredTaskTotal);
        assertEq(item.feeOutstanding, feeTotal);
        assertEq(item.releasedAmount, 200 ether);
        assertEq(uint256(item.status), uint256(SponsoredTaskTypes.AllocationStatus.Claimable));

        SponsoredTaskTypes.ManagerAccount memory account = vault.managerAccount(manager);
        assertEq(account.reserved, 0);
        assertEq(account.spent, 300 ether);
        assertEq(vault.managerRemaining(manager), 500 ether);
        assertEq(vault.totalReserved(), 0);
        assertEq(vault.totalClaimable(), 300 ether);
        assertEq(vault.available(), 700 ether);
        _assertSolvent();

        vm.prank(controller);
        assertFalse(vault.installSettlement(ALLOCATION_ID, TASK_ID, root, 1, sponsoredTaskTotal, feeTotal, 300 ether));
    }

    function test_InstallSettlementRejectsInvalidTotalsFeeAndCommitment() public {
        _reserve(ALLOCATION_ID, TASK_ID, 500 ether);
        bytes32 root = keccak256("root");

        vm.prank(controller);
        vm.expectRevert(SponsoredTasksVault.InvalidSettlementTotals.selector);
        vault.installSettlement(ALLOCATION_ID, TASK_ID, root, 1, 99 ether, 2 ether, 100 ether);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.SettlementFeeTooHigh.selector, 1 ether, 0.5 ether));
        vault.installSettlement(ALLOCATION_ID, TASK_ID, root, 1, 99 ether, 1 ether, 100 ether);

        vm.prank(controller);
        vm.expectRevert(SponsoredTasksVault.SettlementCommitmentRequired.selector);
        vault.installSettlement(ALLOCATION_ID, TASK_ID, bytes32(0), 0, 99.5 ether, 0.5 ether, 100 ether);

        vm.prank(controller);
        vm.expectRevert(SponsoredTasksVault.UnexpectedSettlementCommitment.selector);
        vault.installSettlement(ALLOCATION_ID, TASK_ID, root, 1, 0, 0, 0);

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTasksVault.SettlementExceedsAllocation.selector, 501 ether, 500 ether)
        );
        vault.installSettlement(ALLOCATION_ID, TASK_ID, root, 1, 500 ether, 1 ether, 501 ether);
    }

    function test_TwoIndependentBuilderClaimsAndFeeClaim() public {
        address workerOne = makeAddr("workerOne");
        address workerTwo = makeAddr("workerTwo");
        uint256 amountOne = 199 ether;
        uint256 amountTwo = 99.5 ether;
        uint256 feeTotal = 1.5 ether;
        _reserve(ALLOCATION_ID, TASK_ID, 300 ether);

        bytes32 leafOne = vault.claimLeaf(ALLOCATION_ID, TASK_ID, 1, 0, workerOne, amountOne);
        bytes32 leafTwo = vault.claimLeaf(ALLOCATION_ID, TASK_ID, 1, 1, workerTwo, amountTwo);
        bytes32 root = _hashPair(leafOne, leafTwo);
        vm.prank(controller);
        vault.installSettlement(ALLOCATION_ID, TASK_ID, root, 2, amountOne + amountTwo, feeTotal, 300 ether);

        bytes32[] memory proofOne = new bytes32[](1);
        proofOne[0] = leafTwo;
        vm.prank(workerOne);
        vault.claim(ALLOCATION_ID, 0, amountOne, proofOne);
        assertEq(token.balanceOf(workerOne), amountOne);
        assertTrue(vault.isClaimed(ALLOCATION_ID, 0));

        vm.prank(workerOne);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.ClaimAlreadyPaid.selector, ALLOCATION_ID, 0));
        vault.claim(ALLOCATION_ID, 0, amountOne, proofOne);

        bytes32[] memory proofTwo = new bytes32[](1);
        proofTwo[0] = leafOne;
        vm.prank(workerTwo);
        vault.claim(ALLOCATION_ID, 1, amountTwo, proofTwo);

        vm.prank(workerTwo);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.NotFeeRecipient.selector, workerTwo, feeRecipient));
        vault.claimFee(ALLOCATION_ID, treasury);

        vm.prank(feeRecipient);
        assertEq(vault.claimFee(ALLOCATION_ID, treasury), feeTotal);

        SponsoredTaskTypes.Allocation memory item = _vaultAllocation(vault, ALLOCATION_ID);
        assertEq(item.sponsoredTaskOutstanding, 0);
        assertEq(item.sponsoredTaskPaid, amountOne + amountTwo);
        assertEq(item.feeOutstanding, 0);
        assertEq(item.feePaid, feeTotal);
        assertEq(uint256(item.status), uint256(SponsoredTaskTypes.AllocationStatus.Settled));
        assertEq(vault.totalClaimable(), 0);
        assertEq(vault.totalSponsoredTaskPaid(), amountOne + amountTwo);
        assertEq(vault.totalFeesPaid(), feeTotal);
        assertEq(token.balanceOf(treasury), feeTotal);
        _assertSolvent();
    }

    function test_FeeOnlySettlementAtMaximumFeeNeedsNoMerkleCommitment() public {
        vm.prank(policyOwner);
        policy.setFeeTerms(10_000, feeRecipient);
        bytes32 allocationId = keccak256("fee-only-allocation");
        bytes32 taskId = keccak256("fee-only-task");
        uint64 currentEpoch = vault.epoch();
        vm.prank(controller);
        vault.reserveTask(allocationId, taskId, manager, 100 ether, currentEpoch, 10_000, feeRecipient, TERMS_HASH);

        vm.prank(controller);
        vault.installSettlement(allocationId, taskId, bytes32(0), 0, 0, 100 ether, 100 ether);
        SponsoredTaskTypes.Allocation memory item = _vaultAllocation(vault, allocationId);
        assertEq(item.sponsoredTaskOutstanding, 0);
        assertEq(item.feeOutstanding, 100 ether);
        assertEq(item.rewardsRoot, bytes32(0));
        assertEq(item.leafCount, 0);
        assertEq(uint256(item.status), uint256(SponsoredTaskTypes.AllocationStatus.Claimable));

        vm.prank(feeRecipient);
        vault.claimFee(allocationId, treasury);
        assertEq(token.balanceOf(treasury), 100 ether);
        assertEq(
            uint256(vault.effectiveAllocationStatus(allocationId)), uint256(SponsoredTaskTypes.AllocationStatus.Settled)
        );
        _assertSolvent();
    }

    function test_ClaimRejectsWrongWorkerAmountProofAndIndex() public {
        address worker = makeAddr("worker");
        _reserve(ALLOCATION_ID, TASK_ID, 100 ether);
        (bytes32 root, uint256 sponsoredTaskTotal, uint256 feeTotal) =
            _singleSettlementValues(ALLOCATION_ID, TASK_ID, 100 ether, worker);
        vm.prank(controller);
        vault.installSettlement(ALLOCATION_ID, TASK_ID, root, 1, sponsoredTaskTotal, feeTotal, 100 ether);
        bytes32[] memory emptyProof = new bytes32[](0);

        vm.prank(makeAddr("imposter"));
        vm.expectRevert(SponsoredTasksVault.InvalidClaimProof.selector);
        vault.claim(ALLOCATION_ID, 0, sponsoredTaskTotal, emptyProof);

        vm.prank(worker);
        vm.expectRevert(SponsoredTasksVault.InvalidClaimProof.selector);
        vault.claim(ALLOCATION_ID, 0, sponsoredTaskTotal - 1, emptyProof);

        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.ClaimIndexOutOfBounds.selector, 1, 1));
        vault.claim(ALLOCATION_ID, 1, sponsoredTaskTotal, emptyProof);
    }

    function test_GaslessClaimToBindsDestinationNonceDeadlineAndFullContext() public {
        uint256 workerKey = 0xA11CE;
        address worker = vm.addr(workerKey);
        address destination = makeAddr("builderDestination");
        _reserve(ALLOCATION_ID, TASK_ID, 100 ether);
        (bytes32 root, uint256 sponsoredTaskTotal, uint256 feeTotal) =
            _singleSettlementValues(ALLOCATION_ID, TASK_ID, 100 ether, worker);
        vm.prank(controller);
        vault.installSettlement(ALLOCATION_ID, TASK_ID, root, 1, sponsoredTaskTotal, feeTotal, 100 ether);

        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = vault.claimDigest(ALLOCATION_ID, 0, worker, destination, sponsoredTaskTotal, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(workerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        bytes32[] memory emptyProof = new bytes32[](0);

        vm.expectRevert(SponsoredTasksVault.InvalidClaimSignature.selector);
        vault.claimTo(
            ALLOCATION_ID,
            0,
            worker,
            makeAddr("changedDestination"),
            sponsoredTaskTotal,
            0,
            deadline,
            signature,
            emptyProof
        );
        assertEq(vault.claimNonces(worker), 0);

        vault.claimTo(ALLOCATION_ID, 0, worker, destination, sponsoredTaskTotal, 0, deadline, signature, emptyProof);
        assertEq(token.balanceOf(destination), sponsoredTaskTotal);
        assertEq(vault.claimNonces(worker), 1);

        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.InvalidClaimNonce.selector, worker, 1, 0));
        vault.claimTo(ALLOCATION_ID, 0, worker, destination, sponsoredTaskTotal, 0, deadline, signature, emptyProof);
    }

    function test_GaslessClaimRejectsEveryContextMutationAndManagerCannotRedirectOrClaim() public {
        uint256 workerKey = 0xD00D;
        address worker = vm.addr(workerKey);
        address destination = makeAddr("authorizedBuilderDestination");
        address redirectedDestination = makeAddr("managerSelectedDestination");
        _reserve(ALLOCATION_ID, TASK_ID, 100 ether);
        (bytes32 root, uint256 sponsoredTaskTotal, uint256 feeTotal) =
            _singleSettlementValues(ALLOCATION_ID, TASK_ID, 100 ether, worker);
        vm.prank(controller);
        vault.installSettlement(ALLOCATION_ID, TASK_ID, root, 1, sponsoredTaskTotal, feeTotal, 100 ether);

        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = vault.claimDigest(ALLOCATION_ID, 0, worker, destination, sponsoredTaskTotal, 0, deadline);
        assertEq(
            digest,
            _claimContextDigest(
                address(vault), block.chainid, 1, TASK_ID, worker, destination, sponsoredTaskTotal, deadline
            )
        );
        bytes memory validSignature = _signDigest(workerKey, digest);
        bytes32[] memory emptyProof = new bytes32[](0);

        _expectInvalidClaimSignature(
            worker, destination, sponsoredTaskTotal, deadline, _signDigest(0xBAD, digest), emptyProof
        );
        _expectInvalidClaimSignature(
            worker,
            destination,
            sponsoredTaskTotal,
            deadline,
            _signDigest(
                workerKey,
                _claimContextDigest(
                    address(vault),
                    block.chainid,
                    1,
                    keccak256("wrong-task"),
                    worker,
                    destination,
                    sponsoredTaskTotal,
                    deadline
                )
            ),
            emptyProof
        );
        _expectInvalidClaimSignature(
            worker,
            destination,
            sponsoredTaskTotal,
            deadline,
            _signDigest(
                workerKey,
                _claimContextDigest(
                    address(implementation),
                    block.chainid,
                    1,
                    TASK_ID,
                    worker,
                    destination,
                    sponsoredTaskTotal,
                    deadline
                )
            ),
            emptyProof
        );
        _expectInvalidClaimSignature(
            worker,
            destination,
            sponsoredTaskTotal,
            deadline,
            _signDigest(
                workerKey,
                _claimContextDigest(
                    address(vault), block.chainid, 2, TASK_ID, worker, destination, sponsoredTaskTotal, deadline
                )
            ),
            emptyProof
        );

        // Read through the vault so the optimizer cannot treat CHAINID as invariant across the cheatcode mutation.
        uint256 originalChainId = vault.settlementChain();
        vm.chainId(originalChainId + 1);
        _expectInvalidClaimSignature(worker, destination, sponsoredTaskTotal, deadline, validSignature, emptyProof);
        vm.chainId(originalChainId);

        _expectInvalidClaimSignature(
            worker, redirectedDestination, sponsoredTaskTotal, deadline, validSignature, emptyProof
        );
        _expectInvalidClaimSignature(worker, destination, sponsoredTaskTotal - 1, deadline, validSignature, emptyProof);

        vm.prank(manager);
        vm.expectRevert(SponsoredTasksVault.InvalidClaimProof.selector);
        vault.claim(ALLOCATION_ID, 0, sponsoredTaskTotal, emptyProof);

        vm.prank(manager);
        vm.expectRevert(SponsoredTasksVault.InvalidClaimSignature.selector);
        vault.claimTo(
            ALLOCATION_ID, 0, worker, redirectedDestination, sponsoredTaskTotal, 0, deadline, validSignature, emptyProof
        );

        vm.prank(manager);
        vault.claimTo(
            ALLOCATION_ID, 0, worker, destination, sponsoredTaskTotal, 0, deadline, validSignature, emptyProof
        );
        assertEq(token.balanceOf(destination), sponsoredTaskTotal);
        assertEq(token.balanceOf(manager), 0);
        assertEq(token.balanceOf(redirectedDestination), 0);
        assertEq(vault.claimNonces(worker), 1);
        assertTrue(vault.isClaimed(ALLOCATION_ID, 0));

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.InvalidClaimNonce.selector, worker, 1, 0));
        vault.claimTo(
            ALLOCATION_ID, 0, worker, destination, sponsoredTaskTotal, 0, deadline, validSignature, emptyProof
        );
    }

    function test_GaslessClaimSupportsERC1271Worker() public {
        uint256 signerKey = 0xB0B;
        address signer = vm.addr(signerKey);
        ERC1271WalletMock worker = new ERC1271WalletMock(signer);
        address destination = makeAddr("safeDestination");
        bytes32 allocationId = keccak256("erc1271-allocation");
        bytes32 taskId = keccak256("erc1271-task");
        _reserve(allocationId, taskId, 100 ether);
        (bytes32 root, uint256 sponsoredTaskTotal, uint256 feeTotal) =
            _singleSettlementValues(allocationId, taskId, 100 ether, address(worker));
        vm.prank(controller);
        vault.installSettlement(allocationId, taskId, root, 1, sponsoredTaskTotal, feeTotal, 100 ether);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest =
            vault.claimDigest(allocationId, 0, address(worker), destination, sponsoredTaskTotal, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes32[] memory emptyProof = new bytes32[](0);
        vault.claimTo(
            allocationId,
            0,
            address(worker),
            destination,
            sponsoredTaskTotal,
            0,
            deadline,
            abi.encodePacked(r, s, v),
            emptyProof
        );
        assertEq(token.balanceOf(destination), sponsoredTaskTotal);
    }

    function test_GaslessClaimExpires() public {
        uint256 workerKey = 0xCAFE;
        address worker = vm.addr(workerKey);
        _reserve(ALLOCATION_ID, TASK_ID, 100 ether);
        (bytes32 root, uint256 sponsoredTaskTotal, uint256 feeTotal) =
            _singleSettlementValues(ALLOCATION_ID, TASK_ID, 100 ether, worker);
        vm.prank(controller);
        vault.installSettlement(ALLOCATION_ID, TASK_ID, root, 1, sponsoredTaskTotal, feeTotal, 100 ether);

        uint256 deadline = block.timestamp + 1;
        bytes32 digest = vault.claimDigest(ALLOCATION_ID, 0, worker, worker, sponsoredTaskTotal, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(workerKey, digest);
        vm.warp(deadline + 1);

        bytes32[] memory emptyProof = new bytes32[](0);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.ClaimExpired.selector, deadline));
        vault.claimTo(
            ALLOCATION_ID, 0, worker, worker, sponsoredTaskTotal, 0, deadline, abi.encodePacked(r, s, v), emptyProof
        );
    }

    function test_WithdrawCannotConsumeReservedOrClaimableFunds() public {
        _reserve(ALLOCATION_ID, TASK_ID, 400 ether);
        vm.prank(owner);
        vault.withdrawAvailable(treasury, 600 ether);
        assertEq(vault.available(), 0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.InsufficientAvailable.selector, 1, 0));
        vault.withdrawAvailable(treasury, 1);

        _installSingle(ALLOCATION_ID, TASK_ID, 300 ether);
        assertEq(vault.available(), 100 ether);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTasksVault.InsufficientAvailable.selector, 100 ether + 1, 100 ether)
        );
        vault.withdrawAvailable(treasury, 100 ether + 1);
        _assertSolvent();
    }

    function test_EmergencyExitSweepsEverythingAndInvalidatesOldEpoch() public {
        bytes32 reservedAllocation = keccak256("reserved");
        bytes32 claimableAllocation = keccak256("claimable");
        bytes32 claimableTask = keccak256("claimable-task");
        address worker = makeAddr("worker");
        _reserve(reservedAllocation, keccak256("reserved-task"), 400 ether);
        _reserve(claimableAllocation, claimableTask, 300 ether);
        (bytes32 root, uint256 sponsoredTaskTotal, uint256 feeTotal) =
            _singleSettlementValues(claimableAllocation, claimableTask, 300 ether, worker);
        vm.prank(controller);
        vault.installSettlement(claimableAllocation, claimableTask, root, 1, sponsoredTaskTotal, feeTotal, 300 ether);

        uint256 balanceBefore = token.balanceOf(address(vault));
        vm.prank(owner);
        assertEq(vault.emergencyExitVault(treasury), balanceBefore);

        assertEq(token.balanceOf(treasury), balanceBefore);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.epoch(), 2);
        assertEq(uint256(vault.status()), uint256(SponsoredTaskTypes.VaultStatus.Exited));
        assertEq(vault.totalReserved(), 0);
        assertEq(vault.totalClaimable(), 0);
        assertEq(vault.totalDefaultedReserved(), 400 ether);
        assertEq(vault.totalDefaultedClaimable(), 300 ether);
        assertEq(vault.managerRemaining(manager), 0);
        SponsoredTaskTypes.ManagerAccount memory exitedAccount = vault.managerAccount(manager);
        assertFalse(exitedAccount.active);
        assertEq(exitedAccount.cap, MANAGER_CAP, "terminal getter preserves the historical cap");
        assertEq(exitedAccount.reserved, 400 ether, "terminal exit records reserved defaults globally");
        assertEq(exitedAccount.spent, 300 ether, "terminal exit preserves historical spend");
        assertEq(
            uint256(vault.effectiveAllocationStatus(reservedAllocation)),
            uint256(SponsoredTaskTypes.AllocationStatus.DefaultedByOwner)
        );
        assertEq(
            uint256(vault.effectiveAllocationStatus(claimableAllocation)),
            uint256(SponsoredTaskTypes.AllocationStatus.DefaultedByOwner)
        );

        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(worker);
        vm.expectRevert(SponsoredTasksVault.VaultNotActive.selector);
        vault.claim(claimableAllocation, 0, sponsoredTaskTotal, emptyProof);

        vm.prank(controller);
        vm.expectRevert(SponsoredTasksVault.VaultNotActive.selector);
        vault.releaseTask(reservedAllocation);

        vm.prank(owner);
        vm.expectRevert(SponsoredTasksVault.VaultNotActive.selector);
        vault.fund(1);
    }

    function test_EmergencyExitOnlyOwnerAndCannotRepeatOrRenounce() public {
        vm.prank(manager);
        vm.expectRevert();
        vault.emergencyExitVault(manager);

        vm.prank(owner);
        vm.expectRevert(SponsoredTasksVault.OwnershipRenunciationDisabled.selector);
        vault.renounceOwnership();

        vm.prank(owner);
        vault.emergencyExitVault(owner);
        vm.prank(owner);
        vm.expectRevert(SponsoredTasksVault.VaultNotActive.selector);
        vault.emergencyExitVault(owner);
    }

    function test_FeePolicyConfigurationValidationAndOwnership() public {
        SponsoredTaskTypes.FeeTerms memory terms = policy.feeTerms();
        assertEq(terms.bps, FEE_BPS);
        assertEq(terms.recipient, feeRecipient);

        vm.prank(policyOwner);
        policy.setFeeTerms(0, address(0));
        terms = policy.feeTerms();
        assertEq(terms.bps, 0);
        assertEq(terms.recipient, address(0));

        vm.prank(policyOwner);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskFeePolicy.FeeBpsTooHigh.selector, uint16(10_001)));
        policy.setFeeTerms(10_001, feeRecipient);

        vm.prank(policyOwner);
        vm.expectRevert(SponsoredTaskFeePolicy.FeeRecipientRequired.selector);
        policy.setFeeTerms(1, address(0));

        vm.prank(manager);
        vm.expectRevert();
        policy.setFeeTerms(100, manager);
    }

    function _reserve(bytes32 allocationId, bytes32 taskId, uint256 grossAmount) internal {
        uint64 currentEpoch = vault.epoch();
        vm.prank(controller);
        vault.reserveTask(allocationId, taskId, manager, grossAmount, currentEpoch, FEE_BPS, feeRecipient, TERMS_HASH);
    }

    function _assertManager(
        address managerAddress,
        uint256 cap,
        uint256 reserved,
        uint256 spent,
        bool active,
        uint256 remaining
    ) private view {
        SponsoredTaskTypes.ManagerAccount memory account = vault.managerAccount(managerAddress);
        assertEq(account.cap, cap);
        assertEq(account.reserved, reserved);
        assertEq(account.spent, spent);
        assertEq(account.active, active);
        assertEq(vault.managerRemaining(managerAddress), remaining);
        assertEq(account.cap, account.reserved + account.spent + remaining);
    }

    function _expectInvalidClaimSignature(
        address worker,
        address destination,
        uint256 amount,
        uint256 deadline,
        bytes memory signature,
        bytes32[] memory proof
    ) private {
        vm.expectRevert(SponsoredTasksVault.InvalidClaimSignature.selector);
        vault.claimTo(ALLOCATION_ID, 0, worker, destination, amount, 0, deadline, signature, proof);
        assertEq(vault.claimNonces(worker), 0);
        assertFalse(vault.isClaimed(ALLOCATION_ID, 0));
    }

    function _claimContextDigest(
        address verifyingVault,
        uint256 chainId,
        uint64 claimEpoch,
        bytes32 taskId,
        address worker,
        address destination,
        uint256 amount,
        uint256 deadline
    ) private pure returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("SponsoredTasksVault")),
                keccak256(bytes("1")),
                chainId,
                verifyingVault
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "ClaimTo(bytes32 vaultId,uint64 epoch,bytes32 allocationId,bytes32 taskId,uint256 index,address worker,address destination,uint256 amount,uint256 nonce,uint256 deadline)"
                ),
                VAULT_ID,
                claimEpoch,
                ALLOCATION_ID,
                taskId,
                uint256(0),
                worker,
                destination,
                amount,
                uint256(0),
                deadline
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }

    function _signDigest(uint256 privateKey, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _installSingle(bytes32 allocationId, bytes32 taskId, uint256 distributedGross) internal {
        address worker = makeAddr(string.concat("worker-", vm.toString(allocationId)));
        (bytes32 root, uint256 sponsoredTaskTotal, uint256 feeTotal) =
            _singleSettlementValues(allocationId, taskId, distributedGross, worker);
        vm.prank(controller);
        vault.installSettlement(allocationId, taskId, root, 1, sponsoredTaskTotal, feeTotal, distributedGross);
    }

    function _singleSettlementValues(bytes32 allocationId, bytes32 taskId, uint256 distributedGross, address worker)
        internal
        view
        returns (bytes32 root, uint256 sponsoredTaskTotal, uint256 feeTotal)
    {
        feeTotal = distributedGross * FEE_BPS / 10_000;
        sponsoredTaskTotal = distributedGross - feeTotal;
        root = vault.claimLeaf(allocationId, taskId, vault.epoch(), 0, worker, sponsoredTaskTotal);
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _assertSolvent() internal view {
        assertEq(token.balanceOf(address(vault)), vault.available() + vault.totalReserved() + vault.totalClaimable());
    }
}

contract SponsoredTasksVaultHandler {
    uint16 internal constant FEE_BPS = 50;
    bytes32 internal constant TERMS_HASH = keccak256("invariant-terms");

    MockERC20 public immutable token;
    SponsoredTasksVault public immutable vault;
    bytes32[] private _allocationIds;
    uint256 private _nonce;
    bool private _bootstrapped;

    constructor(MockERC20 token_, SponsoredTasksVault vault_) {
        token = token_;
        vault = vault_;
    }

    function bootstrap(uint256 amount, uint256 cap) external {
        require(!_bootstrapped);
        _bootstrapped = true;
        token.approve(address(vault), type(uint256).max);
        vault.fund(amount);
        vault.configureManager(address(this), cap, true);
    }

    function fund(uint96 rawAmount) external {
        if (!_active()) return;
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = uint256(rawAmount) % balance + 1;
        vault.fund(amount);
    }

    function reserve(uint96 rawAmount) external {
        if (!_active()) return;
        uint256 capacity = vault.managerRemaining(address(this));
        uint256 availableAmount = vault.available();
        uint256 maximum = capacity < availableAmount ? capacity : availableAmount;
        if (maximum == 0) return;
        uint256 amount = uint256(rawAmount) % maximum + 1;

        bytes32 allocationId = keccak256(abi.encode("invariant-allocation", _nonce));
        bytes32 taskId = keccak256(abi.encode("invariant-task", _nonce));
        ++_nonce;
        _allocationIds.push(allocationId);
        vault.reserveTask(
            allocationId, taskId, address(this), amount, vault.epoch(), FEE_BPS, address(this), TERMS_HASH
        );
    }

    function release(uint256 seed) external {
        if (!_active() || _allocationIds.length == 0) return;
        bytes32 allocationId = _allocationIds[seed % _allocationIds.length];
        SponsoredTaskTypes.Allocation memory item = _vaultAllocation(vault, allocationId);
        if (item.status != SponsoredTaskTypes.AllocationStatus.Reserved) return;
        vault.releaseTask(allocationId);
    }

    function settle(uint256 seed, uint96 rawDistributed) external {
        if (!_active() || _allocationIds.length == 0) return;
        bytes32 allocationId = _allocationIds[seed % _allocationIds.length];
        SponsoredTaskTypes.Allocation memory item = _vaultAllocation(vault, allocationId);
        if (item.status != SponsoredTaskTypes.AllocationStatus.Reserved) return;

        uint256 distributedGross = uint256(rawDistributed) % (item.grossAmount + 1);
        uint256 feeTotal = distributedGross * FEE_BPS / 10_000;
        uint256 sponsoredTaskTotal = distributedGross - feeTotal;
        bytes32 root;
        uint32 leafCount;
        if (sponsoredTaskTotal != 0) {
            root = vault.claimLeaf(allocationId, item.taskId, item.epoch, 0, address(this), sponsoredTaskTotal);
            leafCount = 1;
        }
        vault.installSettlement(
            allocationId, item.taskId, root, leafCount, sponsoredTaskTotal, feeTotal, distributedGross
        );
    }

    function claimBuilder(uint256 seed) external {
        if (!_active() || _allocationIds.length == 0) return;
        bytes32 allocationId = _allocationIds[seed % _allocationIds.length];
        SponsoredTaskTypes.Allocation memory item = _vaultAllocation(vault, allocationId);
        if (item.status != SponsoredTaskTypes.AllocationStatus.Claimable || item.sponsoredTaskOutstanding == 0) return;
        bytes32[] memory proof = new bytes32[](0);
        vault.claim(allocationId, 0, item.sponsoredTaskOutstanding, proof);
    }

    function claimFee(uint256 seed) external {
        if (!_active() || _allocationIds.length == 0) return;
        bytes32 allocationId = _allocationIds[seed % _allocationIds.length];
        SponsoredTaskTypes.Allocation memory item = _vaultAllocation(vault, allocationId);
        if (item.status != SponsoredTaskTypes.AllocationStatus.Claimable || item.feeOutstanding == 0) return;
        vault.claimFee(allocationId, address(this));
    }

    function withdraw(uint96 rawAmount) external {
        if (!_active()) return;
        uint256 availableAmount = vault.available();
        if (availableAmount == 0) return;
        uint256 amount = uint256(rawAmount) % availableAmount + 1;
        vault.withdrawAvailable(address(this), amount);
    }

    function emergencyExit(uint8 trigger) external {
        if (!_active() || trigger != 0) return;
        vault.emergencyExitVault(address(this));
    }

    function allocationCount() external view returns (uint256) {
        return _allocationIds.length;
    }

    function allocationIdAt(uint256 index) external view returns (bytes32) {
        return _allocationIds[index];
    }

    function _active() private view returns (bool) {
        return vault.status() == SponsoredTaskTypes.VaultStatus.Active;
    }
}

contract SponsoredTasksVaultInvariantTest is Test {
    uint256 internal constant INITIAL_FUNDING = 1_000_000 ether;
    uint256 internal constant MANAGER_CAP = 800_000 ether;

    MockERC20 internal token;
    SponsoredTaskFeePolicy internal policy;
    SponsoredTasksVault internal vault;
    SponsoredTasksVaultHandler internal handler;

    function setUp() public {
        token = new MockERC20("Invariant Project", "IPROJECT", 18, address(this));
        policy = new SponsoredTaskFeePolicy(address(this), 50, address(this));
        SponsoredTasksVault implementation = new SponsoredTasksVault();
        vault = SponsoredTasksVault(Clones.clone(address(implementation)));
        handler = new SponsoredTasksVaultHandler(token, vault);
        policy.setFeeTerms(50, address(handler));
        vault.initialize(
            keccak256("invariant-vault"), address(token), address(handler), address(handler), address(policy)
        );

        token.mint(address(handler), 10_000_000 ether);
        handler.bootstrap(INITIAL_FUNDING, MANAGER_CAP);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = SponsoredTasksVaultHandler.fund.selector;
        selectors[1] = SponsoredTasksVaultHandler.reserve.selector;
        selectors[2] = SponsoredTasksVaultHandler.release.selector;
        selectors[3] = SponsoredTasksVaultHandler.settle.selector;
        selectors[4] = SponsoredTasksVaultHandler.claimBuilder.selector;
        selectors[5] = SponsoredTasksVaultHandler.claimFee.selector;
        selectors[6] = SponsoredTasksVaultHandler.withdraw.selector;
        selectors[7] = SponsoredTasksVaultHandler.emergencyExit.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function invariant_VaultBalanceAlwaysCoversAndClassifiesAllLiabilities() public view {
        uint256 balance = token.balanceOf(address(vault));
        uint256 liabilities = vault.totalReserved() + vault.totalClaimable();
        assertGe(balance, liabilities);
        if (vault.status() == SponsoredTaskTypes.VaultStatus.Active) {
            assertEq(balance, vault.available() + liabilities);
        } else {
            assertEq(balance, 0);
            assertEq(liabilities, 0);
        }
    }

    function invariant_CumulativeTokenAccountingConservesEveryFundedUnit() public view {
        assertEq(
            vault.totalFunded(),
            token.balanceOf(address(vault)) + vault.totalSponsoredTaskPaid() + vault.totalFeesPaid()
                + vault.totalWithdrawn()
        );
    }

    function invariant_ManagerAndAllocationBucketsRemainConserved() public view {
        if (vault.status() != SponsoredTaskTypes.VaultStatus.Active) {
            assertEq(vault.managerRemaining(address(handler)), 0);
            assertFalse(vault.managerAccount(address(handler)).active);
            return;
        }

        SponsoredTaskTypes.ManagerAccount memory account = vault.managerAccount(address(handler));
        assertEq(account.cap, account.reserved + account.spent + vault.managerRemaining(address(handler)));

        uint256 summedReserved;
        uint256 summedSpent;
        uint256 summedClaimable;
        uint256 count = handler.allocationCount();
        for (uint256 i; i < count; ++i) {
            SponsoredTaskTypes.Allocation memory item = _vaultAllocation(vault, handler.allocationIdAt(i));
            if (item.status == SponsoredTaskTypes.AllocationStatus.Reserved) {
                summedReserved += item.grossAmount;
            } else if (
                item.status == SponsoredTaskTypes.AllocationStatus.Claimable
                    || item.status == SponsoredTaskTypes.AllocationStatus.Settled
            ) {
                assertEq(item.grossAmount, item.distributedGross + item.releasedAmount);
                summedSpent += item.distributedGross;
                summedClaimable += item.sponsoredTaskOutstanding + item.feeOutstanding;
            } else if (item.status == SponsoredTaskTypes.AllocationStatus.Released) {
                assertEq(item.releasedAmount, item.grossAmount);
                assertEq(item.distributedGross, 0);
            }
        }

        assertEq(summedReserved, account.reserved);
        assertEq(summedReserved, vault.totalReserved());
        assertEq(summedSpent, account.spent);
        assertEq(summedClaimable, vault.totalClaimable());
    }
}
