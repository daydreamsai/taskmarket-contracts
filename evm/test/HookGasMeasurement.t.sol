// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm, VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHookV2 } from "../src/interfaces/ITMPHookV2.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import {
    TMP_CLAIM,
    TMP_BOUNTY,
    TMP_PITCH,
    TMP_AUCTION,
    TMP_AUCTION_DUTCH,
    TMP_BENCHMARK
} from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { RewardVault } from "../src/hooks/RewardVault.sol";
import { EpochBudget } from "../src/hooks/EpochBudget.sol";
import { TaskTokenRewardHookV2 } from "../src/hooks/TaskTokenRewardHookV2.sol";
import { PayoutGateHook } from "../src/hooks/payout-gate/PayoutGateHook.sol";
import { ProofGateHook } from "../src/hooks/proof-gate/ProofGateHook.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTaskFactoryV2 } from "../src/hooks/sponsored-task/SponsoredTaskFactoryV2.sol";
import { SponsoredTasksVaultV2 } from "../src/hooks/sponsored-task/SponsoredTasksVaultV2.sol";
import { SponsoredTaskHookV2 } from "../src/hooks/sponsored-task/SponsoredTaskHookV2.sol";
import { RemoteSponsoredTaskHookV2 } from "../src/hooks/sponsored-task/RemoteSponsoredTaskHookV2.sol";
import { SponsoredTaskFeeConfig } from "./helpers/SponsoredTaskFeeConfig.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev Drives every callback the rev028 mainnet hooks declare through a real diamond, with only
///      successful calls, so the Foundry execution trace holds the gas the diamond pays for each one.
///      The hook under test carries a `GAS_*` label, which `tools/hook-gas/trace-gas.mjs` reads. The
///      tests assert nothing about hook behavior; the hooks' own suites do that.
abstract contract HookGasBase is DiamondTestHelper {
    ITMPDiamond internal market;
    ITMPHooksV2 internal v2;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(0xA0);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    address internal evaluator = address(0xE0);

    uint256 internal constant REWARD = 100e6;
    uint256 internal constant DURATION = 7 days;
    bytes32 internal constant WORK = keccak256("work");

    address[] private _watched;
    string[] private _watchedLabels;

    /// @dev Labels a hook so its frames are findable in the trace, and so the new storage slots its
    ///      callbacks create can be counted.
    function _watch(address hook, string memory label) internal {
        vm.label(hook, label);
        _watched.push(hook);
        _watchedLabels.push(label);
    }

    /// @dev Records state accesses for the whole test and, at its end, logs how many storage slots
    ///      went from zero to nonzero inside each successful callback frame. Tempo charges far more for
    ///      a new slot than Ethereum pricing does, and forge applies the Ethereum price.
    modifier recorded() {
        vm.startStateDiffRecording();
        _;
        _reportNewSlots();
    }

    function _reportNewSlots() private {
        Vm.AccountAccess[] memory a = vm.stopAndReturnStateDiff();
        for (uint256 i; i < a.length; ++i) {
            if (a[i].reverted || a[i].data.length < 4) continue;
            if (a[i].kind != VmSafe.AccountAccessKind.Call && a[i].kind != VmSafe.AccountAccessKind.StaticCall) {
                continue;
            }
            string memory label = _labelOf(a[i].account);
            string memory fn = _callbackName(bytes4(a[i].data));
            if (bytes(label).length == 0 || bytes(fn).length == 0) continue;
            uint256 slots = _newSlots(a[i]);
            for (uint256 j = i + 1; j < a.length && a[j].depth > a[i].depth; ++j) {
                if (!a[j].reverted) slots += _newSlots(a[j]);
            }
            console.log(string.concat("GASSLOTS ", label, " ", fn, " ", vm.toString(slots)));
        }
    }

    function _newSlots(Vm.AccountAccess memory access) private pure returns (uint256 n) {
        for (uint256 k; k < access.storageAccesses.length; ++k) {
            Vm.StorageAccess memory s = access.storageAccesses[k];
            if (s.isWrite && !s.reverted && s.previousValue == bytes32(0) && s.newValue != bytes32(0)) ++n;
        }
    }

    function _labelOf(address account) private view returns (string memory) {
        for (uint256 i; i < _watched.length; ++i) {
            if (_watched[i] == account) return _watchedLabels[i];
        }
        return "";
    }

    function _callbackName(bytes4 selector) private pure returns (string memory) {
        if (selector == ITMPHookV2.beforeCreate.selector) return "beforeCreate";
        if (selector == ITMPHookV2.beforeClaim.selector) return "beforeClaim";
        if (selector == ITMPHookV2.beforeSelectWorker.selector) return "beforeSelectWorker";
        if (selector == ITMPHookV2.beforeSubmitProof.selector) return "beforeSubmitProof";
        if (selector == ITMPHookV2.beforeAcceptAuction.selector) return "beforeAcceptAuction";
        if (selector == ITMPHookV2.beforeSubmitWork.selector) return "beforeSubmitWork";
        if (selector == ITMPHookV2.beforeEvaluate.selector) return "beforeEvaluate";
        if (selector == ITMPHookV2.beforeAccept.selector) return "beforeAccept";
        if (selector == ITMPHookV2.afterComplete.selector) return "afterComplete";
        if (selector == ITMPHookV2.afterCancel.selector) return "afterCancel";
        if (selector == ITMPHookV2.afterExpire.selector) return "afterExpire";
        if (selector == ITMPHookV2.afterForfeit.selector) return "afterForfeit";
        if (selector == ITMPHookV2.onCall.selector) return "onCall";
        return "";
    }

    function _baseSetUp() internal {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), address(0xFEE), 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        v2 = ITMPHooksV2(address(market));
        usdc.mint(address(forwarder), 10_000_000e6);
    }

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _one(address h) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = h;
    }

    function _cfg(bytes memory c) internal pure returns (bytes[] memory a) {
        a = new bytes[](1);
        a[0] = c;
    }

    function _createCalldata(
        bytes4 mode,
        uint256 duration,
        address[] memory hooks,
        bytes memory hookData,
        ITMPCore.TaskEvaluatorConfig memory evaluatorConfig
    ) internal view returns (bytes memory) {
        ITMPCore.TaskConfig memory cfg = mode == TMP_PITCH
            ? taskConfig(REWARD, duration, mode, 1 days, 0, bytes4(0))
            : mode == TMP_AUCTION
                ? taskConfig(REWARD, duration, mode, 0, 1 days, TMP_AUCTION_DUTCH)
                : taskConfig(REWARD, duration, mode);
        return abi.encodeCall(
            market.createTask,
            (
                cfg,
                ITMPCore.HookConfig({ contracts: hooks, data: hookData }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                evaluatorConfig,
                stakeTerms(false, 0)
            )
        );
    }

    function _create(
        bytes4 mode,
        uint256 duration,
        address[] memory hooks,
        bytes memory hookData,
        ITMPCore.TaskEvaluatorConfig memory evaluatorConfig
    ) internal returns (bytes32) {
        return abi.decode(
            _relay(
                requester,
                REWARD + evaluatorConfig.evaluatorStake,
                _createCalldata(mode, duration, hooks, hookData, evaluatorConfig)
            ),
            (bytes32)
        );
    }

    function _claim(bytes32 taskId) internal {
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
    }

    function _submit(bytes32 taskId) internal {
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
    }

    function _accept(bytes32 taskId) internal {
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));
    }

    /// @dev Eight workers each submit to a Bounty task and the requester accepts all of them at
    ///      equal shares: the most awards the Sponsored Task hooks commit.
    function _eightWinnersAccepted(bytes32 taskId) internal {
        uint256 n = 8;
        address[] memory winners = new address[](n);
        uint16[] memory shares = new uint16[](n);
        for (uint256 i; i < n; ++i) {
            winners[i] = address(uint160(0xC100 + i));
            shares[i] = 1250;
            _relay(winners[i], 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        }
        _relay(requester, 0, abi.encodeCall(market.acceptSubmissions, (taskId, winners, shares, new bytes32[](0), 0)));
    }

    function _claimSubmitAccept(bytes32 taskId) internal {
        _claim(taskId);
        _submit(taskId);
        _accept(taskId);
    }
}

