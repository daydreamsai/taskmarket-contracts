// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import { IPGTRForwarder } from "./IPGTRForwarder.sol";

/// @title IPGTRPaymentForwarder
/// @notice PGTR forwarder that also reports the payment it pulled for the current relayed call,
///         so the destination can check an amount named in calldata against what it received.
interface IPGTRPaymentForwarder is IPGTRForwarder {
    /// @notice USDC amount (6 decimals) the forwarder transferred to the destination for the
    ///         current forwarded call. MUST be set before the destination is called and reset
    ///         after it returns.
    function pgtrPaymentAmount() external view returns (uint256);
}
