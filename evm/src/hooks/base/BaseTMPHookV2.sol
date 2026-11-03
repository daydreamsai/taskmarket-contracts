// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ITMPHookV2 } from "../../interfaces/ITMPHookV2.sol";
import { ITMPCore } from "../../interfaces/ITMPCore.sol";
import { LibHooksV2 } from "../../libraries/LibHooksV2.sol";

/// @title BaseTMPHookV2
/// @notice Minimal trusted-caller base for rev028 Task Hook V2 hooks. Every callback is accepted only
///         from the configured TaskMarket Diamond. Each before-callback allows by default and each
///         after-callback does nothing; a hook overrides the ones its capabilities declare.
abstract contract BaseTMPHookV2 is ITMPHookV2 {
    /// @notice TaskMarket Diamond authorized to invoke lifecycle callbacks.
    address public immutable diamond;

    error BaseTMPHookV2__ZeroDiamond();
    error BaseTMPHookV2__UnauthorizedCaller(address caller);
    error BaseTMPHookV2__CallUnsupported();

    // Caller roles onCall receives (see LibHooksV2).
    uint32 internal constant ROLE_REQUESTER = LibHooksV2.ROLE_REQUESTER;
    uint32 internal constant ROLE_PROJECT = LibHooksV2.ROLE_PROJECT;
    uint32 internal constant ROLE_WORKER = LibHooksV2.ROLE_WORKER;
    uint32 internal constant ROLE_SUBMITTER = LibHooksV2.ROLE_SUBMITTER;
    uint32 internal constant ROLE_EVALUATOR = LibHooksV2.ROLE_EVALUATOR;
    uint32 internal constant ROLE_STRANGER = LibHooksV2.ROLE_STRANGER;

    /// @dev Tests one role flag. Roles are a set that later revisions may extend, so never compare
    ///      the whole set.
    function _hasRole(uint32 roles, uint32 role) internal pure returns (bool) {
        return roles & role != 0;
    }

    constructor(address diamond_) {
        if (diamond_ == address(0)) revert BaseTMPHookV2__ZeroDiamond();
        diamond = diamond_;
    }

    modifier onlyDiamond() {
        _onlyDiamond();
        _;
    }

    function _onlyDiamond() internal view {
        if (msg.sender != diamond) revert BaseTMPHookV2__UnauthorizedCaller(msg.sender);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(ITMPHookV2).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @notice The rev028 diamond is the first that dispatches V2 hooks.
    function minDiamondVersion() external view virtual returns (uint16) {
        return 28;
    }

    function hookCapabilities() external view virtual returns (uint32);

    function beforeCreate(bytes32, TaskContextV2 calldata, bytes calldata, bytes calldata)
        external
        virtual
        onlyDiamond
        returns (bytes4)
    {
        return this.beforeCreate.selector;
    }

    function beforeAssignEvaluator(bytes32, TaskContextV2 calldata, address, bytes calldata)
        external
        virtual
        onlyDiamond
        returns (bytes4)
    {
        return this.beforeAssignEvaluator.selector;
    }

    function beforeUpdate(bytes32, TaskContextV2 calldata, bytes calldata)
        external
        virtual
        onlyDiamond
        returns (bytes4)
    {
        return this.beforeUpdate.selector;
    }

    function beforeClaim(bytes32, TaskContextV2 calldata, address, bytes calldata)
        external
        virtual
        onlyDiamond
        returns (bytes4)
    {
        return this.beforeClaim.selector;
    }

    function beforeSubmitPitch(bytes32, TaskContextV2 calldata, address, bytes32, bytes calldata)
        external
        virtual
        onlyDiamond
        returns (bytes4)
    {
        return this.beforeSubmitPitch.selector;
    }

    function beforeSelectWorker(bytes32, TaskContextV2 calldata, address, bytes calldata)
        external
        virtual
        onlyDiamond
        returns (bytes4)
    {
        return this.beforeSelectWorker.selector;
    }

    function beforeSubmitProof(bytes32, TaskContextV2 calldata, address, bytes32, bytes calldata)
        external
        virtual
        onlyDiamond
        returns (bytes4)
    {
        return this.beforeSubmitProof.selector;
    }

    function beforeSubmitBid(bytes32, TaskContextV2 calldata, address, uint256, bytes calldata)
        external
        virtual
        onlyDiamond
        returns (bytes4)
    {
        return this.beforeSubmitBid.selector;
    }

    function beforeAcceptAuction(bytes32, TaskContextV2 calldata, address, bytes calldata)
        external
        virtual
        onlyDiamond
        returns (bytes4)
    {
        return this.beforeAcceptAuction.selector;
    }

    function beforeSubmitWork(bytes32, TaskContextV2 calldata, address, bytes32, bytes calldata)
        external
        virtual
        onlyDiamond
        returns (bytes4)
    {
        return this.beforeSubmitWork.selector;
    }

    function beforeRejectSubmission(bytes32, TaskContextV2 calldata, address, bytes calldata)
        external
        virtual
        onlyDiamond
        returns (bytes4)
    {
        return this.beforeRejectSubmission.selector;
    }

    function beforeEvaluate(bytes32, TaskContextV2 calldata, ITMPCore.Verdict calldata, bytes calldata)
        external
        virtual
        onlyDiamond
        returns (bytes4)
    {
        return this.beforeEvaluate.selector;
    }

    function beforeAppeal(bytes32, TaskContextV2 calldata, address, bytes calldata)
        external
        virtual
        onlyDiamond
        returns (bytes4)
    {
        return this.beforeAppeal.selector;
    }

    function beforeAccept(bytes32, TaskContextV2 calldata, ITMPCore.Verdict calldata, bytes calldata)
        external
        virtual
        onlyDiamond
        returns (bytes4, SettlementDelta memory, ITMPCore.Award[] memory)
    {
        return _allowAccept();
    }

    function beforeCancel(bytes32, TaskContextV2 calldata, bytes calldata)
        external
        virtual
        onlyDiamond
        returns (bytes4)
    {
        return this.beforeCancel.selector;
    }

    function beforeRate(bytes32, TaskContextV2 calldata, address, bytes calldata)
        external
        virtual
        onlyDiamond
        returns (bytes4)
    {
        return this.beforeRate.selector;
    }

    /// @dev No calls accepted by default. A hook that declares capability bit 30 overrides both.
    function hookCallRoles() external view virtual returns (uint32) {
        return 0;
    }

    function onCall(bytes32, TaskContextV2 calldata, address, uint32, bytes calldata)
        external
        virtual
        onlyDiamond
        returns (bytes4)
    {
        revert BaseTMPHookV2__CallUnsupported();
    }

    function afterComplete(bytes32, TaskContextV2 calldata, SettlementAmounts calldata, uint64)
        external
        virtual
        onlyDiamond
    { }

    function afterCancel(bytes32, TaskContextV2 calldata, SettlementAmounts calldata, uint64)
        external
        virtual
        onlyDiamond
    { }

    function afterExpire(bytes32, TaskContextV2 calldata, SettlementAmounts calldata, uint64)
        external
        virtual
        onlyDiamond
    { }

    function afterForfeit(bytes32, TaskContextV2 calldata, SettlementAmounts calldata, uint64)
        external
        virtual
        onlyDiamond
    { }

    function afterAction(bytes32, TaskContextV2 calldata, uint8, bytes calldata, uint64)
        external
        virtual
        onlyDiamond
    { }

    /// @dev beforeAccept's allow return with no settlement result.
    function _allowAccept() internal pure returns (bytes4, SettlementDelta memory, ITMPCore.Award[] memory) {
        bytes4 sel = ITMPHookV2.beforeAccept.selector;
        return (sel, SettlementDelta(sel, 0, 0), new ITMPCore.Award[](0));
    }
}
