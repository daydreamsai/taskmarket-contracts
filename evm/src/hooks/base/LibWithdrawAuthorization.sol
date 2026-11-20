// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

/// @title LibWithdrawAuthorization
/// @notice Rev031: the wallet signature check of `TaskTokenRewardHookV2.withdrawFor`, moved out of
///         the hook into a linked library so the hook stays under the contract size limit.
/// @dev An external library function runs by DELEGATECALL, so `address(this)` is the hook proxy
///      and `block.chainid` the hook's chain, exactly as when the check was inline. It reads and
///      writes no storage; nonce replay protection stays in the hook.
library LibWithdrawAuthorization {
    /// @notice Whether `signature` is `wallet`'s authorization to withdraw to `destination`: an
    ///         ECDSA signature by the wallet's key, or the wallet's ERC-1271 validation, over the
    ///         EIP-191 text
    ///         `taskmarket:withdraw-dreams:<wallet>:<destination>:<nonce>:<validBefore>:<chainId>:<hook>`
    ///         with addresses lowercase hex.
    /// @dev ECDSA is tried first and regardless of code, because an EOA upgraded with EIP-7702 has
    ///      code (its delegation designator) but still holds its key; SignatureChecker would skip
    ///      ECDSA for it. ERC-1271 must return exactly the magic value.
    function isAuthorized(
        address wallet,
        address destination,
        string calldata nonce,
        uint256 validBefore,
        bytes calldata signature
    ) external view returns (bool) {
        string memory message = string.concat(
            "taskmarket:withdraw-dreams:",
            Strings.toHexString(wallet),
            ":",
            Strings.toHexString(destination),
            ":",
            nonce,
            ":",
            Strings.toString(validBefore),
            ":",
            Strings.toString(block.chainid),
            ":",
            Strings.toHexString(address(this))
        );
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(bytes(message));
        (address recovered, ECDSA.RecoverError err, bytes32 errArg) = ECDSA.tryRecover(digest, signature);
        if (err == ECDSA.RecoverError.NoError && errArg == bytes32(0) && recovered == wallet) return true;
        return SignatureChecker.isValidERC1271SignatureNow(wallet, digest, signature);
    }
}
