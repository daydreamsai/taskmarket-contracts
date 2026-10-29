// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AppStorage } from "./LibAppStorage.sol";
import { ITMPFundingPool } from "../interfaces/ITMPFundingPool.sol";

/// @title LibFundingPool -- rev027: the funding pool every module of the diamond spends from
/// @dev Modules open pools, credit opening contributions, spend while a pool is open, refund to
///      it, finish what they spent and close it; FundingPoolFacet lets anyone fund an open pool
///      and claim from a settled one. Every amount a pool holds (available) is booked in
///      totalLiabilities: credit and refund book it, spend and claim release it. The caller of
///      credit is responsible for the money having arrived, which the solvency check after the
///      booking enforces.
///
///      Funding buys shares at the pool's value, available + outstanding, where outstanding is what
///      the module has spent on work that has not finished. A spend moves money from available to
///      outstanding and leaves the value alone; a refund adds to available; finish takes from
///      outstanding what the work used up. So a backer that joins after money was spent pays only
///      for what is left, and one that joins after a windfall pays for it.
///
///      A pool is settled once it is closed or past closesAt. Nothing can spend from or fund a
///      settled pool, and a pool never becomes open again, so from that moment available is the
///      backers' pot: refunds keep landing in it, and claims take from it. potIn, the cumulative
///      pot, is therefore available + claimed and need not be stored, and a refund is the same
///      single write whether the pool is open or settled. Settlement at closesAt needs no
///      transaction.
library LibFundingPool {
    /// @notice Shares the first credit mints per base unit. Later credits mint at the pool's
    ///         value, rounding down, so a backer can lose up to one share's value to rounding;
    ///         starting each share at 10^-12 of a base unit keeps that negligible, and keeps it so
    ///         however much a windfall (a forfeited worker stake, say) raises a share's value.
    uint256 internal constant SHARE_SCALE = 1e12;

    /// @notice The pool ID of `key` under `module`: one derivation for every module, so two
    ///         modules can never collide.
    function poolIdOf(bytes32 module, uint256 key) internal pure returns (bytes32) {
        return keccak256(abi.encode(module, key));
    }

    /// @notice Opens a pool of `token` for `module`. Reverts when the ID is taken.
    function open(AppStorage storage s, bytes32 poolId, address token, bytes32 module, uint64 closesAt) internal {
        ITMPFundingPool.Pool storage p = s.fundingPools[poolId];
        if (p.token != address(0)) revert ITMPFundingPool.PoolAlreadyExists();
        p.token = token;
        p.module = module;
        p.closesAt = closesAt;
        emit ITMPFundingPool.PoolOpened(poolId, module, token, closesAt);
    }

    /// @notice Credits `amount` paid in by `funder` to `backer` as shares at the pool's value, and
    ///         books it. The pool must be open; the caller checks the money arrived
    ///         (requireSolvent).
    /// @dev The first credit mints SHARE_SCALE shares per base unit. A later one mints
    ///      amount * totalShares / value, rounded down. When the value is zero while shares exist,
    ///      the old shares are worth nothing, and pricing the pool at one base unit gives the new
    ///      backer amount / (amount + 1) of it: all of its money back but under one base unit.
    function credit(AppStorage storage s, bytes32 poolId, address funder, address backer, uint256 amount) internal {
        ITMPFundingPool.Pool storage p = get(s, poolId);
        if (amount == 0) revert ITMPFundingPool.PoolAmountZero();
        if (!isOpen(p)) revert ITMPFundingPool.PoolNotOpen();
        uint256 supply = p.totalShares;
        uint256 shares;
        if (supply == 0) {
            shares = amount * SHARE_SCALE;
        } else {
            uint256 value = p.available + p.outstanding;
            shares = Math.mulDiv(amount, supply, value == 0 ? 1 : value);
        }
        if (shares == 0) revert ITMPFundingPool.PoolSharesZero();
        p.totalShares = supply + shares;
        p.funded += amount;
        p.available += amount;
        s.poolBackings[poolId][backer].shares += shares;
        s.totalLiabilities += amount;
        emit ITMPFundingPool.PoolFunded(poolId, funder, backer, amount, shares);
    }

    /// @notice Takes `amount` out of an open pool for the module's work, where it is outstanding
    ///         until the work finishes, and releases its booking, for the module to book again
    ///         where it puts the money.
    function spend(AppStorage storage s, bytes32 poolId, uint256 amount) internal {
        ITMPFundingPool.Pool storage p = get(s, poolId);
        if (!isOpen(p)) revert ITMPFundingPool.PoolNotOpen();
        uint256 available = p.available;
        if (amount > available) revert ITMPFundingPool.PoolBalanceExceeded(available, amount);
        p.available = available - amount;
        p.outstanding += amount;
        s.totalLiabilities -= amount;
        emit ITMPFundingPool.PoolSpent(poolId, amount);
    }

    /// @notice Returns `amount` to the pool and books it: spendable again while the pool is open,
    ///         part of the backers' pot once it is settled.
    function refund(AppStorage storage s, bytes32 poolId, uint256 amount) internal {
        s.fundingPools[poolId].available += amount;
        s.totalLiabilities += amount;
        emit ITMPFundingPool.PoolRefunded(poolId, amount);
    }

    /// @notice `amount` the module spent is no longer held by its work: the work paid it out or
    ///         refunded it. It leaves outstanding; a refund has already added it to available.
    function finish(AppStorage storage s, bytes32 poolId, uint256 amount) internal {
        s.fundingPools[poolId].outstanding -= amount;
    }

    /// @notice Settles the pool now: what it holds becomes the backers' pot. No money moves.
    function close(AppStorage storage s, bytes32 poolId) internal {
        ITMPFundingPool.Pool storage p = get(s, poolId);
        if (p.closed) revert ITMPFundingPool.PoolAlreadyClosed();
        p.closed = true;
        emit ITMPFundingPool.PoolClosed(poolId, p.available);
    }

    /// @notice Pays `backer` its share of a settled pool's pot and releases its booking.
    function claim(AppStorage storage s, bytes32 poolId, address backer) internal returns (uint256 amount) {
        ITMPFundingPool.Pool storage p = get(s, poolId);
        ITMPFundingPool.Backing storage b = s.poolBackings[poolId][backer];
        amount = claimable(p, b);
        if (amount == 0) revert ITMPFundingPool.NothingToClaim();
        b.claimed += amount;
        p.available -= amount;
        p.claimed += amount;
        s.totalLiabilities -= amount;
        if (!s.usdcToken.transfer(backer, amount)) revert ITMPFundingPool.PoolTransferFailed();
        emit ITMPFundingPool.PoolClaimed(poolId, backer, amount);
    }

    /// @notice Open means not closed and before closesAt (or no closesAt): it can be funded and
    ///         spent from. A pool that is not open is settled, and never opens again.
    function isOpen(ITMPFundingPool.Pool storage p) internal view returns (bool) {
        return !p.closed && (p.closesAt == 0 || block.timestamp < p.closesAt);
    }

    function get(AppStorage storage s, bytes32 poolId) internal view returns (ITMPFundingPool.Pool storage p) {
        p = s.fundingPools[poolId];
        if (p.token == address(0)) revert ITMPFundingPool.PoolNotFound();
    }

    /// @notice Reverts PoolNotFound for an unknown pool; for views that only check it exists.
    function requireExists(AppStorage storage s, bytes32 poolId) internal view {
        if (s.fundingPools[poolId].token == address(0)) revert ITMPFundingPool.PoolNotFound();
    }

    /// @notice A backer's share of the pot so far, less what it claimed; zero while the pool is
    ///         open, since an open pool's available balance is budget, not a pot.
    /// @dev Once settled, the pot potIn = available + claimed only grows: nothing but a claim
    ///      reduces available, and a claim moves the same amount into claimed, while refunds add
    ///      to available. Shares and totalShares are fixed once settled (funding needs an open
    ///      pool). So the entitlement potIn * shares / totalShares only grows and never falls
    ///      below what the backer claimed, and money that arrives after a claim is shared out the
    ///      same way. Rounding is down, so the entitlements sum to at most potIn: claims can never
    ///      exceed the pot, and available can never underflow. What rounding leaves, under one
    ///      base unit per backer, stays in available, booked in totalLiabilities and never paid
    ///      out, so it can only over-cover the liabilities.
    function claimable(ITMPFundingPool.Pool storage p, ITMPFundingPool.Backing storage b)
        internal
        view
        returns (uint256)
    {
        uint256 supply = p.totalShares;
        if (isOpen(p) || supply == 0) return 0;
        return Math.mulDiv(p.available + p.claimed, b.shares, supply) - b.claimed;
    }
}
