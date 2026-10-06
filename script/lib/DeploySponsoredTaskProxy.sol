// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SponsoredTaskHook } from "../../src/hooks/sponsored-task/SponsoredTaskHook.sol";
import { ISponsoredTaskFeeBank } from "../../src/hooks/sponsored-task/interfaces/ISponsoredTaskFeeBank.sol";
import { ISponsoredTaskRegistry } from "../../src/hooks/sponsored-task/interfaces/ISponsoredTaskRegistry.sol";

/// @title DeploySponsoredTaskProxy
/// @notice Deploys a `SponsoredTaskHook` behind an ERC-1967 proxy and initializes it.
/// @dev Mirrors `DeployRewardHookProxy`: the pairing of "deploy implementation" and "initialize
///      through the proxy" must not come apart, or an implementation deployed but not initialized
///      behind its proxy has no owner. The hook's own constructor disables initializers on the
///      implementation for the same reason.
library DeploySponsoredTaskProxy {
    /// @return The proxy address. Every other Sponsored Task contract must reference this
    ///         address, never the implementation, or it would be talking to an uninitialized hook.
    function deploy(
        address taskmarket,
        IERC20 usdc,
        ISponsoredTaskFeeBank feeBank,
        ISponsoredTaskRegistry registry,
        address owner
    ) internal returns (SponsoredTaskHook) {
        address implementation = address(new SponsoredTaskHook(taskmarket, usdc, feeBank, registry));
        bytes memory initData = abi.encodeCall(SponsoredTaskHook.initialize, (owner));
        return SponsoredTaskHook(address(new ERC1967Proxy(implementation, initData)));
    }
}
