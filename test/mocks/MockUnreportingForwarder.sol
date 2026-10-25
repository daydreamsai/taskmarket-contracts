// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IPGTRForwarder } from "../../src/interfaces/IPGTRForwarder.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @dev Test double for a PGTR forwarder that cannot report the payment it relays: it has no
///      pgtrPaymentAmount, so the diamond must refuse every payment path through it.
contract MockUnreportingForwarder is IPGTRForwarder {
    address private _pgtrSenderValue;

    function isPGTRForwarder() external pure override returns (bool) {
        return true;
    }

    function pgtrSender() external view override returns (address) {
        return _pgtrSenderValue;
    }

    function isTrustedForwarder(address addr) external view override returns (bool) {
        return addr == address(this);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPGTRForwarder).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function relay(address target, address pgtrSenderAddr, bytes calldata data) external returns (bytes memory) {
        _pgtrSenderValue = pgtrSenderAddr;
        (bool success, bytes memory result) = target.call(data);
        _pgtrSenderValue = address(0);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        return result;
    }
}
