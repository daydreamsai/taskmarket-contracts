// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The revision this build corresponds to.
/// @dev READ THIS IF YOU ARE ADDING A REVISION.
///
///      `CURRENT_REVISION` is the number a freshly deployed diamond stamps into
///      `AppStorage.diamondVersion` at `initialize()` time. A fresh deploy routes the complete
///      steady-state selector set from `script/lib/FacetSelectors.sol`, which is to say it is
///      already at the destination every `script/upgrades/RevNNNUpgrade.s.sol` step is trying to
///      reach. Reporting anything lower would be a claim about the code that is not true, and
///      would send `script/upgrade.sh` off applying historical steps whose deltas the diamond has
///      already absorbed.
///
///      When you add `script/upgrades/RevNNNUpgrade.s.sol`, bump this to NNN in the same change.
///      `test/DiamondSelectorParity.t.sol` enumerates that directory and fails if the highest
///      step script there disagrees with this constant, so forgetting is caught by `forge test`
///      rather than by a deploy.
library LibRevision {
    uint256 internal constant CURRENT_REVISION = 21;
}
