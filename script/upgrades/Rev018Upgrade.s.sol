// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { EvaluatorFacet } from "../../src/facets/EvaluatorFacet.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev018Upgrade — createTask takes evaluator configuration, so assignment is atomic
/// @dev Before this revision, a task with an evaluator needed two transactions: `createTask`,
///      then `assignEvaluator`. The task is Open -- and therefore claimable -- from the moment
///      `createTask` mines, and `assignEvaluator` reverts `TaskNotOpen` once a worker has
///      claimed, so the second call raced every worker agent watching for new tasks and could
///      lose. `createTask` now takes an `ITMPCore.TaskEvaluatorConfig` and applies it in the
///      same transaction, which removes the window rather than narrowing it.
///
/// @dev Two facets change:
///
///      CoreFacet — `createTask`'s signature changed (evaluator terms added, and the task-shape
///        scalars grouped into ITMPCore.TaskConfig), so there is a new selector
///        (CoreFacet.createTask.selector). The pre-rev018 nine-parameter selector
///        (FacetSelectors.LEGACY_CREATE_TASK) is NOT removed: it stays routed to the same newly
///        deployed CoreFacet, where a deprecated overload forwards it to the shared body with an
///        empty evaluator configuration. So this is Replace(existing, including the legacy
///        selector) + Add(new selector), with no Remove at all.
///
///      EvaluatorFacet — `assignEvaluator`'s signature is unchanged, but its body now delegates
///        the shared validation, storage writes, stake pull and event to
///        LibTaskMarket._applyEvaluatorConfig so the two entry points cannot drift. That is a
///        bytecode change with no selector change, so it is a pure Replace.
///
/// @dev Expand now, contract later. Removing the old selector in this same cut would make every
///      task creation revert -- not degrade, revert -- for the entire window between this cut
///      landing and every off-chain caller being redeployed against the new signature, and would
///      leave creation down indefinitely if that redeploy failed, recoverable only by rolling the
///      diamond back. Keeping both routed decouples the two deploys: this cut is safe to apply
///      before any caller changes, callers switch to the evaluator-aware selector on their own
///      schedule, and rev019 removes the legacy selector and its shim once nothing encodes the
///      old signature any more. The cost is one dead code path and roughly a hundred bytes of
///      facet bytecode for one revision.
///
/// @dev Ordering: this step assumes rev016 (escrow liability) and rev017 (evaluator award
///      recipients, self-assignment guards, minimum appeal window) have already been applied,
///      hence the rev017 precondition. Rev017's guards on the evaluator terms live in the shared
///      LibTaskMarket._applyEvaluatorConfig body that both entry points call, so the creation
///      path introduced here inherits them rather than sidestepping them.
///
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          — owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_TESTNET  — Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_MAINNET  — Diamond proxy on Base Mainnet (chain 8453)
///
/// @dev Usage (normally applied automatically by `make upgrade <testnet|mainnet>` as part of the
///      pending-steps sequence; direct single-step invocation):
///      make upgrade testnet rev018
///      make upgrade mainnet rev018
contract Rev018Upgrade is Script {
    uint256 private constant EXPECTED_PRE_VERSION = 17;
    uint256 private constant TARGET_VERSION = 18;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = block.chainid == 8453
            ? vm.envAddress("FORGE_DIAMOND_ADDRESS_MAINNET")
            : vm.envAddress("FORGE_DIAMOND_ADDRESS_TESTNET");

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(currentVersion == EXPECTED_PRE_VERSION, "Rev018Upgrade: diamond is not at rev017");

        vm.startBroadcast(ownerKey);

        address coreFacet = address(new CoreFacet());
        address evalFacet = address(new EvaluatorFacet());

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);

        cuts[0] = IDiamondCut.FacetCut(coreFacet, IDiamondCut.FacetCutAction.Replace, _corePreRev018Selectors());

        bytes4[] memory newCreateTask = new bytes4[](1);
        newCreateTask[0] = CoreFacet.createTask.selector;
        cuts[1] = IDiamondCut.FacetCut(coreFacet, IDiamondCut.FacetCutAction.Add, newCreateTask);

        cuts[2] =
            IDiamondCut.FacetCut(evalFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.evalFacetSelectors());

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);

        vm.stopBroadcast();

        console.log("Rev018 upgrade complete. Diamond:", diamond);
        console.log("CoreFacet:      ", coreFacet);
        console.log("EvaluatorFacet: ", evalFacet);
        console.log("diamondVersion: ", TARGET_VERSION);
    }

    /// @dev The 21 CoreFacet selectors a diamond at rev017 already routes -- everything in
    ///      FacetSelectors.coreFacetSelectors() except rev018's new createTask overload, which is
    ///      Added separately above because Replace requires the selector to already exist. The
    ///      legacy createTask selector is in this list, not in a Remove cut: it keeps routing,
    ///      now to the deprecated shim on the new CoreFacet.
    function _corePreRev018Selectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](21);
        s[0] = bytes4(keccak256("BOUNTY()"));
        s[1] = bytes4(keccak256("CLAIM()"));
        s[2] = bytes4(keccak256("PITCH()"));
        s[3] = bytes4(keccak256("BENCHMARK()"));
        s[4] = bytes4(keccak256("AUCTION()"));
        s[5] = bytes4(keccak256("AUCTION_DUTCH()"));
        s[6] = bytes4(keccak256("AUCTION_ENGLISH()"));
        s[7] = bytes4(keccak256("AUCTION_REVERSE_DUTCH()"));
        s[8] = bytes4(keccak256("AUCTION_REVERSE_ENGLISH()"));
        s[9] = bytes4(keccak256("MAX_BIDS_PER_TASK()"));
        s[10] = FacetSelectors.LEGACY_CREATE_TASK;
        s[11] = CoreFacet.claimTask.selector;
        s[12] = CoreFacet.selectWorker.selector;
        s[13] = CoreFacet.submitPitch.selector;
        s[14] = CoreFacet.submitProof.selector;
        s[15] = CoreFacet.submitWork.selector;
        s[16] = CoreFacet.forfeitAndReopen.selector;
        s[17] = CoreFacet.cancelTask.selector;
        s[18] = CoreFacet.updateTask.selector;
        s[19] = CoreFacet.refundExpired.selector;
        s[20] = CoreFacet.rejectSubmission.selector;
    }
}
