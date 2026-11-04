// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BaseTMPHookV2 } from "../../src/hooks/base/BaseTMPHookV2.sol";
import { ITMPFundingPool } from "../../src/interfaces/ITMPFundingPool.sol";

/// @dev rev028 V2 after-hook (afterComplete, afterCancel, afterExpire, afterForfeit) that records
///      the funding pool's value (available + outstanding) and share supply as a settlement
///      callback sees them, and can try a direct fund, so a test can check the pool is consistent
///      while the settlement is still running.
contract MockPoolProbeHook is BaseTMPHookV2 {
    uint32 internal constant CAPS = (uint32(1) << 21) | (uint32(1) << 22) | (uint32(1) << 23) | (uint32(1) << 24);

    ITMPFundingPool public immutable pools;
    bytes32 public immutable poolId;

    uint256 public calls;
    uint256 public seenValue;
    uint256 public seenShares;
    uint256 public fundAmount;
    bool public fundSucceeded;
    bytes public fundRevert;

    constructor(address diamond_, ITMPFundingPool pools_, bytes32 poolId_) BaseTMPHookV2(diamond_) {
        pools = pools_;
        poolId = poolId_;
    }

    /// @dev Makes every later probe also try a direct fund of `amount`, which the hook holds.
    function arm(IERC20 token, uint256 amount) external {
        fundAmount = amount;
        token.approve(address(pools), amount);
    }

    function hookCapabilities() external pure override returns (uint32) {
        return CAPS;
    }

    function _probe() private {
        ITMPFundingPool.PoolInfo memory info = pools.getPool(poolId);
        calls++;
        seenValue = info.available + info.outstanding;
        seenShares = info.totalShares;
        if (fundAmount != 0) {
            try pools.fund(poolId, fundAmount, address(this)) {
                fundSucceeded = true;
            } catch (bytes memory reason) {
                fundRevert = reason;
            }
        }
    }

    function afterComplete(bytes32, TaskContextV2 calldata, SettlementAmounts calldata, uint64)
        external
        override
        onlyDiamond
    {
        _probe();
    }

    function afterCancel(bytes32, TaskContextV2 calldata, SettlementAmounts calldata, uint64)
        external
        override
        onlyDiamond
    {
        _probe();
    }

    function afterExpire(bytes32, TaskContextV2 calldata, SettlementAmounts calldata, uint64)
        external
        override
        onlyDiamond
    {
        _probe();
    }

    function afterForfeit(bytes32, TaskContextV2 calldata, SettlementAmounts calldata, uint64)
        external
        override
        onlyDiamond
    {
        _probe();
    }
}
