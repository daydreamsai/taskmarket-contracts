// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title ITMPFundingPool -- rev027: a crowdfunded pool of the task payment stablecoin
/// @notice A funding pool collects money from any number of backers for one purpose, which a
///         module of the diamond spends while the pool is open. A project is the first module:
///         each project has one pool, and its tasks are funded from it. Anyone may fund an open
///         pool, for themselves or on behalf of another address. Funding buys shares at the
///         pool's current value: what it holds plus what it has spent on work that has not
///         finished. Money the module gets back (refunds) returns to the pool. Once the pool is
///         settled (closed, or past its closing date) nothing can be spent from it any more: what
///         it holds, plus every later refund, is the backers' pot, which each backer claims in
///         proportion to its shares. Every pool balance is an escrow liability, so the surplus
///         sweep can never take it.
interface ITMPFundingPool {
    /// @notice What the diamond stores for a pool. Pools are opened only by a module, never
    ///         directly.
    struct Pool {
        // The token the pool holds: always the task payment stablecoin.
        address token;
        // When the pool settles on its own; zero means only an explicit close settles it.
        uint64 closesAt;
        bool closed;
        // The module that opened the pool and alone may spend from it.
        bytes32 module;
        // Every amount paid in so far, the module's opening one included. Fixed once settled.
        uint256 funded;
        // While open, what the module can spend; once settled, the backers' unclaimed pot.
        uint256 available;
        // What the module has spent on work that has not finished yet. While the pool is open,
        // its value is available + outstanding, the price fund mints shares at.
        uint256 outstanding;
        // Every backer's shares. Fixed once settled.
        uint256 totalShares;
        // Everything paid out of the pot to backers so far.
        uint256 claimed;
        // The share generation. A credit to a pool worth nothing while shares exist starts the
        // next one: every older share is worth nothing then, so totalShares restarts from zero
        // and a backing from an older generation counts as no shares.
        uint256 generation;
    }

    /// @notice A pool as getPool reports it.
    /// @dev potIn is the cumulative pot: zero while the pool is open, and available + claimed
    ///      once it is settled (what was unspent at settlement plus every later refund).
    struct PoolInfo {
        address token;
        bytes32 module;
        uint64 closesAt;
        bool closed;
        bool settled;
        uint256 funded;
        uint256 available;
        uint256 outstanding;
        uint256 totalShares;
        uint256 potIn;
        uint256 claimed;
        uint256 generation;
    }

    /// @notice One backer's stake in a pool: its shares and what it has claimed, in the share
    ///         generation it last funded in. A backing from an older generation than the pool's
    ///         holds no shares.
    struct Backing {
        uint256 shares;
        uint256 claimed;
        uint256 generation;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event PoolOpened(bytes32 indexed poolId, bytes32 indexed module, address token, uint64 closesAt);
    /// @notice `funder` paid `amount` in, buying `shares` for `onBehalfOf`. A module's opening
    ///         contribution is reported the same way.
    event PoolFunded(
        bytes32 indexed poolId, address indexed funder, address indexed onBehalfOf, uint256 amount, uint256 shares
    );
    /// @notice The module spent `amount` of the open pool on work; it is outstanding until the
    ///         work finishes.
    event PoolSpent(bytes32 indexed poolId, uint256 amount);
    /// @notice `amount` came back to the pool: budget while it is open, the backers' pot once it
    ///         is settled.
    event PoolRefunded(bytes32 indexed poolId, uint256 amount);
    /// @notice The pool was closed explicitly; pot is what it held then, now the backers' pot.
    event PoolClosed(bytes32 indexed poolId, uint256 pot);
    event PoolClaimed(bytes32 indexed poolId, address indexed backer, uint256 amount);
    /// @notice A credit found the open pool worth nothing while shares existed, so every share
    ///         was worth nothing: share generation `generation` starts, totalShares restarts from
    ///         zero and every backing from an earlier generation now holds no shares. Emitted
    ///         before the PoolFunded of the credit that started it.
    event PoolSharesReset(bytes32 indexed poolId, uint256 generation);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error PoolNotFound();
    error PoolAlreadyExists();
    /// @notice The pool is closed or past its closing date.
    error PoolNotOpen();
    error PoolAlreadyClosed();
    error PoolAmountZero();
    error PoolBalanceExceeded(uint256 available, uint256 needed);
    error PoolTransferFailed();
    /// @notice The amount buys no shares at the pool's current value.
    error PoolSharesZero();
    /// @notice A pool cannot be funded on behalf of the diamond itself.
    error PoolInvalidBacker();
    /// @notice The backer's share of the pot, less what it already claimed, is zero, or the pool
    ///         is still open and has no pot.
    error NothingToClaim();

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------

    /// @notice Fund an open pool with `amount`, buying shares for `onBehalfOf` (the caller when
    ///         zero; never the diamond). The first credit, a module's opening contribution, mints
    ///         10^12 shares per base unit; every later one mints
    ///         amount * totalShares / (available + outstanding), so a backer pays the pool's value
    ///         now and shares neither what was spent nor what was won before it joined. A credit
    ///         to a pool worth nothing while shares exist starts a new share generation
    ///         (PoolSharesReset): the old shares are worth nothing, totalShares restarts and the
    ///         credit mints at the first price. Reverts PoolSharesZero when the amount buys no share. Through a
    ///         trusted forwarder the funder is the relayed sender and the forwarder must have moved
    ///         exactly `amount` into escrow. Called directly, the diamond pulls `amount` from the
    ///         caller with transferFrom, so a router or another contract can fund for a user.
    function fund(bytes32 poolId, uint256 amount, address onBehalfOf) external;

    /// @notice Pay `backer` its share of a settled pool's pot: potIn * shares / totalShares,
    ///         less what it already claimed. Anyone may call it, directly or through a forwarder
    ///         that reports no payment; the money always goes to `backer`. Reverts NothingToClaim
    ///         when that is zero.
    function claim(bytes32 poolId, address backer) external returns (uint256 amount);

    function getPool(bytes32 poolId) external view returns (PoolInfo memory);

    /// @notice The backer's shares in the pool's current generation; zero for a backing from
    ///         an earlier one.
    function sharesOf(bytes32 poolId, address backer) external view returns (uint256);

    /// @notice What claim would pay `backer` now; zero while the pool is open.
    function claimable(bytes32 poolId, address backer) external view returns (uint256);
}
