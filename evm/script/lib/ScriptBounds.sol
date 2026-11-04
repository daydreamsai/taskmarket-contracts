// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ScriptBounds
/// @notice Range checks for deploy-script settings that are read as `uint256` and then narrowed.
/// @dev A bare `uint16(value)` or `uint8(value)` keeps only the low bits, so `65537` becomes `1` and
///      passes a downstream range check. Each helper checks the full-width value first, then narrows.
library ScriptBounds {
    uint256 internal constant MAX_BPS = 10_000;

    /// @notice Returns `value` as a uint16 basis-point setting, reverting when it exceeds 10000.
    function bps(uint256 value, string memory name) internal pure returns (uint16) {
        require(value <= MAX_BPS, string.concat(name, " exceeds 10000"));
        return uint16(value);
    }

    /// @notice Returns `value` as a uint8, reverting when it does not fit.
    function toUint8(uint256 value, string memory name) internal pure returns (uint8) {
        require(value <= type(uint8).max, string.concat(name, " exceeds 255"));
        return uint8(value);
    }
}