contract HookGasPayoutGateTest is HookGasBase {
    PayoutGateHook internal gate;

    function setUp() public {
        _baseSetUp();
        gate = new PayoutGateHook(address(market));
        _watch(address(gate), "GAS_PAYOUT_GATE");
    }

    function _gated(bytes32 gatingTaskId, uint64 deadline) internal returns (bytes32) {
        return _create(
            TMP_CLAIM,
            DURATION,
            _one(address(gate)),
            abi.encode(_cfg(abi.encode(gatingTaskId, deadline, new bytes32[](0)))),
            noEvaluatorConfig()
        );
    }

    function _plain() internal returns (bytes32) {
        return _create(TMP_CLAIM, DURATION, new address[](0), "", noEvaluatorConfig());
    }

    // beforeCreate (gated, deadline only), beforeAccept (deadline open).
    function test_gasGatedDeadline() public recorded {
        bytes32 taskId = _gated(bytes32(0), uint64(block.timestamp + 1 hours));
        _claim(taskId);
        _submit(taskId);
        vm.warp(block.timestamp + 1 hours);
        _accept(taskId);
    }

    // beforeCreate (gated with a gating task set at creation), beforeAccept (opened by the gating task).
    function test_gasGatedByGatingTask() public recorded {
        bytes32 gating = _plain();
        bytes32 taskId = _gated(gating, uint64(block.timestamp + 30 days));
        _claimSubmitAccept(gating);
        _claim(taskId);
        _submit(taskId);
        _accept(taskId);
    }

    // beforeCreate (gating mode over one gated task), beforeAccept (a task with no gate of its own).
    function test_gasGatingModeOne() public recorded {
        bytes32 gated = _gated(bytes32(0), uint64(block.timestamp + 30 days));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = gated;
        bytes32 gating = _create(
            TMP_CLAIM,
            DURATION,
            _one(address(gate)),
            abi.encode(_cfg(abi.encode(bytes32(0), uint64(0), ids))),
            noEvaluatorConfig()
        );
        _claimSubmitAccept(gating);
    }

    // beforeCreate (gating mode at the 16-task limit).
    function test_gasGatingModeMax() public recorded {
        uint256 n = gate.MAX_GATES_PER_TASK();
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = _gated(bytes32(0), uint64(block.timestamp + 30 days));
        }
        _create(
            TMP_CLAIM,
            DURATION,
            _one(address(gate)),
            abi.encode(_cfg(abi.encode(bytes32(0), uint64(0), ids))),
            noEvaluatorConfig()
        );
    }

    // onCall: the requester links the gating task after creation.
    function test_gasOnCallLateLink() public recorded {
        bytes32 taskId = _gated(bytes32(0), uint64(block.timestamp + 30 days));
        bytes32 gating = _plain();
        _relay(requester, 0, abi.encodeCall(v2.callTaskHook, (taskId, address(gate), abi.encode(uint8(1), gating))));
    }
}

