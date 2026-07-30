// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";

/// @title Rev014Upgrade — replace CoreFacet to add stakeRequired/stakeBps to createTask
/// @dev createTask's signature changed (a new StakeConfig calldata struct param inserted before
///      the hookConfig/content structs), so its selector changed too -- this is a Remove(old) +
///      Replace(unchanged) + Add(new) on CoreFacet, not a pure Replace like rev013.
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          — owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_TESTNET  — Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_MAINNET  — Diamond proxy on Base Mainnet (chain 8453)
///
/// @dev Usage (normally applied automatically by `make upgrade <testnet|mainnet>` as part of the
///      pending-steps sequence; direct single-step invocation):
///      make upgrade testnet rev014
///      make upgrade mainnet rev014
contract Rev014Upgrade is Script {
    uint256 private constant EXPECTED_PRE_VERSION = 13;
    uint256 private constant TARGET_VERSION = 14;

    // Pre-rev014 createTask selector: createTask(uint256,uint256,bytes4,uint256,uint256,bytes4,
    // (address[],bytes),(bytes32,string,bytes32[])) -- no stakeRequired/stakeBps params. Rev013
    // (the CoreFacet/EvaluatorFacet security-fix bundle) did not change createTask, so this
    // selector is still the one live on any diamond at rev013.
    bytes4 private constant OLD_CREATE_TASK = 0x6025c050;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = block.chainid == 8453
            ? vm.envAddress("FORGE_DIAMOND_ADDRESS_MAINNET")
            : vm.envAddress("FORGE_DIAMOND_ADDRESS_TESTNET");

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(currentVersion == EXPECTED_PRE_VERSION, "Rev014Upgrade: diamond is not at rev013");

        vm.startBroadcast(ownerKey);

        address coreFacet = address(new CoreFacet());

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);

        bytes4[] memory oldCreateTask = new bytes4[](1);
        oldCreateTask[0] = OLD_CREATE_TASK;
        cuts[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, oldCreateTask);

        cuts[1] = IDiamondCut.FacetCut(coreFacet, IDiamondCut.FacetCutAction.Replace, _coreUnchangedSelectors());

        bytes4[] memory newCreateTask = new bytes4[](1);
        newCreateTask[0] = CoreFacet.createTask.selector;
        cuts[2] = IDiamondCut.FacetCut(coreFacet, IDiamondCut.FacetCutAction.Add, newCreateTask);

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);

        vm.stopBroadcast();

        console.log("Rev014 upgrade complete. Diamond:", diamond);
        console.log("CoreFacet:      ", coreFacet);
        console.log("diamondVersion: ", TARGET_VERSION);
    }

    /// @dev The 20 CoreFacet selectors whose signature is unaffected by rev014 (everything in
    ///      FacetSelectors.coreFacetSelectors() except createTask, which changed).
    function _coreUnchangedSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](20);
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
        s[10] = CoreFacet.claimTask.selector;
        s[11] = CoreFacet.selectWorker.selector;
        s[12] = CoreFacet.submitPitch.selector;
        s[13] = CoreFacet.submitProof.selector;
        s[14] = CoreFacet.submitWork.selector;
        s[15] = CoreFacet.forfeitAndReopen.selector;
        s[16] = CoreFacet.cancelTask.selector;
        s[17] = CoreFacet.updateTask.selector;
        s[18] = CoreFacet.refundExpired.selector;
        s[19] = CoreFacet.rejectSubmission.selector;
    }
}
