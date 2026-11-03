// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../../src/interfaces/ITMPCore.sol";
import { BaseTMPHookV2 } from "../../src/hooks/base/BaseTMPHookV2.sol";

interface ISettlingViewV2 {
    function isSettling() external view returns (bool);
}

/// @dev Task Hook V2 form of MockSettlingProbeHook: inside beforeAccept it records whether the
///      diamond reports a settlement in progress. Never blocks.
contract MockSettlingProbeHookV2 is BaseTMPHookV2 {
    bool public checkCompleteCalled;
    bool public sawSettling;

    constructor(address diamond_) BaseTMPHookV2(diamond_) { }

    /// @notice beforeAccept (bit 13) only.
    function hookCapabilities() external pure override returns (uint32) {
        return uint32(1) << 13;
    }

    function beforeAccept(bytes32, TaskContextV2 calldata, ITMPCore.Verdict calldata, bytes calldata)
        external
        override
        onlyDiamond
        returns (bytes4, SettlementDelta memory, ITMPCore.Award[] memory)
    {
        checkCompleteCalled = true;
        sawSettling = ISettlingViewV2(diamond).isSettling();
        return _allowAccept();
    }
}
