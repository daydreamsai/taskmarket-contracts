// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTMPHookV2 } from "../../src/hooks/base/BaseTMPHookV2.sol";
import { ITMPHooksV2 } from "../../src/interfaces/ITMPHooksV2.sol";

/// @dev A hook that receives callTaskHook calls from the roles it is built with and records the
///      last one. With `reenter` set, onCall calls callTaskHook again on the same task.
contract MockCallHookV2 is BaseTMPHookV2 {
    uint32 public immutable acceptedRoles;
    bool public reenter;
    bool public refuse;

    bytes32 public lastTask;
    address public lastCaller;
    uint32 public lastRoles;
    bytes public lastData;
    uint256 public calls;

    error MockCallRefused();

    constructor(address diamond_, uint32 roles_) BaseTMPHookV2(diamond_) {
        acceptedRoles = roles_;
    }

    function setReenter(bool v) external {
        reenter = v;
    }

    function setRefuse(bool v) external {
        refuse = v;
    }

    function hookCapabilities() external pure override returns (uint32) {
        return uint32(1) << 30;
    }

    function hookCallRoles() external view override returns (uint32) {
        return acceptedRoles;
    }

    function onCall(bytes32 taskId, TaskContextV2 calldata, address caller, uint32 roles, bytes calldata data)
        external
        override
        onlyDiamond
        returns (bytes4)
    {
        if (refuse) revert MockCallRefused();
        if (reenter) ITMPHooksV2(diamond).callTaskHook(taskId, address(this), data);
        lastTask = taskId;
        lastCaller = caller;
        lastRoles = roles;
        lastData = data;
        ++calls;
        return this.onCall.selector;
    }
}
