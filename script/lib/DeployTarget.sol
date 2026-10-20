// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";

/// @title DeployTarget -- resolves the diamond an upgrade script acts on from the chain it runs on
/// @dev Every RevNNN upgrade script from rev022 on takes its diamond from here. The older scripts
///      picked theirs with `block.chainid == 8453 ? MAINNET : TESTNET`, which sends any chain that
///      is not Base mainnet to the Base Sepolia diamond -- on Tempo that would cut the wrong
///      network's diamond address (or none). An unknown chain reverts instead of falling through.
library DeployTarget {
    uint256 internal constant BASE_MAINNET = 8453;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant TEMPO_MAINNET = 4217;
    uint256 internal constant TEMPO_MODERATO = 42431;

    error UnknownDeployTarget(uint256 chainId);

    /// @notice The env var holding the diamond address for `chainId`.
    function diamondEnvVar(uint256 chainId) internal pure returns (string memory) {
        if (chainId == BASE_MAINNET) return "FORGE_DIAMOND_ADDRESS_MAINNET";
        if (chainId == BASE_SEPOLIA) return "FORGE_DIAMOND_ADDRESS_TESTNET";
        if (chainId == TEMPO_MAINNET) return "FORGE_DIAMOND_ADDRESS_TEMPO_MAINNET";
        if (chainId == TEMPO_MODERATO) return "FORGE_DIAMOND_ADDRESS_TEMPO_TESTNET";
        revert UnknownDeployTarget(chainId);
    }

    /// @notice The diamond address for the chain the script is running on.
    function diamondFor(Vm vm) internal view returns (address) {
        return vm.envAddress(diamondEnvVar(block.chainid));
    }
}
