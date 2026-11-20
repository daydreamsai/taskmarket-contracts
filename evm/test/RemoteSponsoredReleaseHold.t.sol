// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { RemoteSponsoredTaskHookV2 } from "../src/hooks/sponsored-task/RemoteSponsoredTaskHookV2.sol";
import { SponsoredTaskTerms } from "../src/hooks/sponsored-task/libraries/SponsoredTaskTerms.sol";
import { SponsoredSettledAwardsBase } from "./Rev030SponsoredTaskSettledAwards.t.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev Rev031 (Cyclops 4403): the keeper may not release a remote reservation while the task can
///      still be accepted, however long after expiry that is.
contract RemoteSponsoredReleaseHoldTest is SponsoredSettledAwardsBase {
    RemoteSponsoredTaskHookV2 internal hook;

    function setUp() public {
        _baseSetUp();
        address implementation = address(new RemoteSponsoredTaskHookV2(address(market)));
        hook = RemoteSponsoredTaskHookV2(
            address(
                new ERC1967Proxy(implementation, abi.encodeCall(RemoteSponsoredTaskHookV2.initialize, (address(this))))
            )
        );
    }

    function _request(bytes32 termsHash, uint64 nonce) internal view returns (bytes memory) {
        return hook.encodeHookData(
            RemoteSponsoredTaskHookV2.FundingRequest({
                remoteChainId: 46_630,
                vault: address(0x7A17),
                vaultId: keccak256("remote-vault"),
                token: address(0x70CE),
                grossAmount: GROSS,
                commitmentNonce: nonce,
                epoch: 1,
                feeBps: 0,
                feeRecipient: address(0),
                taskTermsHash: termsHash
            })
        );
    }

    function _bounty(uint64 nonce) internal returns (bytes32) {
        address[] memory hooks = _hooks(address(hook));
        return _create(hooks, _request(_termsHash(hooks), nonce));
    }

    function _claimTask() internal returns (bytes32) {
        address[] memory hooks = new address[](1);
        hooks[0] = address(hook);
        SponsoredTaskTerms.Terms memory t = SponsoredTaskTerms.Terms({
            reward: REWARD,
            duration: DURATION,
            mode: TMP_CLAIM,
            pitchDuration: 0,
            bidDuration: 0,
            auctionSubtype: bytes4(0),
            stakeRequired: false,
            stakeBps: 0,
            feeBps: 500,
            evaluator: address(0),
            evaluatorStake: 0,
            evaluatorFeeBps: 0,
            evaluationWindow: 0,
            appealWindow: 0,
            disputeResolver: address(0),
            contentHash: bytes32(0),
            contentURIHash: keccak256(bytes("")),
            tagsHash: keccak256(abi.encode(new bytes32[](0))),
            hooksHash: keccak256(abi.encode(hooks))
        });
        SponsoredTaskTerms.SettlementTerms memory settlement;
        bytes32 termsHash = keccak256(
            abi.encode(
                SponsoredTaskTerms.TERMS_HASH_TYPEHASH,
                keccak256(abi.encode(SponsoredTaskTerms.TASK_TERMS_TYPEHASH, t)),
                keccak256(abi.encode(SponsoredTaskTerms.SETTLEMENT_TERMS_TYPEHASH, settlement))
            )
        );
        bytes[] memory configs = new bytes[](1);
        configs[0] = _request(termsHash, 2);
        return abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        taskConfig(REWARD, DURATION, TMP_CLAIM),
                        ITMPCore.HookConfig({ contracts: hooks, data: abi.encode(configs) }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        noEvaluatorConfig(),
                        stakeTerms(false, 0)
                    )
                )
            ),
            (bytes32)
        );
    }

    function _expectHeld(bytes32 taskId) internal {
        vm.expectRevert(
            abi.encodeWithSelector(RemoteSponsoredTaskHookV2.ReleaseHeldForLiveSubmissions.selector, taskId)
        );
        hook.reservationReleaseAfter(taskId);
    }

    function test_BountyReleaseIsHeldWhileSubmissionsAreLive() public {
        bytes32 empty = _bounty(1);
        uint256 expiry = market.getTask(empty).expiryTime;
        assertEq(hook.reservationReleaseAfter(empty), expiry + 7 days, "no submissions: expiry plus 7 days");

        bytes32 taskId = _bounty(3);
        _submit(taskId, 1);
        vm.warp(expiry + 30 days);
        _expectHeld(taskId);

        _acceptOne(taskId);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
        assertEq(hook.reservationReleaseAfter(taskId), expiry + 7 days, "accepted: the settlement takes over");
    }

    function test_BountyHoldEndsWhenTheLapsedDecisionTimesOut() public {
        bytes32 taskId = _bounty(1);
        _submit(taskId, 2);
        uint256 expiry = market.getTask(taskId).expiryTime;
        vm.warp(expiry + 7 days);
        _expectHeld(taskId);

        vm.warp(expiry + 7 days + 1);
        market.requesterTimeout(taskId);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Expired));
        assertEq(uint8(hook.outcome(taskId).status), uint8(RemoteSponsoredTaskHookV2.HookStatus.ReleaseCommitted));
        assertEq(hook.reservationReleaseAfter(taskId), expiry + 7 days);
    }

    function test_ClaimReleaseIsHeldWhileADeliveryIsUndecided() public {
        bytes32 taskId = _claimTask();
        uint256 expiry = market.getTask(taskId).expiryTime;
        address worker = _w(0);
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        assertEq(hook.reservationReleaseAfter(taskId), expiry + 7 days, "claimed, nothing delivered");

        bytes32 work = keccak256("claim-work");
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, work)));
        vm.warp(expiry + 7 days);
        _expectHeld(taskId);
    }
}
