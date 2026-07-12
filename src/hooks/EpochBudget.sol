// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title EpochBudget
/// @notice Tracks per-epoch USD emission caps: global, per-worker, and per-requester.
///         Only the authorised hook contract may call mutating functions.
///
///         All caps and usage are denominated in USDC base units (6 decimals) — the
///         USD value of the reward, not the DREAMS token amount. This keeps caps
///         meaningful regardless of the DREAMS/USDC exchange rate.
///
///         Usage is tracked against a monotonic epoch index. When the epoch rolls,
///         all usage is considered reset without O(n) clears: each account's stored
///         (epoch, used) pair is treated as zero usage when its epoch != the current one.
contract EpochBudget is Ownable {
    struct Usage {
        uint64 epoch;
        uint192 used;
    }

    address public hook;

    uint256 public epochDuration;
    uint256 public globalCapUsd;
    uint256 public workerCapUsd;
    uint256 public requesterCapUsd;
    uint256 public maxUsdPerTask;

    uint64 public currentEpoch;
    uint256 public epochStart;

    Usage internal globalUsage;
    mapping(address => Usage) internal workerUsage;
    mapping(address => Usage) internal requesterUsage;

    event HookSet(address indexed hook);
    event EpochRolled(uint64 indexed newEpoch, uint256 startTime);
    event Consumed(address indexed requester, address indexed worker, uint256 amount);
    event Released(address indexed requester, address indexed worker, uint256 amount);

    error OnlyHook();
    error EpochDurationZero();
    error CapExceedsUint192();
    error GlobalCapExceeded(uint256 requested, uint256 remaining);
    error WorkerCapExceeded(address worker, uint256 requested, uint256 remaining);
    error RequesterCapExceeded(address requester, uint256 requested, uint256 remaining);
    error TaskCapExceeded(uint256 requested, uint256 cap);

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    constructor(
        uint256 _epochDuration,
        uint256 _globalCapUsd,
        uint256 _workerCapUsd,
        uint256 _requesterCapUsd,
        uint256 _maxUsdPerTask,
        address _owner
    ) Ownable(_owner) {
        if (_epochDuration == 0) revert EpochDurationZero();
        if (_globalCapUsd > type(uint192).max) revert CapExceedsUint192();
        if (_workerCapUsd > type(uint192).max) revert CapExceedsUint192();
        if (_requesterCapUsd > type(uint192).max) revert CapExceedsUint192();
        if (_maxUsdPerTask > type(uint192).max) revert CapExceedsUint192();
        epochDuration = _epochDuration;
        globalCapUsd = _globalCapUsd;
        workerCapUsd = _workerCapUsd;
        requesterCapUsd = _requesterCapUsd;
        maxUsdPerTask = _maxUsdPerTask;
        epochStart = block.timestamp;
        currentEpoch = 1;
    }

    function setHook(address _hook) external onlyOwner {
        hook = _hook;
        emit HookSet(_hook);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    /// @notice Effective epoch as of `block.timestamp` (does not mutate state).
    function _effectiveEpoch() internal view returns (uint64) {
        if (block.timestamp >= epochStart + epochDuration) {
            // How many full epochs have elapsed since epochStart
            uint256 elapsed = (block.timestamp - epochStart) / epochDuration;
            return uint64(currentEpoch + elapsed);
        }
        return currentEpoch;
    }

    function _usedIn(Usage storage u, uint64 epoch) internal view returns (uint256) {
        // slither-disable-next-line incorrect-equality
        return u.epoch == epoch ? uint256(u.used) : 0;
    }

    function globalUsed() external view returns (uint256) {
        return _usedIn(globalUsage, _effectiveEpoch());
    }

    function workerUsed(address worker) external view returns (uint256) {
        return _usedIn(workerUsage[worker], _effectiveEpoch());
    }

    function requesterUsed(address requester) external view returns (uint256) {
        return _usedIn(requesterUsage[requester], _effectiveEpoch());
    }

    /// @notice Remaining USD capacity for a requester/worker pair in the effective epoch.
    function remaining(address requester, address worker) external view returns (uint256) {
        uint64 epoch = _effectiveEpoch();
        uint256 globalRem = globalCapUsd - _min(globalCapUsd, _usedIn(globalUsage, epoch));
        uint256 workerRem = workerCapUsd - _min(workerCapUsd, _usedIn(workerUsage[worker], epoch));
        uint256 reqRem = requesterCapUsd - _min(requesterCapUsd, _usedIn(requesterUsage[requester], epoch));
        return _min(_min3(globalRem, workerRem, reqRem), maxUsdPerTask);
    }

    // ─── Mutations ────────────────────────────────────────────────────────────

    function _rollEpochIfStale() internal returns (uint64) {
        if (block.timestamp >= epochStart + epochDuration) {
            // slither-disable-next-line divide-before-multiply
            uint256 elapsed = (block.timestamp - epochStart) / epochDuration;
            currentEpoch = uint64(currentEpoch + elapsed);
            epochStart = epochStart + elapsed * epochDuration;
            emit EpochRolled(currentEpoch, epochStart);
        }
        return currentEpoch;
    }

    /// @notice Check USD capacity and consume budget. Reverts if any cap is exceeded.
    function checkAndConsume(address requester, address worker, uint256 amount) external onlyHook {
        uint64 epoch = _rollEpochIfStale();

        if (amount > maxUsdPerTask) revert TaskCapExceeded(amount, maxUsdPerTask);

        uint256 gUsed = _usedIn(globalUsage, epoch);
        uint256 globalRem = globalCapUsd - _min(globalCapUsd, gUsed);
        if (amount > globalRem) revert GlobalCapExceeded(amount, globalRem);

        uint256 wUsed = _usedIn(workerUsage[worker], epoch);
        uint256 workerRem = workerCapUsd - _min(workerCapUsd, wUsed);
        if (amount > workerRem) revert WorkerCapExceeded(worker, amount, workerRem);

        uint256 rUsed = _usedIn(requesterUsage[requester], epoch);
        uint256 reqRem = requesterCapUsd - _min(requesterCapUsd, rUsed);
        if (amount > reqRem) revert RequesterCapExceeded(requester, amount, reqRem);

        globalUsage = Usage(epoch, uint192(gUsed + amount));
        workerUsage[worker] = Usage(epoch, uint192(wUsed + amount));
        requesterUsage[requester] = Usage(epoch, uint192(rUsed + amount));
        emit Consumed(requester, worker, amount);
    }

    /// @notice Reverse previously consumed budget within the same epoch (cancel/expire/forfeit).
    ///         If the epoch has rolled since consumption, usage is already zero — no-op.
    function release(address requester, address worker, uint256 amount) external onlyHook {
        uint64 epoch = _rollEpochIfStale();
        bool anyDecremented = false;

        uint256 gUsed = _usedIn(globalUsage, epoch);
        if (gUsed >= amount) {
            globalUsage = Usage(epoch, uint192(gUsed - amount));
            anyDecremented = true;
        }

        uint256 wUsed = _usedIn(workerUsage[worker], epoch);
        if (wUsed >= amount) {
            workerUsage[worker] = Usage(epoch, uint192(wUsed - amount));
            anyDecremented = true;
        }

        uint256 rUsed = _usedIn(requesterUsage[requester], epoch);
        if (rUsed >= amount) {
            requesterUsage[requester] = Usage(epoch, uint192(rUsed - amount));
            anyDecremented = true;
        }

        if (anyDecremented) emit Released(requester, worker, amount);
    }

    // ─── Owner config ─────────────────────────────────────────────────────────

    function setGlobalCapUsd(uint256 _globalCapUsd) external onlyOwner {
        if (_globalCapUsd > type(uint192).max) revert CapExceedsUint192();
        globalCapUsd = _globalCapUsd;
    }

    function setWorkerCapUsd(uint256 _workerCapUsd) external onlyOwner {
        if (_workerCapUsd > type(uint192).max) revert CapExceedsUint192();
        workerCapUsd = _workerCapUsd;
    }

    function setRequesterCapUsd(uint256 _requesterCapUsd) external onlyOwner {
        if (_requesterCapUsd > type(uint192).max) revert CapExceedsUint192();
        requesterCapUsd = _requesterCapUsd;
    }

    function setMaxUsdPerTask(uint256 _maxUsdPerTask) external onlyOwner {
        if (_maxUsdPerTask > type(uint192).max) revert CapExceedsUint192();
        maxUsdPerTask = _maxUsdPerTask;
    }

    function setEpochDuration(uint256 _epochDuration) external onlyOwner {
        if (_epochDuration == 0) revert EpochDurationZero();
        epochDuration = _epochDuration;
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _min3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return a < b ? (a < c ? a : c) : (b < c ? b : c);
    }
}
