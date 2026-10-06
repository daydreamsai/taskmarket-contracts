// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Deploys a `TimelockController` in front of a Safe, for use as
///         `FORGE_SPONSORED_TASK_FEE_BANK_GUARD_ADMIN` -- so a fee change the Safe proposes only
///         takes effect after a public minimum delay, rather than the instant a threshold of
///         signers approves it.
/// @dev The Safe is the timelock's proposer, executor, and canceller; the deployer never holds
///      a standing role once `TIMELOCK_ADMIN` is left unset (this contract's own `admin` param
///      falls back to `address(0)`, so DEFAULT_ADMIN_ROLE is only ever self-held by the timelock
///      itself -- membership changes must go through the timelock's own delayed process, not a
///      privileged external admin). Pass `TIMELOCK_ADMIN` explicitly only if you deliberately want
///      the Safe to be able to add/remove proposers without a delay.
contract DeploySponsoredTaskGuardTimelock is Script {
    /// @dev Env inputs:
    ///      TIMELOCK_DEPLOYER_KEY -- private key broadcasting this deployment.
    ///      TIMELOCK_SAFE         -- the Safe address that will propose/execute/cancel.
    ///      TIMELOCK_MIN_DELAY    -- seconds between a proposal and its earliest execution.
    ///      TIMELOCK_ADMIN        -- optional; see contract-level note. Defaults to address(0).
    function run() external returns (address timelock) {
        uint256 deployerKey = vm.envUint("TIMELOCK_DEPLOYER_KEY");
        address safe = vm.envAddress("TIMELOCK_SAFE");
        uint256 minDelay = vm.envUint("TIMELOCK_MIN_DELAY");
        address admin = vm.envOr("TIMELOCK_ADMIN", address(0));

        require(safe.code.length != 0, "DeployGuardTimelock: TIMELOCK_SAFE must be a contract");
        require(minDelay > 0, "DeployGuardTimelock: TIMELOCK_MIN_DELAY must be > 0");

        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = safe;

        vm.startBroadcast(deployerKey);
        TimelockController controller = new TimelockController(minDelay, proposers, executors, admin);
        vm.stopBroadcast();

        timelock = address(controller);
        require(timelock.code.length != 0, "DeployGuardTimelock: no code at deployed address");
        require(controller.getMinDelay() == minDelay, "DeployGuardTimelock: minDelay mismatch");

        console2.log("TimelockController deployed", timelock);
        console2.log("Proposer/executor (Safe)", safe);
        console2.log("Min delay (seconds)", minDelay);
    }
}
