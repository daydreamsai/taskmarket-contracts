// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTMPHookV2 } from "../base/BaseTMPHookV2.sol";
import { ITMPHookV2 } from "../../interfaces/ITMPHookV2.sol";

/// @title ProofGateHook -- only allowlisted workers may submit benchmark proof entries
/// @notice A standalone Task Hook V2 hook, shared per chain and deployed on its own. A task attaches it at creation with the
///         configuration `abi.encode(address[] allowed)`, or an empty configuration to start with an
///         empty allowlist; the task's requester adds workers with `allow`. Under V2 the
///         diamond calls `beforeSubmitProof` from `submitProof` before the proof hash is recorded, so
///         a rejection leaves nothing recorded and nothing paid. `beforeSubmitWork`, which runs when
///         a result is anchored, is a separate callback this hook does not declare.
/// @dev Needs a diamond that dispatches Task Hook V2 (diamondVersion 28 or later). See
///      docs/extensions/ext-004-proof-gate-hook.md.
contract ProofGateHook is BaseTMPHookV2 {
    /// @notice Capability bits: before Create (0) and before SubmitProof (6). Check only.
    uint32 public constant CAPABILITIES = (uint32(1) << 0) | (uint32(1) << 6);
    /// @notice Upper bound on the allowlist, to keep the attach within its gas budget.
    uint256 public constant MAX_ALLOWED = 64;

    mapping(bytes32 => mapping(address => bool)) private _allowed;
    mapping(bytes32 => address) private _requesterOf;

    event ProofGateSet(bytes32 indexed taskId, uint256 allowedCount);
    event ProofGateAllowed(bytes32 indexed taskId, address indexed worker);

    error ProofGate__InvalidConfig();
    error ProofGate__AlreadySet();
    error ProofGate__NotRequester();
    error ProofGate__WorkerNotAllowed(address worker);

    constructor(address diamond_) BaseTMPHookV2(diamond_) { }

    function hookCapabilities() external pure override returns (uint32) {
        return CAPABILITIES;
    }

    /// @notice Whether `worker` may submit proof entries to `taskId`.
    function isAllowed(bytes32 taskId, address worker) external view returns (bool) {
        return _allowed[taskId][worker];
    }

    /// @notice The task's requester allows one more worker to submit proof entries.
    function allow(bytes32 taskId, address worker) external {
        if (msg.sender != _requesterOf[taskId]) revert ProofGate__NotRequester();
        if (worker == address(0)) revert ProofGate__InvalidConfig();
        _allowed[taskId][worker] = true;
        emit ProofGateAllowed(taskId, worker);
    }

    function beforeCreate(bytes32 taskId, TaskContextV2 calldata ctx, bytes calldata config, bytes calldata)
        external
        override
        onlyDiamond
        returns (bytes4)
    {
        if (_requesterOf[taskId] != address(0)) revert ProofGate__AlreadySet();
        _requesterOf[taskId] = ctx.requester;
        address[] memory allowed = config.length == 0 ? new address[](0) : abi.decode(config, (address[]));
        if (allowed.length > MAX_ALLOWED) revert ProofGate__InvalidConfig();
        for (uint256 i = 0; i < allowed.length; i++) {
            if (allowed[i] == address(0)) revert ProofGate__InvalidConfig();
            _allowed[taskId][allowed[i]] = true;
        }
        emit ProofGateSet(taskId, allowed.length);
        return this.beforeCreate.selector;
    }

    function beforeSubmitProof(bytes32 taskId, TaskContextV2 calldata, address who, bytes32, bytes calldata)
        external
        view
        override
        onlyDiamond
        returns (bytes4)
    {
        if (!_allowed[taskId][who]) revert ProofGate__WorkerNotAllowed(who);
        return ITMPHookV2.beforeSubmitProof.selector;
    }
}
