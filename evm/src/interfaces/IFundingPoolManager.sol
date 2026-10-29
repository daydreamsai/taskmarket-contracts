// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title IFundingPoolManager -- rev027: what the diamond calls on the funding pool contract
/// @notice The funding pool is its own contract. Backers use the public side, ITMPFundingPool
///         (fund, claim and the views). The diamond, as the pool's only manager, uses this side
///         to open pools and to spend from them, refund to them and close them. A pool contract
///         implements both. Every function here reverts NotManager for any other caller.
interface IFundingPoolManager {
    /// @notice `finish` was asked to release more than the pool's outstanding amount, so it
    ///         released `applied` instead of reverting. A drift between the diamond's task draws
    ///         and the pool's outstanding shows up here and cannot block a payout.
    event PoolLedgerMismatch(bytes32 indexed poolId, uint256 requested, uint256 applied);

    /// @notice The caller is not the pool's manager.
    error NotManager();
    /// @notice The pool or an initialiser was given a token other than the diamond's payment
    ///         token.
    error PoolInvalidToken();
    /// @notice The pool is paused: fund, creditFunding and claim are stopped.
    error PoolPaused();

    /// @notice The only address that may call the manager functions: the diamond.
    function manager() external view returns (address);

    /// @notice Opens a pool of `token`, the diamond's payment token, for `module`. Reverts
    ///         PoolAlreadyExists when the id is taken.
    function open(bytes32 poolId, address token, bytes32 module, uint64 closesAt) external;

    /// @notice Books `amount` as a module's opening contribution for `backer`, which the diamond
    ///         has already transferred to the pool. The first credit mints the opening shares.
    ///         Not stopped by the pool's pause.
    function creditOpening(bytes32 poolId, address backer, uint256 amount) external;

    /// @notice Books `amount` paid in by `funder` for `backer`, which the diamond has already
    ///         transferred to the pool (funding relayed through the diamond). Stopped by the
    ///         pool's pause.
    function creditFunding(bytes32 poolId, address funder, address backer, uint256 amount) external;

    /// @notice Moves `amount` of an open pool's available balance to the diamond for a task,
    ///         where it becomes outstanding until the task finishes. Reverts PoolBalanceExceeded
    ///         above available. Never paused.
    function spend(bytes32 poolId, uint256 amount) external;

    /// @notice Books `amount` that the diamond has already transferred back to the pool. Never
    ///         paused, and reverts only for an unknown pool or a caller that is not the manager.
    function refund(bytes32 poolId, uint256 amount) external;

    /// @notice `amount` of what the pool spent is no longer held by its work. It leaves
    ///         outstanding, saturating at zero: asking for more emits PoolLedgerMismatch and
    ///         releases what outstanding holds. Never reverts on arithmetic and never paused.
    function finish(bytes32 poolId, uint256 amount) external;

    /// @notice Settles the pool now: what it holds becomes the backers' pot. Never paused.
    function close(bytes32 poolId) external;
}

/// @notice What the pool reads from the diamond: its owner, which is also the pool's owner, and
///         its payment token.
interface IDiamondForPool {
    function owner() external view returns (address);
    function usdcToken() external view returns (address);
}