contract HookGasProofGateTest is HookGasBase {
    ProofGateHook internal gate;

    function setUp() public {
        _baseSetUp();
        gate = new ProofGateHook(address(market));
        _watch(address(gate), "GAS_PROOF_GATE");
    }

    function _benchmark(address[] memory allowed, bool encodeEmpty) internal returns (bytes32) {
        bytes memory config = encodeEmpty ? bytes("") : abi.encode(allowed);
        return _create(TMP_BENCHMARK, DURATION, _one(address(gate)), abi.encode(_cfg(config)), noEvaluatorConfig());
    }

    function _submitProof(bytes32 taskId, bytes32 proofHash) internal {
        _relay(worker, 0, abi.encodeCall(market.submitProof, (taskId, proofHash, keccak256("eval"), 9500)));
    }

    // beforeCreate with an empty configuration.
    function test_gasCreateEmpty() public recorded {
        _benchmark(new address[](0), true);
    }

    // beforeCreate with one allowed worker, beforeSubmitProof for that worker.
    function test_gasCreateOneAndSubmitProof() public recorded {
        address[] memory allowed = new address[](1);
        allowed[0] = worker;
        bytes32 taskId = _benchmark(allowed, false);
        _submitProof(taskId, keccak256("proof-1"));
        _submitProof(taskId, keccak256("proof-2"));
    }

    // beforeCreate with the largest allowlist that fits the diamond's default 1,000,000 gas budget
    // for the callback (the hook's own limit of 64 does not), beforeSubmitProof with that allowlist.
    function test_gasCreateMaxAndSubmitProof() public recorded {
        uint256 n = 40;
        address[] memory allowed = new address[](n);
        for (uint256 i; i < n; ++i) {
            allowed[i] = address(uint160(0x1000 + i));
        }
        allowed[n - 1] = worker;
        bytes32 taskId = _benchmark(allowed, false);
        _submitProof(taskId, keccak256("proof-max"));
    }
}

