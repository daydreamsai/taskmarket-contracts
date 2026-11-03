// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../../src/interfaces/ITMPCore.sol";
import { BaseTMPHookV2 } from "../../src/hooks/base/BaseTMPHookV2.sol";

/// @notice Configurable rev028 V2 hook for tests: capabilities, per-action veto, a settlement
///         result, and a record of what it observed.
contract MockTaskHookV2 is BaseTMPHookV2 {
    uint32 public caps;
    uint16 public minVersion = 28;
    mapping(uint8 => bool) public vetoAction;
    bool public revertAfter;

    // Recorded observations.
    uint256 public createCalls;
    bytes public lastConfig;
    bytes public lastActionData;
    uint8 public lastAfterAction;
    uint64 public lastSeq;
    uint256 public afterCalls;
    uint256 public acceptCalls;
    ITMPCore.TaskStatus public lastAcceptState;
    ITMPCore.TaskStatus public lastPriorStatus;
    address public lastActor;
    SettlementAmounts internal _lastAmounts;
    uint8 public lastTerminalKind; // 1 complete, 2 cancel, 3 expire, 4 forfeit

    // Settlement result.
    ITMPCore.Award[] internal _resultAwards;
    uint16 public resultFeeBps;
    bool public malformedCount;

    constructor(address diamond_, uint32 caps_) BaseTMPHookV2(diamond_) {
        caps = caps_;
    }

    function setCaps(uint32 c) external {
        caps = c;
    }

    function setMinVersion(uint16 v) external {
        minVersion = v;
    }

    function setVeto(uint8 action, bool v) external {
        vetoAction[action] = v;
    }

    function setRevertAfter(bool v) external {
        revertAfter = v;
    }

    function setResult(ITMPCore.Award[] calldata awards, uint16 feeBps, bool malformed) external {
        delete _resultAwards;
        for (uint256 i; i < awards.length; ++i) {
            _resultAwards.push(awards[i]);
        }
        resultFeeBps = feeBps;
        malformedCount = malformed;
    }

    function lastAmounts() external view returns (SettlementAmounts memory) {
        return _lastAmounts;
    }

    function hookCapabilities() external view override returns (uint32) {
        return caps;
    }

    function minDiamondVersion() external view override returns (uint16) {
        return minVersion;
    }

    function _gate(uint8 action, TaskContextV2 calldata ctx, bytes calldata actionData) internal {
        if (vetoAction[action]) revert("veto");
        lastActionData = actionData;
        lastActor = ctx.actor;
        lastPriorStatus = ctx.priorStatus;
    }

    function beforeCreate(bytes32, TaskContextV2 calldata ctx, bytes calldata config, bytes calldata actionData)
        external
        override
        onlyDiamond
        returns (bytes4)
    {
        _gate(0, ctx, actionData);
        createCalls++;
        lastConfig = config;
        return this.beforeCreate.selector;
    }

    function beforeClaim(bytes32, TaskContextV2 calldata ctx, address, bytes calldata actionData)
        external
        override
        onlyDiamond
        returns (bytes4)
    {
        _gate(3, ctx, actionData);
        return this.beforeClaim.selector;
    }

    function beforeSubmitWork(bytes32, TaskContextV2 calldata ctx, address, bytes32, bytes calldata actionData)
        external
        override
        onlyDiamond
        returns (bytes4)
    {
        _gate(9, ctx, actionData);
        return this.beforeSubmitWork.selector;
    }

    function beforeCancel(bytes32, TaskContextV2 calldata ctx, bytes calldata actionData)
        external
        override
        onlyDiamond
        returns (bytes4)
    {
        _gate(14, ctx, actionData);
        return this.beforeCancel.selector;
    }

    function beforeAccept(bytes32, TaskContextV2 calldata ctx, ITMPCore.Verdict calldata, bytes calldata actionData)
        external
        override
        onlyDiamond
        returns (bytes4, SettlementDelta memory, ITMPCore.Award[] memory)
    {
        acceptCalls++;
        lastAcceptState = ctx.currentState;
        _gate(13, ctx, actionData);
        bytes4 sel = this.beforeAccept.selector;
        uint16 count = uint16(_resultAwards.length);
        if (malformedCount) count += 1;
        return (sel, SettlementDelta(sel, count, resultFeeBps), _resultAwards);
    }

    function afterComplete(bytes32, TaskContextV2 calldata, SettlementAmounts calldata a, uint64 seq)
        external
        override
        onlyDiamond
    {
        _after(1, a, seq);
    }

    function afterCancel(bytes32, TaskContextV2 calldata, SettlementAmounts calldata a, uint64 seq)
        external
        override
        onlyDiamond
    {
        _after(2, a, seq);
    }

    function afterExpire(bytes32, TaskContextV2 calldata, SettlementAmounts calldata a, uint64 seq)
        external
        override
        onlyDiamond
    {
        _after(3, a, seq);
    }

    function afterForfeit(bytes32, TaskContextV2 calldata, SettlementAmounts calldata a, uint64 seq)
        external
        override
        onlyDiamond
    {
        _after(4, a, seq);
    }

    function afterAction(bytes32, TaskContextV2 calldata, uint8 action, bytes calldata actionData, uint64 seq)
        external
        override
        onlyDiamond
    {
        if (revertAfter) revert("after");
        lastAfterAction = action;
        lastActionData = actionData;
        lastSeq = seq;
        afterCalls++;
    }

    function _after(uint8 kind, SettlementAmounts calldata a, uint64 seq) internal {
        if (revertAfter) revert("after");
        lastTerminalKind = kind;
        _lastAmounts = a;
        lastSeq = seq;
        afterCalls++;
    }
}
