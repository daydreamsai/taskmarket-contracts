// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibTaskMarket } from "../libraries/LibTaskMarket.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPHook } from "../interfaces/ITMPHook.sol";
import {
    TMP_AUCTION,
    TMP_AUCTION_DUTCH,
    TMP_AUCTION_ENGLISH,
    TMP_AUCTION_REVERSE_DUTCH,
    TMP_AUCTION_REVERSE_ENGLISH
} from "../interfaces/ITMPModes.sol";

/// @title AuctionFacet — bid submission, winner selection, and clock-price acceptance
contract AuctionFacet {
    bytes4 private constant AUCTION = TMP_AUCTION;
    bytes4 private constant AUCTION_DUTCH = TMP_AUCTION_DUTCH;
    bytes4 private constant AUCTION_ENGLISH = TMP_AUCTION_ENGLISH;
    bytes4 private constant AUCTION_REVERSE_DUTCH = TMP_AUCTION_REVERSE_DUTCH;
    bytes4 private constant AUCTION_REVERSE_ENGLISH = TMP_AUCTION_REVERSE_ENGLISH;

    uint256 private constant MAX_BIDS_PER_TASK = 500;

    /// @notice Submit a bid on an Auction mode task.
    ///         Valid for English and Reverse-English subtypes.
    ///         The worker is the authenticated actor (pgtrSender).
    /// @param taskId Task identifier
    /// @param price  Bid price in USDC base units (must be <= maxPrice)
    function submitBid(bytes32 taskId, uint256 price) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        address worker = LibTaskMarket._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        ITMPCore.TaskAuctionConfig storage auctionCfg = s.taskAuctionConfigs[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (task.mode != AUCTION) revert ITMPCore.NotAnAuctionTask();
        if (!(auctionCfg.auctionSubtype == AUCTION_ENGLISH || auctionCfg.auctionSubtype == AUCTION_REVERSE_ENGLISH)) {
            revert ITMPCore.NotABidAuction();
        }
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (block.timestamp >= auctionCfg.bidDeadline) revert ITMPCore.BidDeadlinePassed();
        if (price > auctionCfg.maxPrice) revert ITMPCore.BidExceedsMaxPrice();
        if (s.taskBids[taskId].length >= MAX_BIDS_PER_TASK) revert ITMPCore.BidLimitReached();

        if (s.taskBids[taskId].length == 0 || price < auctionCfg.lowestBidPrice) {
            auctionCfg.lowestBidPrice = price;
            auctionCfg.lowestBidder = worker;
        }

        s.taskBids[taskId].push(ITMPCore.Bid({ worker: worker, price: price }));

        emit ITMPCore.BidSubmitted(taskId, worker, price);
        LibTaskMarket._nonReentrantAfter(s);
    }

    /// @notice Select the lowest bidder after bid deadline.
    ///         O(1): submitBid maintains a running minimum.
    /// @param taskId Task identifier
    function selectLowestBidder(bytes32 taskId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        ITMPCore.Task storage task = s.tasks[taskId];
        ITMPCore.TaskAuctionConfig storage auctionCfg = s.taskAuctionConfigs[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (task.mode != AUCTION) revert ITMPCore.NotAnAuctionTask();
        if (!(auctionCfg.auctionSubtype == AUCTION_ENGLISH || auctionCfg.auctionSubtype == AUCTION_REVERSE_ENGLISH)) {
            revert ITMPCore.NotABidAuction();
        }
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();
        if (block.timestamp < auctionCfg.bidDeadline) revert ITMPCore.BidDeadlineNotPassed();
        if (auctionCfg.lowestBidder == address(0)) revert ITMPCore.NoBidsSubmitted();

        task.worker = auctionCfg.lowestBidder;
        task.stakeAmount = auctionCfg.lowestBidPrice;
        task.status = ITMPCore.TaskStatus.Claimed;

        LibTaskMarket._checkSelectWorkerHooks(taskId, auctionCfg.lowestBidder, s);

        emit ITMPCore.TaskWorkerSelected(taskId, auctionCfg.lowestBidder);
        LibTaskMarket._nonReentrantAfter(s);
    }

    /// @notice Directly award an open auction task to a worker at a given price.
    ///         Used by clock-based auction subtypes (Dutch, Reverse-Dutch).
    ///         The worker is the authenticated actor (pgtrSender).
    /// @param taskId Task identifier
    /// @param price  Accepted price in USDC base units (must be <= task maxPrice)
    function acceptAuction(bytes32 taskId, uint256 price) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        address worker = LibTaskMarket._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        ITMPCore.TaskAuctionConfig storage auctionCfg = s.taskAuctionConfigs[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (task.mode != AUCTION) revert ITMPCore.NotAnAuctionTask();
        if (!(auctionCfg.auctionSubtype == AUCTION_DUTCH || auctionCfg.auctionSubtype == AUCTION_REVERSE_DUTCH)) {
            revert ITMPCore.NotAClockPriceAuction();
        }
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();
        if (price > auctionCfg.maxPrice) revert ITMPCore.PriceExceedsMaxPrice();

        task.worker = worker;
        task.stakeAmount = price;
        task.status = ITMPCore.TaskStatus.Claimed;

        LibTaskMarket._checkSelectWorkerHooks(taskId, worker, s);

        emit ITMPCore.AuctionAccepted(taskId, worker, price);
        LibTaskMarket._nonReentrantAfter(s);
    }
}
