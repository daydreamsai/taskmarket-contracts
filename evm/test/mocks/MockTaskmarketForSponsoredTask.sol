// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../../src/interfaces/ITMPCore.sol";

/// @dev A minimal market the Sponsored Task V2 hook tests prime directly: task, metadata, evaluator,
///      verdict and terms are plain setters, and the views the hooks read answer from them. The
///      V2 callers live in the suites that extend it.
contract MockTaskmarketForSponsoredTask {
    mapping(bytes32 => ITMPCore.Task) private _tasks;
    mapping(bytes32 => ITMPCore.TaskMetadata) private _metadata;
    mapping(bytes32 => ITMPCore.TaskEvaluatorConfig) private _evaluators;
    mapping(bytes32 => ITMPCore.TaskAuctionConfig) private _auctions;
    mapping(bytes32 => ITMPCore.TaskPitchConfig) private _pitches;
    mapping(bytes32 => ITMPCore.Verdict) private _verdicts;
    mapping(bytes32 => address[]) private _hooks;
    mapping(bytes32 => bytes32[]) private _tags;
    mapping(bytes32 => address) private _paymentTokens;
    mapping(bytes32 => ITMPCore.TaskTerms) private _terms;
    mapping(bytes32 => address) private _creators;

    /// @dev Models a project task created by an operator: `taskCreatedBy` reports `creator` while
    ///      the task's requester stays whoever `primeTask` named.
    function setCreator(bytes32 taskId, address creator) external {
        _creators[taskId] = creator;
    }

    function taskCreatedBy(bytes32 taskId) external view returns (address) {
        return _creators[taskId];
    }

    function setTaskTerms(bytes32 taskId, ITMPCore.TaskTerms calldata terms) external {
        _terms[taskId] = terms;
    }

    function getTaskTerms(bytes32 taskId) external view returns (ITMPCore.TaskTerms memory) {
        return _terms[taskId];
    }

    function primeTask(
        bytes32 taskId,
        address requester,
        address paymentToken,
        uint256 reward,
        bytes4 mode,
        address hook
    ) external {
        _tasks[taskId] = ITMPCore.Task({
            id: taskId,
            requester: requester,
            worker: address(0),
            status: ITMPCore.TaskStatus.Open,
            mode: mode,
            reward: reward,
            expiryTime: block.timestamp + 3 days,
            stakeAmount: 0,
            feeBps: 750,
            deliverable: bytes32(0),
            rating: 0,
            hookContract: hook,
            stakeRequired: false,
            stakeBps: 0
        });
        _metadata[taskId] = ITMPCore.TaskMetadata({
            createdAt: block.timestamp,
            claimedAt: 0,
            contentHash: keccak256("content"),
            contentURI: "ipfs://sponsored-task"
        });
        _paymentTokens[taskId] = paymentToken;
        _hooks[taskId].push(hook);
        _tags[taskId].push(keccak256("sponsored-task"));
    }

    /// @dev The backend creates tasks with no on-chain content; vector tests prime that shape.
    function setContent(bytes32 taskId, bytes32 contentHash, string calldata contentURI) external {
        _metadata[taskId].contentHash = contentHash;
        _metadata[taskId].contentURI = contentURI;
    }

    function setStatus(bytes32 taskId, ITMPCore.TaskStatus status) external {
        _tasks[taskId].status = status;
    }

    function setReward(bytes32 taskId, uint256 reward) external {
        _tasks[taskId].reward = reward;
    }

    function setWorkerAndStake(bytes32 taskId, address worker, uint256 stakeAmount, bytes32 deliverable) external {
        _tasks[taskId].worker = worker;
        _tasks[taskId].stakeAmount = stakeAmount;
        _tasks[taskId].deliverable = deliverable;
    }

    function setEvaluator(bytes32 taskId, ITMPCore.TaskEvaluatorConfig calldata config) external {
        _evaluators[taskId] = config;
    }

    function setVerdict(bytes32 taskId, ITMPCore.Verdict calldata verdict) external {
        delete _verdicts[taskId];
        ITMPCore.Verdict storage stored = _verdicts[taskId];
        stored.issued = verdict.issued;
        stored.verdictType = verdict.verdictType;
        stored.score = verdict.score;
        stored.confidence = verdict.confidence;
        stored.evidenceHash = verdict.evidenceHash;
        for (uint256 i; i < verdict.awards.length; ++i) {
            stored.awards.push(verdict.awards[i]);
        }
    }

    function getTask(bytes32 taskId) external view returns (ITMPCore.Task memory) {
        return _tasks[taskId];
    }

    function getTaskContext(bytes32 taskId) external view returns (ITMPCore.TaskContext memory) {
        return _context(taskId);
    }

    function getTaskMetadata(bytes32 taskId) external view returns (ITMPCore.TaskMetadata memory) {
        return _metadata[taskId];
    }

    function getTaskEvaluatorConfig(bytes32 taskId) external view returns (ITMPCore.TaskEvaluatorConfig memory) {
        return _evaluators[taskId];
    }

    function getTaskAuctionConfig(bytes32 taskId) external view returns (ITMPCore.TaskAuctionConfig memory) {
        return _auctions[taskId];
    }

    function getTaskPitchConfig(bytes32 taskId) external view returns (ITMPCore.TaskPitchConfig memory) {
        return _pitches[taskId];
    }

    function getTaskHooks(bytes32 taskId) external view returns (address[] memory) {
        return _hooks[taskId];
    }

    function getTaskVerdict(bytes32 taskId) external view returns (ITMPCore.Verdict memory) {
        return _verdicts[taskId];
    }

    function _context(bytes32 taskId) private view returns (ITMPCore.TaskContext memory context) {
        ITMPCore.Task storage task = _tasks[taskId];
        ITMPCore.TaskEvaluatorConfig storage evaluator = _evaluators[taskId];
        context.taskId = taskId;
        context.requester = task.requester;
        context.evaluator = evaluator.evaluator;
        context.paymentToken = _paymentTokens[taskId];
        context.reward = task.reward;
        context.evaluatorStake = evaluator.evaluatorStake;
        context.evaluatorFeeBps = evaluator.evaluatorFeeBps;
        context.submissionDeadline = task.expiryTime;
        context.evaluationWindow = evaluator.evaluationWindow;
        context.appealWindow = evaluator.appealWindow;
        context.disputeResolver = evaluator.disputeResolver;
        context.currentState = task.status;
        context.mode = task.mode;
        context.tags = _tags[taskId];
    }
}
