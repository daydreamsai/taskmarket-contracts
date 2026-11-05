// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { ProofGateHook } from "../src/hooks/proof-gate/ProofGateHook.sol";

/// @notice Deploys the shared proof gate hook. Opt-in per task; never a default hook, and not part
///         of any diamond revision or cut.
/// @dev Required env vars: FORGE_DEV_PRIVATE_KEY, FORGE_DIAMOND_ADDRESS. Refuses a diamond that does
///      not dispatch Task Hook V2 (diamondVersion below 28): the hook's callbacks would never run.
contract DeployProofGateHook is Script {
    function run() external returns (ProofGateHook gate) {
        uint256 deployerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = vm.envAddress("FORGE_DIAMOND_ADDRESS");
        (bool ok, bytes memory ret) = diamond.staticcall(abi.encodeWithSignature("diamondVersion()"));
        require(
            ok && ret.length == 32 && abi.decode(ret, (uint256)) >= 28,
            "Proof gate: diamond does not support Task Hook V2"
        );
        vm.startBroadcast(deployerKey);
        gate = new ProofGateHook(diamond);
        vm.stopBroadcast();
        require(gate.diamond() == diamond, "Proof gate: diamond mismatch");
        console.log("=== Proof gate hook deployment ===");
        console.log("ProofGateHook:", address(gate));
    }
}
