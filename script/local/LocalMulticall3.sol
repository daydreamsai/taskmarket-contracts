// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Multicall3-compatible contract for a local anvil only. scripts/local-multicall3.sh
/// places its runtime code at the canonical Multicall3 address with anvil_setCode so viem's
/// multicall works against a fresh local stack. It is never deployed to a real network.
contract LocalMulticall3 {
    struct Call3 {
        address target;
        bool allowFailure;
        bytes callData;
    }

    struct Result {
        bool success;
        bytes returnData;
    }

    function aggregate3(Call3[] calldata calls) external payable returns (Result[] memory returnData) {
        returnData = new Result[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].target.call(calls[i].callData);
            require(ok || calls[i].allowFailure, "Multicall3: call failed");
            returnData[i] = Result(ok, ret);
        }
    }

    function getBlockNumber() external view returns (uint256) {
        return block.number;
    }

    function getCurrentBlockTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function getEthBalance(address account) external view returns (uint256) {
        return account.balance;
    }

    function getChainId() external view returns (uint256) {
        return block.chainid;
    }
}
