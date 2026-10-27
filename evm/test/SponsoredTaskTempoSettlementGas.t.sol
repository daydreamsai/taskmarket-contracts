// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPHook } from "../src/interfaces/ITMPHook.sol";
import { TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTaskFactory } from "../src/hooks/sponsored-task/SponsoredTaskFactory.sol";
import { SponsoredTaskFeeConfig } from "./helpers/SponsoredTaskFeeConfig.sol";
import { SponsoredTasksVault } from "../src/hooks/sponsored-task/SponsoredTasksVault.sol";
import { SponsoredTaskHook } from "../src/hooks/sponsored-task/SponsoredTaskHook.sol";
import { MockTaskmarketForSponsoredTask } from "./SponsoredTaskHook.t.sol";

/// Runs every Sponsored Task hook callback that ends a task at the stipend the Tempo diamond is
/// configured with, and requires each to finish inside it. A callback that ran out of gas would
/// be swallowed by the diamond and leave the allocation for reconcile/finalizeSettlement to
/// repair; on Tempo that must not be the normal path.
///
/// Forge executes with Ethereum gas pricing, which undercounts Tempo: there a new storage slot
/// costs about 250,000 gas instead of 20,000. Each path is therefore measured once with state-diff
/// recording, its zero-to-nonzero writes are surcharged at the Tempo difference, and the path is
/// then re-run from the same state with only the stipend minus that surcharge, so a pass means it
/// fits the Tempo stipend under Tempo's storage pricing.
contract SponsoredTaskTempoSettlementGasTest is Test {
    uint256 private constant TEMPO_HOOK_GAS_STIPEND = 7_000_000;
    uint256 private constant TEMPO_NEW_SLOT_SURCHARGE = 250_000 - 20_000;

    uint256 private constant NATIVE_REWARD = 8_000_000;
    uint256 private constant GROSS = 80_000;
    uint16 private constant TOKEN_FEE_BPS = 50;
    address private constant MANAGER = address(0xCAFE);

    MockTaskmarketForSponsoredTask private market;
    SponsoredTaskHook private hook;
    SponsoredTasksVault private vault;
    address private usdcAddress;

    function setUp() external {
        market = new MockTaskmarketForSponsoredTask();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6, address(this));
        usdcAddress = address(usdc);
        MockERC20 projectToken = new MockERC20("Project", "PROJECT", 18, address(this));
        SponsoredTaskFeePolicy feePolicy = new SponsoredTaskFeePolicy(address(this), TOKEN_FEE_BPS, address(0xFEE1));
        SponsoredTaskRegistry registry = new SponsoredTaskRegistry(address(this));
        hook = new SponsoredTaskHook(address(market), IERC20(address(usdc)), registry);

        SponsoredTaskFactory factory = new SponsoredTaskFactory(
            address(hook), address(feePolicy), registry, SponsoredTaskFeeConfig.none(IERC20(address(usdc)))
        );
        registry.setFactory(address(factory), true);
        (address vaultAddress,) = factory.createVault(address(projectToken), address(this), keccak256("tempo-gas"));
        vault = SponsoredTasksVault(vaultAddress);
        vault.configureManager(MANAGER, GROSS * 100, true);
        projectToken.mint(address(this), GROSS * 100);
        projectToken.approve(address(vault), type(uint256).max);
        vault.fund(GROSS * 100);

        usdc.mint(MANAGER, 100_000_000);
    }

    function testMaxAwardVerdictCommitsWithinTempoStipend() external {
        bytes32 taskId = _fundedTask("verdict");
        market.setStatus(taskId, ITMPCore.TaskStatus.Accepted);
        bytes memory call = abi.encodeCall(
            MockTaskmarketForSponsoredTask.callCheckComplete, (ITMPHook(address(hook)), taskId, _maxVerdict())
        );
        _assertFitsTempoStipend(call, taskId, SponsoredTaskHook.HookStatus.CompletionCommitted);
    }

    /// A dispute resolved after expiry, or any acceptance that skipped checkComplete, reaches the
    /// hook only through onComplete, which then does the whole commitment itself.
    function testDisputeResolvedWithMaxAwardsCommitsThroughOnCompleteWithinTempoStipend() external {
        bytes32 taskId = _fundedTask("dispute");
        market.setStatus(taskId, ITMPCore.TaskStatus.Accepted);
        bytes memory call = abi.encodeCall(
            MockTaskmarketForSponsoredTask.callOnComplete, (ITMPHook(address(hook)), taskId, _maxVerdict())
        );
        _assertFitsTempoStipend(call, taskId, SponsoredTaskHook.HookStatus.CompletionCommitted);
    }

    function testCancellationReleasesWithinTempoStipend() external {
        bytes32 taskId = _fundedTask("cancel");
        market.setStatus(taskId, ITMPCore.TaskStatus.Cancelled);
        bytes memory call =
            abi.encodeCall(MockTaskmarketForSponsoredTask.callOnCancel, (ITMPHook(address(hook)), taskId));
        _assertFitsTempoStipend(call, taskId, SponsoredTaskHook.HookStatus.Released);
    }

    function testExpiryReleasesWithinTempoStipend() external {
        bytes32 taskId = _fundedTask("expire");
        market.setStatus(taskId, ITMPCore.TaskStatus.Expired);
        bytes memory call =
            abi.encodeCall(MockTaskmarketForSponsoredTask.callOnExpire, (ITMPHook(address(hook)), taskId));
        _assertFitsTempoStipend(call, taskId, SponsoredTaskHook.HookStatus.Released);
    }

    function _assertFitsTempoStipend(bytes memory call, bytes32 taskId, SponsoredTaskHook.HookStatus expected) private {
        uint256 snapshot = vm.snapshotState();
        vm.startStateDiffRecording();
        (bool measured,) = address(market).call{ gas: TEMPO_HOOK_GAS_STIPEND }(call);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertTrue(measured, "path must succeed at the stipend under EVM pricing");
        assertEq(uint8(_status(taskId)), uint8(expected), "measurement run must reach the settled state");

        uint256 surcharge = _newSlots(accesses) * TEMPO_NEW_SLOT_SURCHARGE;
        assertLt(surcharge, TEMPO_HOOK_GAS_STIPEND, "new-slot surcharge alone exceeds the Tempo stipend");
        vm.revertToState(snapshot);

        // The diamond swallows a failed after-hook, so a failure here would surface only as the
        // allocation being left for repair; check the status, not just the call result.
        (bool ok,) = address(market).call{ gas: TEMPO_HOOK_GAS_STIPEND - surcharge }(call);
        assertTrue(ok, "path must complete within the Tempo stipend");
        assertEq(uint8(_status(taskId)), uint8(expected), "path must not be left for reconcile");
    }

    function _newSlots(Vm.AccountAccess[] memory accesses) private pure returns (uint256 count) {
        for (uint256 i; i < accesses.length; ++i) {
            Vm.StorageAccess[] memory slots = accesses[i].storageAccesses;
            for (uint256 j; j < slots.length; ++j) {
                if (
                    slots[j].isWrite && !slots[j].reverted && slots[j].previousValue == bytes32(0)
                        && slots[j].newValue != bytes32(0) && !_seen(slots, j)
                ) ++count;
            }
        }
    }

    function _seen(Vm.StorageAccess[] memory slots, uint256 index) private pure returns (bool) {
        for (uint256 k; k < index; ++k) {
            if (slots[k].isWrite && slots[k].slot == slots[index].slot && slots[k].account == slots[index].account) {
                return true;
            }
        }
        return false;
    }

    function _status(bytes32 taskId) private view returns (SponsoredTaskHook.HookStatus status) {
        (,,,,,,,, status) = hook.taskAllocationSettlement(taskId);
    }

    function _fundedTask(string memory salt) private returns (bytes32 taskId) {
        taskId = keccak256(bytes(salt));
        market.primeTask(taskId, MANAGER, usdcAddress, NATIVE_REWARD, TMP_BOUNTY, address(hook));
        SponsoredTaskHook.FundingRequest memory request = SponsoredTaskHook.FundingRequest({
            route: hook.ROUTE_BASE_LOCAL(),
            vault: address(vault),
            vaultId: vault.vaultId(),
            allocationId: bytes32(0),
            epoch: 1,
            feeBps: TOKEN_FEE_BPS,
            feeRecipient: address(0xFEE1),
            grossAmount: GROSS,
            taskTermsHash: hook.currentTaskTermsHash(taskId)
        });
        market.callCheckFund(hook, taskId, hook.encodeHookData(request));
    }

    function _maxVerdict() private view returns (ITMPCore.Verdict memory) {
        uint256 count = hook.MAX_AWARDS();
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](count);
        for (uint256 i; i < count; ++i) {
            awards[i] = ITMPCore.Award({
                worker: address(uint160(0x1000 + i)), amount: NATIVE_REWARD / count, rank: uint16(i + 1)
            });
        }
        return ITMPCore.Verdict({
            issued: true,
            verdictType: ITMPCore.VerdictType.APPROVE,
            score: 1_000,
            confidence: 1_000,
            criteriaFlags: new bytes32[](0),
            evidenceHash: bytes32(0),
            awards: awards
        });
    }
}
