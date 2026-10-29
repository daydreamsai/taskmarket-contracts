// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { FundingPool } from "../../src/FundingPool.sol";

/// @title DeployFundingPool
/// @notice Deploys the funding pool implementation and an ERC-1967 proxy that initialises it in
///         its constructor, so deploy and initialise are one transaction and nobody can
///         initialise the proxy first with a different manager.
/// @dev Shared by DiamondDeploy and Rev027Upgrade so both paths deploy the pool identically.
///      Order for a caller: deploy (the diamond must already exist, it is the manager), cut the
///      facets, then `ITMPProject.initFundingPool(proxy)` on the diamond.
library DeployFundingPool {
    /// @param diamond The pool's manager, fixed at initialisation.
    /// @param token The diamond's payment token; the initialiser reverts on a mismatch.
    /// @return implementation The logic contract.
    /// @return proxy The address the diamond and every backer must use, never the implementation.
    function deploy(address diamond, address token) internal returns (address implementation, address proxy) {
        implementation = address(new FundingPool());
        proxy = address(new ERC1967Proxy(implementation, abi.encodeCall(FundingPool.initialize, (diamond, token))));
    }
}
