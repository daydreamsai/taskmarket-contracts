// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ITMPHook } from "../../src/interfaces/ITMPHook.sol";
import { ITMPCore } from "../../src/interfaces/ITMPCore.sol";

/// @dev ITMPHook whose return data can be configured to a large size, simulating the
///      return-data DoS from issue #317. All check* calls return a normal 32-byte bool by
///      default so the hook registers/claims/etc. without issue; only the calls explicitly
///      armed via setBombOn* return the oversized blob instead. Declared Solidity return
///      types are irrelevant here -- the bomb is emitted via raw assembly `return`, which
///      controls the actual RETURN opcode regardless of the interface signature.
contract MockReturnBombHook is ITMPHook {
    uint256 public bombSize;
    bool public bombOnCheckSubmit;
    bool public bombOnExpire;

    function setBombSize(uint256 size) external {
        bombSize = size;
    }

    function setBombOnCheckSubmit(bool v) external {
        bombOnCheckSubmit = v;
    }

    function setBombOnExpire(bool v) external {
        bombOnExpire = v;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ITMPHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function checkFund(bytes32, ITMPCore.TaskContext calldata, bytes calldata) external pure override returns (bool) {
        return true;
    }

    function checkClaim(bytes32, ITMPCore.TaskContext calldata, address) external pure override returns (bool) {
        return true;
    }

    function checkSelectWorker(bytes32, ITMPCore.TaskContext calldata, address) external pure override returns (bool) {
        return true;
    }

    function checkSubmit(bytes32, ITMPCore.TaskContext calldata, address, bytes32) external override returns (bool) {
        if (bombOnCheckSubmit) _returnBomb();
        return true;
    }

    function checkEvaluate(bytes32, ITMPCore.TaskContext calldata, address) external pure override returns (bool) {
        return true;
    }

    function checkComplete(bytes32, ITMPCore.TaskContext calldata, ITMPCore.Verdict calldata)
        external
        pure
        override
        returns (bool)
    {
        return true;
    }

    function onComplete(bytes32, ITMPCore.TaskContext calldata, ITMPCore.Verdict calldata) external override { }

    function onForfeit(bytes32, ITMPCore.TaskContext calldata, address) external override { }

    function onCancel(bytes32, ITMPCore.TaskContext calldata) external override { }

    function onExpire(bytes32, ITMPCore.TaskContext calldata) external override {
        if (bombOnExpire) _returnBomb();
    }

    /// @dev Returns `bombSize` bytes of zeroed memory via raw RETURN, independent of the
    ///      caller's declared ABI return type.
    function _returnBomb() internal view {
        uint256 size = bombSize;
        assembly {
            let ptr := mload(0x40)
            mstore(0x40, add(ptr, size))
            return(ptr, size)
        }
    }
}
