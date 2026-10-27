// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { SponsoredTaskTypes } from "../src/hooks/sponsored-task/SponsoredTaskTypes.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTaskFactory } from "../src/hooks/sponsored-task/SponsoredTaskFactory.sol";
import { SponsoredTaskFeeConfig } from "./helpers/SponsoredTaskFeeConfig.sol";
import { SponsoredTasksVault } from "../src/hooks/sponsored-task/SponsoredTasksVault.sol";
import { SponsoredTaskHook } from "../src/hooks/sponsored-task/SponsoredTaskHook.sol";
import { MockTaskmarketForSponsoredTask } from "./SponsoredTaskHook.t.sol";

/// @notice Explicit MW-5/MW-6 acceptance fixtures kept separate from the broad hook unit suite.
contract SponsoredTaskMultiwinnerAcceptanceTest is Test {
    // allocationSettlement returns a tuple, not the Allocation struct -- the whole-struct
    // external getter tripped forge coverage --ir-minimum's stack-too-deep limit on its own ABI
    // encoding (see SponsoredTasksVault.allocationSettlement's own doc comment).
    function _allocationStatus(SponsoredTasksVault v, bytes32 allocationId)
        private
        view
        returns (SponsoredTaskTypes.AllocationStatus status)
    {
        (,,,,,,, status) = v.allocationSettlement(allocationId);
    }

    bytes32 private constant LOCAL_TASK = keccak256("multiwinner-local");

    uint256 private constant WORKER_ONE_PK = 0xA11CE;
    uint256 private constant WORKER_TWO_PK = 0xB0B;
    uint256 private constant WORKER_THREE_PK = 0xCAFE;
    uint256 private constant NATIVE_REWARD = 1_000_000;
    uint256 private constant GROSS = 100_000;
    uint16 private constant FEE_BPS = 50;

    address private constant MANAGER = address(0xB011D);
    address private constant FEE_RECIPIENT = address(0xFEE1);
    address private constant CREATION_FEE_RECIPIENT = address(0xFEE2);
    address private constant DESTINATION_ONE = address(0xD001);
    address private constant DESTINATION_TWO = address(0xD002);
    address private constant DESTINATION_THREE = address(0xD003);

    MockTaskmarketForSponsoredTask private market;
    MockERC20 private usdc;
    MockERC20 private projectToken;
    SponsoredTaskFeePolicy private feePolicy;
    SponsoredTaskRegistry private registry;
    SponsoredTaskHook private hook;
    SponsoredTasksVault private vault;

    address private workerOne;
    address private workerTwo;
    address private workerThree;

    function setUp() external {
        workerOne = vm.addr(WORKER_ONE_PK);
        workerTwo = vm.addr(WORKER_TWO_PK);
        workerThree = vm.addr(WORKER_THREE_PK);

        market = new MockTaskmarketForSponsoredTask();
        usdc = new MockERC20("USD Coin", "USDC", 6, address(this));
        projectToken = new MockERC20("Project", "PROJECT", 18, address(this));
        feePolicy = new SponsoredTaskFeePolicy(address(this), FEE_BPS, FEE_RECIPIENT);
        registry = new SponsoredTaskRegistry(address(this));
        hook = new SponsoredTaskHook(address(market), IERC20(address(usdc)), registry);

        SponsoredTaskFactory factory = new SponsoredTaskFactory(
            address(hook), address(feePolicy), registry, SponsoredTaskFeeConfig.none(IERC20(address(usdc)))
        );
        registry.setFactory(address(factory), true);
        (address vaultAddress,) =
            factory.createVault(address(projectToken), address(this), keccak256("multiwinner-vault"));
        vault = SponsoredTasksVault(vaultAddress);
        vault.configureManager(MANAGER, 10 * GROSS, true);

        projectToken.mint(address(this), 10 * GROSS);
        projectToken.approve(address(vault), type(uint256).max);
        vault.fund(10 * GROSS);

        usdc.mint(MANAGER, 10_000_000);

        market.primeTask(LOCAL_TASK, MANAGER, address(usdc), NATIVE_REWARD, TMP_BOUNTY, address(hook));
    }

    function testThreeWorkersClaimIndependentlyToDistinctDestinationsInReverseOrder() external {
        _fundLocal();
        ITMPCore.Award[] memory awards = _threeAwards();
        _commitAndFinalize(LOCAL_TASK, awards);

        uint256[3] memory net = [uint256(49_750), uint256(29_850), uint256(19_900)];
        bytes32[3] memory leaves;
        leaves[0] = vault.claimLeaf(LOCAL_TASK, LOCAL_TASK, 1, 0, workerOne, net[0]);
        leaves[1] = vault.claimLeaf(LOCAL_TASK, LOCAL_TASK, 1, 1, workerTwo, net[1]);
        leaves[2] = vault.claimLeaf(LOCAL_TASK, LOCAL_TASK, 1, 2, workerThree, net[2]);

        bytes32[] memory proofOne = _proofForThree(leaves[0], leaves);
        bytes32[] memory proofTwo = _proofForThree(leaves[1], leaves);
        bytes32[] memory proofThree = _proofForThree(leaves[2], leaves);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signatureOne = _claimSignature(WORKER_ONE_PK, 0, workerOne, DESTINATION_ONE, net[0], 0, deadline);

        // The signed worker, index, and destination are independent authorization boundaries.
        vm.expectRevert(SponsoredTasksVault.InvalidClaimSignature.selector);
        vault.claimTo(LOCAL_TASK, 0, workerTwo, DESTINATION_ONE, net[0], 0, deadline, signatureOne, proofOne);

        vm.expectRevert(SponsoredTasksVault.InvalidClaimSignature.selector);
        vault.claimTo(LOCAL_TASK, 1, workerOne, DESTINATION_ONE, net[0], 0, deadline, signatureOne, proofOne);

        vm.expectRevert(SponsoredTasksVault.InvalidClaimSignature.selector);
        vault.claimTo(LOCAL_TASK, 0, workerOne, MANAGER, net[0], 0, deadline, signatureOne, proofOne);

        // A worker cannot consume another worker's award index through the direct claim path.
        vm.expectRevert(SponsoredTasksVault.InvalidClaimProof.selector);
        vm.prank(workerOne);
        vault.claim(LOCAL_TASK, 1, net[1], proofTwo);

        // Claims are intentionally relayed in reverse/non-sequential order and pay distinct wallets.
        bytes memory signatureThree =
            _claimSignature(WORKER_THREE_PK, 2, workerThree, DESTINATION_THREE, net[2], 0, deadline);
        vault.claimTo(LOCAL_TASK, 2, workerThree, DESTINATION_THREE, net[2], 0, deadline, signatureThree, proofThree);
        vault.claimTo(LOCAL_TASK, 0, workerOne, DESTINATION_ONE, net[0], 0, deadline, signatureOne, proofOne);
        bytes memory signatureTwo = _claimSignature(WORKER_TWO_PK, 1, workerTwo, DESTINATION_TWO, net[1], 0, deadline);
        vault.claimTo(LOCAL_TASK, 1, workerTwo, DESTINATION_TWO, net[1], 0, deadline, signatureTwo, proofTwo);

        assertEq(projectToken.balanceOf(DESTINATION_ONE), net[0]);
        assertEq(projectToken.balanceOf(DESTINATION_TWO), net[1]);
        assertEq(projectToken.balanceOf(DESTINATION_THREE), net[2]);
        assertEq(projectToken.balanceOf(MANAGER), 0);
        assertEq(vault.totalSponsoredTaskPaid(), net[0] + net[1] + net[2]);

        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.InvalidClaimNonce.selector, workerOne, 1, 0));
        vault.claimTo(LOCAL_TASK, 0, workerOne, DESTINATION_ONE, net[0], 0, deadline, signatureOne, proofOne);

        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.ClaimAlreadyPaid.selector, LOCAL_TASK, 2));
        vm.prank(workerThree);
        vault.claim(LOCAL_TASK, 2, net[2], proofThree);

        vm.prank(FEE_RECIPIENT);
        vault.claimFee(LOCAL_TASK, FEE_RECIPIENT);
        assertEq(projectToken.balanceOf(FEE_RECIPIENT), 500);
        assertEq(vault.totalClaimable(), 0);
        assertEq(uint8(_allocationStatus(vault, LOCAL_TASK)), uint8(SponsoredTaskTypes.AllocationStatus.Settled));
    }

    function _fundLocal() private {
        bytes32 termsHash = hook.currentTaskTermsHash(LOCAL_TASK);
        SponsoredTaskHook.FundingRequest memory request = SponsoredTaskHook.FundingRequest({
            route: hook.ROUTE_BASE_LOCAL(),
            vault: address(vault),
            vaultId: vault.vaultId(),
            allocationId: bytes32(0),
            epoch: vault.epoch(),
            feeBps: FEE_BPS,
            feeRecipient: FEE_RECIPIENT,
            grossAmount: GROSS,
            taskTermsHash: termsHash
        });
        market.callCheckFund(hook, LOCAL_TASK, hook.encodeHookData(request));
    }

    function _commitAndFinalize(bytes32 taskId, ITMPCore.Award[] memory awards) private {
        market.setStatus(taskId, ITMPCore.TaskStatus.Accepted);
        ITMPCore.Verdict memory verdict = ITMPCore.Verdict({
            issued: true,
            verdictType: ITMPCore.VerdictType.APPROVE,
            score: 10_000,
            confidence: 10_000,
            criteriaFlags: new bytes32[](0),
            evidenceHash: keccak256("three-winner-evidence"),
            awards: awards
        });
        market.callCheckComplete(hook, taskId, verdict);
        hook.finalizeSettlement(taskId, awards);
    }

    function _threeAwards() private view returns (ITMPCore.Award[] memory awards) {
        awards = new ITMPCore.Award[](3);
        awards[0] = ITMPCore.Award({ worker: workerOne, amount: 500_000, rank: 1 });
        awards[1] = ITMPCore.Award({ worker: workerTwo, amount: 300_000, rank: 2 });
        awards[2] = ITMPCore.Award({ worker: workerThree, amount: 200_000, rank: 3 });
    }

    function _claimSignature(
        uint256 privateKey,
        uint256 index,
        address worker,
        address destination,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) private view returns (bytes memory signature) {
        bytes32 digest = vault.claimDigest(LOCAL_TASK, index, worker, destination, amount, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _proofForThree(bytes32 target, bytes32[3] memory leaves) private pure returns (bytes32[] memory proof) {
        bytes32 first = leaves[0];
        bytes32 second = leaves[1];
        bytes32 third = leaves[2];
        if (first > second) (first, second) = (second, first);
        if (second > third) (second, third) = (third, second);
        if (first > second) (first, second) = (second, first);

        if (target == third) {
            proof = new bytes32[](1);
            proof[0] = _hashPair(first, second);
        } else {
            proof = new bytes32[](2);
            proof[0] = target == first ? second : first;
            proof[1] = third;
        }
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
