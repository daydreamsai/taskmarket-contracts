// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SponsoredTaskTypes } from "../SponsoredTaskTypes.sol";

interface ISponsoredTaskFeePolicy {
    function feeTerms() external view returns (SponsoredTaskTypes.FeeTerms memory);
}