contract HookGasTaskTokenRewardTest is HookGasBase {
    TaskTokenRewardHookV2 internal hook;
    MockUSDC internal dreams;

    function setUp() public {
        _baseSetUp();
        dreams = new MockUSDC();
        vm.startPrank(owner);
        RewardVault vault = new RewardVault(address(dreams), owner);
        EpochBudget budget = new EpochBudget(7 days, 1_000_000e6, 100_000e6, 100_000e6, 10_000e6, owner);
        dreams.mint(owner, 100_000e18);
        dreams.transfer(address(vault), 100_000e18);
        bytes memory init = abi.encodeCall(
            TaskTokenRewardHookV2.initialize,
            (
                address(vault),
                address(budget),
                address(market),
                18,
                1e18,
                1000,
                address(dreams),
                8000,
                address(0xBEEF),
                owner
            )
        );
        hook = TaskTokenRewardHookV2(address(new ERC1967Proxy(address(new TaskTokenRewardHookV2()), init)));
        vault.setHook(address(hook));
        budget.setHook(address(hook));
        hook.setRamp(
            [uint40(1), uint40(2), uint40(3)], [uint16(10_000), uint16(10_000), uint16(10_000), uint16(10_000)]
        );
        vm.stopPrank();
        _watch(address(hook), "GAS_TASK_TOKEN_REWARD");
    }

    function _make(bytes4 mode, uint256 duration) internal returns (bytes32) {
        return _create(mode, duration, _one(address(hook)), "", noEvaluatorConfig());
    }

    // beforeCreate, beforeClaim, beforeSubmitWork, beforeAccept, afterComplete on a Claim task.
    function test_gasClaimLifecycle() public recorded {
        _claimSubmitAccept(_make(TMP_CLAIM, 3 days));
    }

    // The same callbacks on a Bounty task, where the bonus is priced at completion.
    function test_gasBountyLifecycle() public recorded {
        bytes32 taskId = _make(TMP_BOUNTY, 3 days);
        _submit(taskId);
        _accept(taskId);
    }

    // beforeAccept and afterComplete on a Bounty task with eight winners.
    function test_gasBountyEightWinners() public recorded {
        _eightWinnersAccepted(_make(TMP_BOUNTY, 3 days));
    }

    // beforeSelectWorker on a Pitch task.
    function test_gasPitchSelectWorker() public recorded {
        bytes32 taskId = _make(TMP_PITCH, 3 days);
        _relay(worker, 0, abi.encodeCall(market.submitPitch, (taskId, keccak256("pitch"))));
        _relay(requester, 0, abi.encodeCall(market.selectWorker, (taskId, worker)));
        _submit(taskId);
        _accept(taskId);
    }

    // beforeAcceptAuction on a Dutch auction task.
    function test_gasAuctionAccept() public recorded {
        bytes32 taskId = _make(TMP_AUCTION, 3 days);
        _relay(worker, 0, abi.encodeCall(market.acceptAuction, (taskId, REWARD)));
        _submit(taskId);
        _accept(taskId);
    }

    // afterCancel on a claimed-free task.
    function test_gasCancel() public recorded {
        bytes32 taskId = _make(TMP_CLAIM, 3 days);
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
    }

    // afterExpire on a claimed task that ran out of time.
    function test_gasExpire() public recorded {
        bytes32 taskId = _make(TMP_CLAIM, 1 days);
        _claim(taskId);
        vm.warp(block.timestamp + 2 days);
        market.refundExpired(taskId, 0);
    }

    // afterForfeit on a claimed task whose worker missed the deadline.
    function test_gasForfeit() public recorded {
        bytes32 taskId = _make(TMP_CLAIM, 1 days);
        _claim(taskId);
        vm.warp(block.timestamp + 2 days);
        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
    }
}

