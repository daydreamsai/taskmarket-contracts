// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { RemoteSponsoredTaskHook } from "../src/hooks/sponsored-task/RemoteSponsoredTaskHook.sol";
import { MockTaskmarketForSponsoredTask } from "./SponsoredTaskHook.t.sol";

/// @notice Replays the cross-chain funding vector the backend builds
///         (`docs/specs/sponsored-tasks/vectors/remote-funding-hookdata-v1.json`): for each task
///         chain (Base, Tempo) and vault family (EVM, Solana), the backend's hookData must fund the
///         task it describes on `RemoteSponsoredTaskHook`, with no `TaskTermsMismatch`.
contract RemoteSponsoredTaskHookFundingVectorTest is Test {
    string private constant VECTOR = "../docs/specs/sponsored-tasks/vectors/remote-funding-hookdata-v1.json";
    uint256 private constant REWARD = 1_000_000;

    function testTaskFundedFromRobinhoodVault() public {
        _replay("baseFromRobinhood");
    }

    function testTempoTaskFundedFromRobinhoodVault() public {
        _replay("tempoFromRobinhood");
    }

    function testTaskFundedFromSolanaVault() public {
        _replay("baseFromSolana");
    }

    function testTempoTaskFundedFromSolanaVault() public {
        _replay("tempoFromSolana");
    }

    function testAnotherTaskTermsHashIsRefused() public {
        (RemoteSponsoredTaskHook hook, MockTaskmarketForSponsoredTask market, bytes32 taskId, bytes memory hookData) =
            _setUpCase("baseFromRobinhood");
        market.setReward(taskId, REWARD + 1);
        vm.expectPartialRevert(RemoteSponsoredTaskHook.TaskTermsMismatch.selector);
        market.callCheckFund(hook, taskId, hookData);
    }

    function _replay(string memory name) private {
        (RemoteSponsoredTaskHook hook, MockTaskmarketForSponsoredTask market, bytes32 taskId, bytes memory hookData) =
            _setUpCase(name);
        assertTrue(market.callCheckFund(hook, taskId, hookData));

        string memory json = vm.readFile(VECTOR);
        string memory key = string.concat(".cases.", name);
        RemoteSponsoredTaskHook.Commitment memory c = hook.commitment(taskId);
        assertEq(c.remoteChainId, vm.parseJsonUint(json, string.concat(key, ".vaultChainId")));
        assertEq(c.vault, vm.parseJsonAddress(json, string.concat(key, ".vault")));
        assertEq(c.vaultId, vm.parseJsonBytes32(json, string.concat(key, ".vaultId")));
        assertEq(c.token, vm.parseJsonAddress(json, string.concat(key, ".token")));
        assertEq(c.commitmentNonce, vm.parseJsonUint(json, string.concat(key, ".commitmentNonce")));
        assertEq(c.manager, vm.parseJsonAddress(json, string.concat(key, ".manager")));
        assertEq(uint8(hook.outcome(taskId).status), uint8(RemoteSponsoredTaskHook.HookStatus.Committed));
    }

    /// @dev Primes the vector's task on the vector's task chain: a 72-hour bounty with one tag, the
    ///      750 bps platform fee, no evaluator and no content, with the hook at the vector's address.
    function _setUpCase(string memory name)
        private
        returns (
            RemoteSponsoredTaskHook hook,
            MockTaskmarketForSponsoredTask market,
            bytes32 taskId,
            bytes memory hookData
        )
    {
        string memory json = vm.readFile(VECTOR);
        string memory key = string.concat(".cases.", name);
        vm.chainId(vm.parseJsonUint(json, string.concat(key, ".taskChainId")));
        address hookAddress = vm.parseJsonAddress(json, string.concat(key, ".hookAddress"));
        address manager = vm.parseJsonAddress(json, string.concat(key, ".manager"));
        taskId = vm.parseJsonBytes32(json, string.concat(key, ".taskId"));
        hookData = vm.parseJsonBytes(json, string.concat(key, ".hookData"));

        market = new MockTaskmarketForSponsoredTask();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6, address(this));
        deployCodeTo("RemoteSponsoredTaskHook.sol:RemoteSponsoredTaskHook", abi.encode(address(market)), hookAddress);
        hook = RemoteSponsoredTaskHook(hookAddress);

        market.primeTask(taskId, manager, address(usdc), REWARD, TMP_BOUNTY, hookAddress);
        market.setContent(taskId, bytes32(0), "");
    }
}
