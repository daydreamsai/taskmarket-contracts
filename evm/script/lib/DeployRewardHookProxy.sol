// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TaskTokenRewardHook } from "../../src/hooks/TaskTokenRewardHook.sol";

/// @title DeployRewardHookProxy
/// @notice Deploys a `TaskTokenRewardHook` behind an ERC-1967 proxy and initializes it.
/// @dev One helper rather than the same lines in every deploy script and test. The pairing of
///      "deploy implementation" and "initialize through the proxy" is what must not come apart:
///      an implementation deployed but not initialized behind its proxy has no owner. The hook's
///      own constructor disables initializers on the implementation for the same reason, so the
///      gap cannot be claimed by anyone else either.
///
///      The parameter list mirrors the pre-proxy constructor exactly, so call sites read the same
///      as they did and a reviewer can see that nothing about the configuration changed -- only
///      where it is stored.
library DeployRewardHookProxy {
    /// @return The proxy address. Everything else -- vault, budget, Diamond -- must use this,
    ///         never the implementation, or it would be talking to an uninitialized contract.
    function deploy(
        address vault,
        address epochBudget,
        address diamond,
        uint8 tokenDecimals,
        uint256 dreamsPerUsdc,
        uint16 bonusBps,
        address token,
        uint16 workerSplitBps,
        address authorizedRelayer,
        address owner
    ) internal returns (TaskTokenRewardHook) {
        address implementation = address(new TaskTokenRewardHook());

        bytes memory initData = abi.encodeCall(
            TaskTokenRewardHook.initialize,
            (
                vault,
                epochBudget,
                diamond,
                tokenDecimals,
                dreamsPerUsdc,
                bonusBps,
                token,
                workerSplitBps,
                authorizedRelayer,
                owner
            )
        );

        return TaskTokenRewardHook(address(new ERC1967Proxy(implementation, initData)));
    }
}
