// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SponsoredTaskCreationFee } from "../../src/hooks/sponsored-task/SponsoredTaskCreationFee.sol";

/// @notice Creation-fee configurations for Sponsored Task factory tests.
library SponsoredTaskFeeConfig {
    /// @dev A factory that charges nothing, for tests about something other than the fee.
    function none(IERC20 token) internal pure returns (SponsoredTaskCreationFee.CreationFeeConfig memory) {
        return SponsoredTaskCreationFee.CreationFeeConfig({ token: token, amount: 0, recipient: address(0) });
    }

    function charging(IERC20 token, uint256 amount, address recipient)
        internal
        pure
        returns (SponsoredTaskCreationFee.CreationFeeConfig memory)
    {
        return SponsoredTaskCreationFee.CreationFeeConfig({ token: token, amount: amount, recipient: recipient });
    }
}
