// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { ITMPDiamond } from "../../src/interfaces/ITMPDiamond.sol";
import { DeployTarget } from "../lib/DeployTarget.sol";

/// @title Rev026Backfill -- book every live pre-rev026 task after Rev026Upgrade
/// @dev Not a RevNNNUpgrade step: it does not change diamondVersion and may be re-run, since
///      backfillLiabilities skips unknown, terminal and already-booked IDs. It never calls
///      completeLiabilities; the runbook does, after reconciling the printed surplus
///      against the escrow monitor.
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY      -- owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_*    -- as for the upgrade steps (see DeployTarget)
///      REV026_TASK_IDS_FILE       -- JSON file {"taskIds": ["0x...", ...]} of live task IDs
///                                    exported from the indexer
///      REV026_BATCH_SIZE          -- optional, default 200
contract Rev026Backfill is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        ITMPDiamond diamond = ITMPDiamond(DeployTarget.diamondFor(vm));
        require(!diamond.liabilitiesInitialised(), "Rev026Backfill: liabilities already initialised");

        bytes32[] memory ids = vm.parseJsonBytes32Array(vm.readFile(vm.envString("REV026_TASK_IDS_FILE")), ".taskIds");
        uint256 batchSize = vm.envOr("REV026_BATCH_SIZE", uint256(200));
        require(batchSize > 0, "Rev026Backfill: batch size must be positive");

        uint256 booked;
        vm.startBroadcast(ownerKey);
        for (uint256 start; start < ids.length; start += batchSize) {
            uint256 end = start + batchSize < ids.length ? start + batchSize : ids.length;
            bytes32[] memory batch = new bytes32[](end - start);
            for (uint256 i; i < batch.length; ++i) {
                batch[i] = ids[start + i];
            }
            booked += diamond.backfillLiabilities(batch);
        }
        vm.stopBroadcast();

        uint256 liabilities = diamond.totalLiabilities();
        address usdc = diamond.usdcToken();
        (, bytes memory ret) = usdc.staticcall(abi.encodeWithSignature("balanceOf(address)", address(diamond)));
        uint256 balance = abi.decode(ret, (uint256));
        console.log("Task IDs read:     ", ids.length);
        console.log("Tasks booked:      ", booked);
        console.log("totalLiabilities:  ", liabilities);
        console.log("Diamond balance:   ", balance);
        console.log("Surplus:           ", balance - liabilities);
        console.log("Reconcile the surplus against the escrow monitor, then call completeLiabilities.");
    }
}
