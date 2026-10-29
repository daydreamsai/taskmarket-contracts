// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibGuards } from "../libraries/LibGuards.sol";
import { LibEscrow } from "../libraries/LibEscrow.sol";
import { LibFundingPool } from "../libraries/LibFundingPool.sol";
import { ITMPFundingPool } from "../interfaces/ITMPFundingPool.sol";

/// @title FundingPoolFacet -- rev027: anyone funds an open pool, anyone claims for a backer
/// @notice See ITMPFundingPool. Pools are opened, spent from and closed by the modules that own
///         them (a project's ProjectFacet); this facet is the backers' side, the same for every
///         module, so a later crowdfunded kind of work needs no new public surface.
contract FundingPoolFacet {
    /// @notice See ITMPFundingPool.
    function fund(bytes32 poolId, uint256 amount, address onBehalfOf) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        ITMPFundingPool.Pool storage p = LibFundingPool.get(s, poolId);
        if (amount == 0) revert ITMPFundingPool.PoolAmountZero();
        if (!LibFundingPool.isOpen(p)) revert ITMPFundingPool.PoolNotOpen();
        address funder;
        if (s.trustedForwarders[msg.sender]) {
            // Relayed: the forwarder moved the payment in before the call and reports it.
            funder = LibGuards._effectiveSender(s);
            LibGuards._requireReportedPayment(amount);
        } else {
            // Direct: a router or another contract pays from its own balance.
            funder = msg.sender;
            if (!s.usdcToken.transferFrom(msg.sender, address(this), amount)) {
                revert ITMPFundingPool.PoolTransferFailed();
            }
        }
        if (onBehalfOf == address(0)) onBehalfOf = funder;
        // Shares held by the diamond could be claimed into the diamond, unbooked, for the surplus
        // sweep to take.
        if (onBehalfOf == address(this)) revert ITMPFundingPool.PoolInvalidBacker();
        LibFundingPool.credit(s, poolId, funder, onBehalfOf, amount);
        LibEscrow.requireSolvent(s);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice See ITMPFundingPool. Permissionless: the share always goes to `backer`, so the
    ///         backend or anyone else can sweep for backers who never send a transaction. Relayed,
    ///         the forwarder must report no payment, so none lands unbooked.
    function claim(bytes32 poolId, address backer) external returns (uint256 amount) {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);
        if (s.trustedForwarders[msg.sender]) LibGuards._requireReportedPayment(0);
        amount = LibFundingPool.claim(s, poolId, backer);
        LibEscrow.requireSolvent(s);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice See ITMPFundingPool.
    function getPool(bytes32 poolId) external view returns (ITMPFundingPool.PoolInfo memory info) {
        ITMPFundingPool.Pool storage p = LibFundingPool.get(LibAppStorage.appStorage(), poolId);
        bool settled = !LibFundingPool.isOpen(p);
        info = ITMPFundingPool.PoolInfo({
            token: p.token,
            module: p.module,
            closesAt: p.closesAt,
            closed: p.closed,
            settled: settled,
            funded: p.funded,
            available: p.available,
            outstanding: p.outstanding,
            totalShares: p.totalShares,
            potIn: settled ? p.available + p.claimed : 0,
            claimed: p.claimed,
            generation: p.generation
        });
    }

    /// @notice See ITMPFundingPool.
    function sharesOf(bytes32 poolId, address backer) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.appStorage();
        return LibFundingPool.sharesOf(LibFundingPool.get(s, poolId), s.poolBackings[poolId][backer]);
    }

    /// @notice See ITMPFundingPool.
    function claimable(bytes32 poolId, address backer) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.appStorage();
        return LibFundingPool.claimable(LibFundingPool.get(s, poolId), s.poolBackings[poolId][backer]);
    }
}