/// @dev Sponsored Task hooks bind a task to its terms hash, which only the diamond's stored task
///      can produce. A first create with a placeholder hash is rejected by the hook with the
///      expected hash in its error; that rejected call is rolled back and its frames are not
///      measured. The real create then carries the hash.
abstract contract HookGasSponsoredFlows is HookGasBase {
    uint16 internal constant FEE_BPS = 50;
    address internal constant FEE_RECIPIENT = address(0xFEE1);
    uint256 internal constant GROSS = 10_000;

    function _hookAddress() internal view virtual returns (address);

    function _hookData(bytes32 termsHash) internal virtual returns (bytes memory);

    function _evaluatorConfig() internal view returns (ITMPCore.TaskEvaluatorConfig memory) {
        return ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: 0,
            evaluatorFeeBps: 0,
            evaluationWindow: 2 days,
            appealWindow: 1 days,
            disputeResolver: address(0)
        });
    }

    function _probeTermsHash(
        bytes4 mode,
        uint256 duration,
        address[] memory hooks,
        ITMPCore.TaskEvaluatorConfig memory evaluatorConfig
    ) internal returns (bytes32 actual) {
        bytes memory data = _createCalldata(
            mode, duration, hooks, abi.encode(_cfg(_hookData(bytes32(uint256(1))))), evaluatorConfig
        );
        (bool ok, bytes memory ret) =
            address(forwarder).call(abi.encodeCall(forwarder.relay, (address(market), requester, REWARD, data)));
        require(!ok, "probe create did not revert");
        bytes4 selector = SponsoredTaskHookV2.TaskTermsMismatch.selector;
        for (uint256 i; i + 68 <= ret.length; ++i) {
            if (
                ret[i] == selector[0] && ret[i + 1] == selector[1] && ret[i + 2] == selector[2]
                    && ret[i + 3] == selector[3]
            ) {
                assembly ("memory-safe") {
                    actual := mload(add(add(ret, 68), i))
                }
                return actual;
            }
        }
        revert("terms hash not found in revert data");
    }

    function _createSponsored(bytes4 mode, uint256 duration, ITMPCore.TaskEvaluatorConfig memory evaluatorConfig)
        internal
        returns (bytes32)
    {
        address[] memory hooks = _one(_hookAddress());
        bytes32 termsHash = _probeTermsHash(mode, duration, hooks, evaluatorConfig);
        return _create(mode, duration, hooks, abi.encode(_cfg(_hookData(termsHash))), evaluatorConfig);
    }

    // beforeCreate, beforeAccept, afterComplete: a Claim task accepted by its requester.
    function test_gasClaimAccepted() public recorded {
        bytes32 taskId = _createSponsored(TMP_CLAIM, 3 days, noEvaluatorConfig());
        _claimSubmitAccept(taskId);
    }

    // beforeCreate, beforeAccept, afterComplete: a Bounty task accepted by its requester.
    function test_gasBountyAccepted() public recorded {
        bytes32 taskId = _createSponsored(TMP_BOUNTY, 3 days, noEvaluatorConfig());
        _submit(taskId);
        _accept(taskId);
    }

    // beforeAccept and afterComplete with the most awards the hook commits.
    function test_gasBountyEightWinners() public recorded {
        _eightWinnersAccepted(_createSponsored(TMP_BOUNTY, 3 days, noEvaluatorConfig()));
    }

    // beforeEvaluate, then beforeAccept and afterComplete when the verdict is finalized.
    function test_gasEvaluatedAndFinalized() public recorded {
        bytes32 taskId = _createSponsored(TMP_CLAIM, 7 days, _evaluatorConfig());
        _claim(taskId);
        _submit(taskId);
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: REWARD, rank: 1 });
        _relay(
            evaluator,
            0,
            abi.encodeCall(market.evaluate, (taskId, ITMPCore.VerdictType.APPROVE, 950, 1000, bytes32(0), awards))
        );
        vm.warp(block.timestamp + 1 days + 1);
        market.finalizeVerdict(taskId);
    }

    // afterCancel.
    function test_gasCancel() public recorded {
        bytes32 taskId = _createSponsored(TMP_CLAIM, 3 days, noEvaluatorConfig());
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
    }

    // afterExpire.
    function test_gasExpire() public recorded {
        bytes32 taskId = _createSponsored(TMP_CLAIM, 1 days, noEvaluatorConfig());
        vm.warp(block.timestamp + 2 days);
        market.refundExpired(taskId, 0);
    }

    // afterForfeit.
    function test_gasForfeit() public recorded {
        bytes32 taskId = _createSponsored(TMP_CLAIM, 1 days, noEvaluatorConfig());
        _claim(taskId);
        vm.warp(block.timestamp + 2 days);
        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
    }
}

