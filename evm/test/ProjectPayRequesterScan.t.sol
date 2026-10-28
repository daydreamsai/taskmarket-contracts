// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

/// @dev rev027: money owed to a task's requester goes through LibProject.payRequester, which
///      credits a project task's budget instead of the requester's wallet. This scans the diamond's
///      facets and libraries for a token transfer that pays a task's requester directly, so a new
///      payout path cannot skip payRequester unnoticed. A line fails when it calls transfer or
///      safeTransfer and names a requester; when it picks a requester in a ternary, the way an
///      `address to = cond ? x : task.requester` recipient does; or when it transfers to a local
///      variable assigned from `.requester`. LibProject.payRequester's own fallback transfer for a
///      task in no project is the one exception. ProjectRequesterPayouts.t.sol checks the paths at
///      runtime.
contract ProjectPayRequesterScanTest is Test {
    string internal constant EXEMPT_FILE = "LibProject.sol";
    string internal constant EXEMPT_LINE = "s.usdcToken.transfer(s.tasks[taskId].requester, amount)";

    function test_NoFacetOrLibraryPaysTheRequesterDirectly() public view {
        uint256 calls = _scanDir("src/facets") + _scanDir("src/libraries");
        // The scan must see the payRequester call sites, or a path or layout change has blinded it.
        assertGt(calls, 10, "payRequester call sites found");
    }

    function _scanDir(string memory dir) internal view returns (uint256 calls) {
        Vm.DirEntry[] memory entries = vm.readDir(dir);
        assertGt(entries.length, 0, dir);
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].isDir || !vm.contains(entries[i].path, ".sol")) continue;
            calls += _scanFile(entries[i].path);
        }
    }

    /// @dev Returns the number of LibProject.payRequester calls in the file.
    function _scanFile(string memory path) internal view returns (uint256 calls) {
        string[] memory lines = vm.split(vm.readFile(path), "\n");
        bool exemptFile = vm.contains(path, EXEMPT_FILE);
        // Local address variables holding a task's requester, in the order they are declared.
        string[] memory locals = new string[](lines.length);
        uint256 nLocals;
        for (uint256 i; i < lines.length; ++i) {
            string memory line = vm.trim(lines[i]);
            if (_isComment(line)) continue;
            if (vm.contains(line, "LibProject.payRequester(")) ++calls;

            string memory lower = vm.toLowercase(line);
            bool namesRequester = vm.contains(lower, "requester");
            if (vm.contains(line, "address ") && vm.contains(line, " = ") && vm.contains(line, ".requester")) {
                locals[nLocals++] = _declaredName(line);
            }
            if (namesRequester && vm.contains(line, " ? ") && vm.contains(line, " : ")) {
                _fail(path, i, line, "chooses a requester as a recipient");
            }
            if (!_isTransfer(line)) continue;
            if (namesRequester && !(exemptFile && vm.contains(line, EXEMPT_LINE))) {
                _fail(path, i, line, "transfers to a requester");
            }
            for (uint256 j; j < nLocals; ++j) {
                if (vm.contains(line, string.concat("transfer(", locals[j], ","))) {
                    _fail(path, i, line, "transfers to a variable holding the requester");
                }
            }
        }
    }

    function _isComment(string memory line) internal pure returns (bool) {
        bytes memory b = bytes(line);
        if (b.length == 0) return true;
        return b[0] == "*" || (b.length > 1 && b[0] == "/" && (b[1] == "/" || b[1] == "*"));
    }

    function _isTransfer(string memory line) internal pure returns (bool) {
        return vm.contains(line, ".transfer(") || vm.contains(line, ".safeTransfer(");
    }

    /// @dev The variable name in `address name = ...`.
    function _declaredName(string memory line) internal pure returns (string memory) {
        string[] memory lhs = vm.split(vm.split(line, " = ")[0], " ");
        return lhs[lhs.length - 1];
    }

    function _fail(string memory path, uint256 i, string memory line, string memory why) internal pure {
        revert(string.concat(path, ":", vm.toString(i + 1), " ", why, " outside LibProject.payRequester: ", line));
    }
}
