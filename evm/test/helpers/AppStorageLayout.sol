// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AppStorage } from "../../src/libraries/LibAppStorage.sol";

/// @dev Never deployed. Declares `AppStorage` as its only state variable so that
///      `forge inspect ... storageLayout` reports the struct's member layout for `make contract evm storage-check`.
contract AppStorageLayout {
    AppStorage internal s;
}