contract HookGasSponsoredTaskTest is HookGasSponsoredFlows {
    SponsoredTaskHookV2 internal hook;
    SponsoredTasksVaultV2 internal vault;
    MockERC20 internal projectToken;

    function setUp() public {
        _baseSetUp();
        projectToken = new MockERC20("Project", "PROJECT", 18, address(this));
        SponsoredTaskFeePolicy feePolicy = new SponsoredTaskFeePolicy(address(this), FEE_BPS, FEE_RECIPIENT);
        SponsoredTaskRegistry registry = new SponsoredTaskRegistry(address(this));
        address implementation = address(new SponsoredTaskHookV2(address(market), IERC20(address(usdc)), registry));
        hook = SponsoredTaskHookV2(
            address(new ERC1967Proxy(implementation, abi.encodeCall(SponsoredTaskHookV2.initialize, (address(this)))))
        );
        SponsoredTaskFactoryV2 factory = new SponsoredTaskFactoryV2(
            address(hook), address(feePolicy), registry, SponsoredTaskFeeConfig.none(IERC20(address(usdc)))
        );
        registry.setFactory(address(factory), true);
        (address vaultAddress,) = factory.createVault(address(projectToken), address(this), keccak256("gas"));
        vault = SponsoredTasksVaultV2(vaultAddress);
        vault.configureManager(requester, GROSS * 100, true);
        projectToken.mint(address(this), GROSS * 100);
        projectToken.approve(address(vault), type(uint256).max);
        vault.fund(GROSS * 100);
        _watch(address(hook), "GAS_SPONSORED_V2");
    }

    function _hookAddress() internal view override returns (address) {
        return address(hook);
    }

    function _hookData(bytes32 termsHash) internal view override returns (bytes memory) {
        return hook.encodeHookData(
            SponsoredTaskHookV2.FundingRequest({
                route: 0,
                vault: address(vault),
                vaultId: vault.vaultId(),
                allocationId: bytes32(0),
                epoch: 1,
                feeBps: FEE_BPS,
                feeRecipient: FEE_RECIPIENT,
                grossAmount: GROSS,
                taskTermsHash: termsHash
            })
        );
    }
}

contract HookGasRemoteSponsoredTaskTest is HookGasSponsoredFlows {
    RemoteSponsoredTaskHookV2 internal hook;
    uint64 internal nonce;

    function setUp() public {
        _baseSetUp();
        address implementation = address(new RemoteSponsoredTaskHookV2(address(market)));
        hook = RemoteSponsoredTaskHookV2(
            address(
                new ERC1967Proxy(implementation, abi.encodeCall(RemoteSponsoredTaskHookV2.initialize, (address(this))))
            )
        );
        _watch(address(hook), "GAS_REMOTE_SPONSORED_V2");
    }

    function _hookAddress() internal view override returns (address) {
        return address(hook);
    }

    function _hookData(bytes32 termsHash) internal override returns (bytes memory) {
        return hook.encodeHookData(
            RemoteSponsoredTaskHookV2.FundingRequest({
                remoteChainId: 46_630,
                vault: address(0x5A17),
                vaultId: keccak256("remote-vault"),
                token: address(0x70CE),
                grossAmount: GROSS,
                commitmentNonce: ++nonce,
                epoch: 1,
                feeBps: FEE_BPS,
                feeRecipient: FEE_RECIPIENT,
                taskTermsHash: termsHash
            })
        );
    }
}
