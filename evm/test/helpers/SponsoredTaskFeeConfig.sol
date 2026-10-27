// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SponsoredTaskCreationFee } from "../../src/hooks/sponsored-task/SponsoredTaskCreationFee.sol";

/// @notice Creation-fee configurations for Sponsored Task factory tests. The calling test contract
///         is the fee admin (it has code, as the factory requires).
library SponsoredTaskFeeConfig {
    uint256 internal constant CEILING = 100_000_000;

    /// @dev A factory that charges nothing, for tests about something other than the fee.
    function none(IERC20 token) internal view returns (SponsoredTaskCreationFee.CreationFeeConfig memory) {
        return SponsoredTaskCreationFee.CreationFeeConfig({
            admin: address(this), token: token, amount: 0, recipient: address(0), ceiling: CEILING
        });
    }

    function charging(IERC20 token, uint256 amount, address recipient)
        internal
        view
        returns (SponsoredTaskCreationFee.CreationFeeConfig memory)
    {
        return SponsoredTaskCreationFee.CreationFeeConfig({
            admin: address(this), token: token, amount: amount, recipient: recipient, ceiling: CEILING
        });
    }
}
