// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IPGTRForwarder } from "../../src/interfaces/IPGTRForwarder.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @dev Test double for a PGTR forwarder (ERC-8194).
///      Holds USDC on behalf of payers and sets pgtrSender atomically
///      during each relayed call to the destination contract.
contract MockPGTRForwarder is IPGTRForwarder {
    IERC20 public usdc;
    address private _pgtrSenderValue;

    constructor(address _usdc) {
        usdc = IERC20(_usdc);
    }

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

    function relay(address target, address pgtrSenderAddr, uint256 paymentAmount, bytes calldata data)
        external
        returns (bytes memory)
    {
        if (paymentAmount > 0) {
            require(usdc.transfer(target, paymentAmount), "USDC transfer failed");
        }
        _pgtrSenderValue = pgtrSenderAddr;
        (bool success, bytes memory result) = target.call(data);
        _pgtrSenderValue = address(0);
        if (!success) {
            if (result.length > 0) {
                assembly { revert(add(result, 32), mload(result)) }
            }
            revert("relay failed");
        }
        return result;
    }
}
