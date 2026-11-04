// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ScriptBounds } from "../script/lib/ScriptBounds.sol";

/// @dev Calls the library through an external contract so `vm.expectRevert` can see the revert.
contract ScriptBoundsHarness {
    function bps(uint256 value) external pure returns (uint16) {
        return ScriptBounds.bps(value, "SETTING");
    }

    function toUint8(uint256 value) external pure returns (uint8) {
        return ScriptBounds.toUint8(value, "SETTING");
    }
}

/// @dev Deploy scripts read settings as uint256. A bare `uint16(value)` keeps the low 16 bits, so
///      65537 would become 1 and slip past the range check the deployed contract applies.
contract ScriptBoundsTest is Test {
    ScriptBoundsHarness private h = new ScriptBoundsHarness();

    function test_BpsAcceptsTheFullRange() public view {
        assertEq(h.bps(0), 0);
        assertEq(h.bps(8000), 8000);
        assertEq(h.bps(10_000), 10_000);
    }

    function test_RevertWhen_BpsAboveTenThousand() public {
        vm.expectRevert(bytes("SETTING exceeds 10000"));
        h.bps(10_001);
    }

    function test_RevertWhen_BpsWouldTruncateIntoRange() public {
        vm.expectRevert(bytes("SETTING exceeds 10000"));
        h.bps(65_537); // uint16(65537) == 1
        vm.expectRevert(bytes("SETTING exceeds 10000"));
        h.bps((uint256(1) << 16) | 5_000);
    }

    function test_RevertWhen_Uint8WouldTruncateIntoRange() public {
        assertEq(h.toUint8(255), 255);
        vm.expectRevert(bytes("SETTING exceeds 255"));
        h.toUint8(257); // uint8(257) == 1
    }
}
