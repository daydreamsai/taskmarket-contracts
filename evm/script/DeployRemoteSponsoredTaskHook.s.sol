// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RemoteSponsoredTaskHook } from "../src/hooks/sponsored-task/RemoteSponsoredTaskHook.sol";
import { SponsoredTaskFeeBank } from "../src/hooks/sponsored-task/SponsoredTaskFeeBank.sol";
import { SponsoredTaskFeeBankGuard } from "../src/hooks/sponsored-task/SponsoredTaskFeeBankGuard.sol";
import { ISponsoredTaskFeeBank } from "../src/hooks/sponsored-task/interfaces/ISponsoredTaskFeeBank.sol";

interface ISponsoredTaskHookFeeBank {
    function feeBank() external view returns (ISponsoredTaskFeeBank);
}

/// @notice Deploys the Base half of settler mode, `RemoteSponsoredTaskHook`, behind an ERC-1967
///         proxy, with its own fee bank and fee bank guard. See
///         `docs/specs/sponsored-tasks/evm-attested-settler.md`.
/// @dev Required env vars:
///
///   FORGE_DEV_PRIVATE_KEY                   -- deployer key; owns nothing once this script ends
///   FORGE_DIAMOND_ADDRESS                   -- TaskMarket Diamond proxy on Base
///   FORGE_SPONSORED_TASK_HOOK_ADDRESS       -- the deployed Base `SponsoredTaskHook` proxy; the
///                                              new fee bank copies its fee bank's token, fee
///                                              amount and fee recipient, so a remote task costs
///                                              the same creation fee as a hook-mode task
///   FORGE_SPONSORED_TASK_FEE_CEILING_USDC   -- the guard's immutable ceiling on future fee changes
///   FORGE_SPONSORED_TASK_REMOTE_HOOK_ADMIN  -- a deployed contract (Safe or timelock) that owns the
///                                              proxy, may upgrade it, and administers the guard
///
/// The Base hook's fee bank cannot take a second charger: its guard can only revoke chargers. So
/// the remote hook charges a fee bank of its own, held by its own guard, and managers deposit
/// fee credit there for remote tasks.
///
/// The hook is opt-in, never a Diamond default hook; a vault manager attaches it per task.
contract DeployRemoteSponsoredTaskHook is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address diamond = vm.envAddress("FORGE_DIAMOND_ADDRESS");
        address admin = vm.envAddress("FORGE_SPONSORED_TASK_REMOTE_HOOK_ADMIN");
        require(admin.code.length != 0, "Remote hook: admin must be a contract");
        require(admin != deployer, "Remote hook: admin must not be the deployer");

        ISponsoredTaskFeeBank baseBank =
            ISponsoredTaskHookFeeBank(vm.envAddress("FORGE_SPONSORED_TASK_HOOK_ADDRESS")).feeBank();
        uint256 feeAmount = baseBank.feeAmount();
        address feeRecipient = baseBank.feeRecipient();

        vm.startBroadcast(deployerKey);
        SponsoredTaskFeeBank feeBank = new SponsoredTaskFeeBank(deployer, baseBank.feeToken(), feeAmount, feeRecipient);
        address implementation = address(new RemoteSponsoredTaskHook(diamond, feeBank));
        RemoteSponsoredTaskHook hook = RemoteSponsoredTaskHook(
            address(new ERC1967Proxy(implementation, abi.encodeCall(RemoteSponsoredTaskHook.initialize, (admin))))
        );
        feeBank.setCharger(address(hook), true);
        SponsoredTaskFeeBankGuard guard = new SponsoredTaskFeeBankGuard(
            admin, feeBank, address(hook), vm.envUint("FORGE_SPONSORED_TASK_FEE_CEILING_USDC")
        );
        feeBank.transferOwnership(address(guard));
        guard.acceptFeeBankOwnership();
        vm.stopBroadcast();

        require(hook.owner() == admin, "Remote hook: owner is not the admin");
        require(hook.diamond() == diamond, "Remote hook: diamond mismatch");
        require(address(hook.feeBank()) == address(feeBank), "Remote hook: fee bank mismatch");
        require(feeBank.owner() == address(guard), "Remote hook: guard did not take the fee bank");
        require(feeBank.feeAmount() == feeAmount, "Remote hook: fee differs from the Base hook");

        console.log("=== Remote Sponsored Task hook deployment ===");
        console.log("RemoteSponsoredTaskHook (proxy):", address(hook));
        console.log("Implementation:                 ", implementation);
        console.log("SponsoredTaskFeeBank (remote):  ", address(feeBank));
        console.log("SponsoredTaskFeeBankGuard:      ", address(guard));
        console.log("Owner (admin):                  ", admin);
        console.log("Hook is opt-in only -- not registered as a Diamond default hook");
    }
}
