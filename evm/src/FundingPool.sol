// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ITMPFundingPool } from "./interfaces/ITMPFundingPool.sol";
import { IFundingPoolManager, IDiamondForPool } from "./interfaces/IFundingPoolManager.sol";

/// @title FundingPool -- rev027: the crowdfunded pool as its own upgradeable contract
/// @notice One contract for every project's pool, behind a UUPS proxy. The Diamond is the only
///         manager: it opens pools, books money it has transferred in, spends from pools, and
///         closes them. Backers fund and claim directly. Shares are priced at the pool's current
///         value (available + outstanding), the first credit of a share generation mints
///         SHARE_SCALE shares per base unit, and a credit to a pool worth nothing while shares
///         exist starts the next generation. See rev027-funding-pool-contract.md.
/// @dev Accounting. totalLiabilities is the sum of every pool's `available`, booked the way
///      LibEscrow books the Diamond's escrow: credits and refunds add to it, spend and claim
///      release it. Every state-changing call ends with balanceOf(this) >= totalLiabilities.
///      Tokens sent straight to the pool are not booked and stay (there is no sweep).
///
///      Ownership. The pool's owner is whoever owns the manager (the Diamond) at the moment of the
///      call; it can pause, unpause and upgrade. Pause stops fund, creditFunding and claim only.
///
///      Storage lives in one ERC-7201 namespaced struct, so an upgrade adds fields at the end of it
///      and inherited bases cannot collide with it.
contract FundingPool is Initializable, UUPSUpgradeable, ITMPFundingPool, IFundingPoolManager {
    using SafeERC20 for IERC20;

    /// @notice Shares the first credit of a share generation mints per base unit. Later credits
    ///         mint at the pool's value, rounding down. Starting each share at 10^-12 of a base unit
    ///         keeps the rounding loss under one base unit for any windfall smaller than 10^12
    ///         base units.
    uint256 internal constant SHARE_SCALE = 1e12;

    /// @custom:storage-location erc7201:taskmarket.storage.FundingPool
    struct PoolStorage {
        address manager;
        IERC20 token;
        bool paused;
        uint256 totalLiabilities;
        mapping(bytes32 poolId => Pool) pools;
        mapping(bytes32 poolId => mapping(address backer => Backing)) backings;
    }

    // keccak256(abi.encode(uint256(keccak256("taskmarket.storage.FundingPool")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION = 0xa08b399d68f3a5c8d78346200c6a0bee78cb47eab339a3e56e1e913b11e0f400;

    event PoolPauseChanged(bool paused);

    error NotOwner();
    error PoolInvalidManager();
    error PoolUnderfunded(uint256 balance, uint256 liabilities);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Sets the manager (the Diamond) and the token. Runs once, in the proxy's constructor
    ///         call. Reverts PoolInvalidToken unless `token_` is the Diamond's payment token.
    function initialize(address diamond, address token_) external initializer {
        if (diamond == address(0) || diamond.code.length == 0) revert PoolInvalidManager();
        if (token_ == address(0) || token_ != IDiamondForPool(diamond).usdcToken()) revert PoolInvalidToken();
        PoolStorage storage $ = _s();
        $.manager = diamond;
        $.token = IERC20(token_);
    }

    // -------------------------------------------------------------------------
    // Access
    // -------------------------------------------------------------------------

    modifier onlyManager() {
        if (msg.sender != _s().manager) revert NotManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner()) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (_s().paused) revert PoolPaused();
        _;
    }

    /// @notice The pool's owner: the Diamond's owner, read live.
    function owner() public view returns (address) {
        return IDiamondForPool(_s().manager).owner();
    }

    /// @inheritdoc IFundingPoolManager
    function manager() external view returns (address) {
        return _s().manager;
    }

    function token() external view returns (address) {
        return address(_s().token);
    }

    function paused() external view returns (bool) {
        return _s().paused;
    }

    function totalLiabilities() external view returns (uint256) {
        return _s().totalLiabilities;
    }

    function pause() external onlyOwner {
        _s().paused = true;
        emit PoolPauseChanged(true);
    }

    function unpause() external onlyOwner {
        _s().paused = false;
        emit PoolPauseChanged(false);
    }

    function _authorizeUpgrade(address) internal view override onlyOwner { }

    // -------------------------------------------------------------------------
    // Backers
    // -------------------------------------------------------------------------

    /// @inheritdoc ITMPFundingPool
    function fund(bytes32 poolId, uint256 amount, address onBehalfOf) external whenNotPaused {
        PoolStorage storage $ = _s();
        if (onBehalfOf == address(0)) onBehalfOf = msg.sender;
        _credit($, poolId, msg.sender, onBehalfOf, amount);
        $.token.safeTransferFrom(msg.sender, address(this), amount);
        _requireSolvent($);
    }

    /// @inheritdoc ITMPFundingPool
    function claim(bytes32 poolId, address backer) external whenNotPaused returns (uint256 amount) {
        PoolStorage storage $ = _s();
        Pool storage p = _get($, poolId);
        Backing storage b = $.backings[poolId][backer];
        amount = _claimable(p, b);
        if (amount == 0) revert NothingToClaim();
        b.claimed += amount;
        p.available -= amount;
        p.claimed += amount;
        $.totalLiabilities -= amount;
        $.token.safeTransfer(backer, amount);
        emit PoolClaimed(poolId, backer, amount);
        _requireSolvent($);
    }

    /// @inheritdoc ITMPFundingPool
    function getPool(bytes32 poolId) external view returns (PoolInfo memory info) {
        Pool storage p = _get(_s(), poolId);
        bool settled = !_isOpen(p);
        info = PoolInfo({
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

    /// @inheritdoc ITMPFundingPool
    function sharesOf(bytes32 poolId, address backer) external view returns (uint256) {
        PoolStorage storage $ = _s();
        return _sharesOf(_get($, poolId), $.backings[poolId][backer]);
    }

    /// @inheritdoc ITMPFundingPool
    function claimable(bytes32 poolId, address backer) external view returns (uint256) {
        PoolStorage storage $ = _s();
        return _claimable(_get($, poolId), $.backings[poolId][backer]);
    }

    // -------------------------------------------------------------------------
    // Manager
    // -------------------------------------------------------------------------

    /// @inheritdoc IFundingPoolManager
    function open(bytes32 poolId, address token_, bytes32 module, uint64 closesAt) external onlyManager {
        PoolStorage storage $ = _s();
        if (token_ != address($.token)) revert PoolInvalidToken();
        Pool storage p = $.pools[poolId];
        if (p.token != address(0)) revert PoolAlreadyExists();
        p.token = token_;
        p.module = module;
        p.closesAt = closesAt;
        emit PoolOpened(poolId, module, token_, closesAt);
    }

    /// @inheritdoc IFundingPoolManager
    function creditOpening(bytes32 poolId, address backer, uint256 amount) external onlyManager {
        PoolStorage storage $ = _s();
        _credit($, poolId, msg.sender, backer, amount);
        _requireSolvent($);
    }

    /// @inheritdoc IFundingPoolManager
    function creditFunding(bytes32 poolId, address funder, address backer, uint256 amount)
        external
        onlyManager
        whenNotPaused
    {
        PoolStorage storage $ = _s();
        _credit($, poolId, funder, backer, amount);
        _requireSolvent($);
    }

    /// @inheritdoc IFundingPoolManager
    function spend(bytes32 poolId, uint256 amount) external onlyManager {
        PoolStorage storage $ = _s();
        Pool storage p = _get($, poolId);
        if (!_isOpen(p)) revert PoolNotOpen();
        uint256 available = p.available;
        if (amount > available) revert PoolBalanceExceeded(available, amount);
        p.available = available - amount;
        p.outstanding += amount;
        $.totalLiabilities -= amount;
        $.token.safeTransfer(msg.sender, amount);
        emit PoolSpent(poolId, amount);
        _requireSolvent($);
    }

    /// @inheritdoc IFundingPoolManager
    function refund(bytes32 poolId, uint256 amount) external onlyManager {
        PoolStorage storage $ = _s();
        Pool storage p = _get($, poolId);
        p.available += amount;
        $.totalLiabilities += amount;
        emit PoolRefunded(poolId, amount);
        _requireSolvent($);
    }

    /// @inheritdoc IFundingPoolManager
    function finish(bytes32 poolId, uint256 amount) external onlyManager {
        Pool storage p = _get(_s(), poolId);
        uint256 outstanding = p.outstanding;
        uint256 applied = amount > outstanding ? outstanding : amount;
        p.outstanding = outstanding - applied;
        if (applied != amount) emit PoolLedgerMismatch(poolId, amount, applied);
    }

    /// @inheritdoc IFundingPoolManager
    function close(bytes32 poolId) external onlyManager {
        Pool storage p = _get(_s(), poolId);
        if (p.closed) revert PoolAlreadyClosed();
        p.closed = true;
        emit PoolClosed(poolId, p.available);
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// @dev Credits `amount` to `backer` as shares at the pool's value and books it. When the
    ///      value is zero while shares exist, every share is worth nothing, so the credit starts
    ///      the next share generation (totalShares restarts from zero and older backings count as
    ///      no shares). The caller makes sure the money is in the pool before the solvency check.
    function _credit(PoolStorage storage $, bytes32 poolId, address funder, address backer, uint256 amount) private {
        Pool storage p = _get($, poolId);
        if (amount == 0) revert PoolAmountZero();
        if (!_isOpen(p)) revert PoolNotOpen();
        // Shares held by the manager or the pool could be claimed into an address that cannot
        // return them to a backer.
        if (backer == $.manager || backer == address(this)) revert PoolInvalidBacker();
        uint256 supply = p.totalShares;
        uint256 value = p.available + p.outstanding;
        uint256 generation = p.generation;
        if (supply != 0 && value == 0) {
            supply = 0;
            p.generation = ++generation;
            emit PoolSharesReset(poolId, generation);
        }
        uint256 shares = supply == 0 ? amount * SHARE_SCALE : Math.mulDiv(amount, supply, value);
        if (shares == 0) revert PoolSharesZero();
        p.totalShares = supply + shares;
        p.funded += amount;
        p.available += amount;
        Backing storage b = $.backings[poolId][backer];
        if (b.generation != generation) {
            b.generation = generation;
            b.shares = 0;
            b.claimed = 0;
        }
        b.shares += shares;
        $.totalLiabilities += amount;
        emit PoolFunded(poolId, funder, backer, amount, shares);
    }

    function _requireSolvent(PoolStorage storage $) private view {
        uint256 balance = $.token.balanceOf(address(this));
        if (balance < $.totalLiabilities) revert PoolUnderfunded(balance, $.totalLiabilities);
    }

    function _get(PoolStorage storage $, bytes32 poolId) private view returns (Pool storage p) {
        p = $.pools[poolId];
        if (p.token == address(0)) revert PoolNotFound();
    }

    function _isOpen(Pool storage p) private view returns (bool) {
        return !p.closed && (p.closesAt == 0 || block.timestamp < p.closesAt);
    }

    function _sharesOf(Pool storage p, Backing storage b) private view returns (uint256) {
        return b.generation == p.generation ? b.shares : 0;
    }

    /// @dev Once settled, the pot potIn = available + claimed only grows, and shares are fixed, so
    ///      potIn * shares / totalShares never falls below what the backer claimed and entitlements
    ///      sum to at most potIn (rounding down).
    function _claimable(Pool storage p, Backing storage b) private view returns (uint256) {
        uint256 supply = p.totalShares;
        if (_isOpen(p) || supply == 0) return 0;
        uint256 shares = _sharesOf(p, b);
        if (shares == 0) return 0;
        return Math.mulDiv(p.available + p.claimed, shares, supply) - b.claimed;
    }

    function _s() private pure returns (PoolStorage storage $) {
        bytes32 location = STORAGE_LOCATION;
        assembly {
            $.slot := location
        }
    }
}
