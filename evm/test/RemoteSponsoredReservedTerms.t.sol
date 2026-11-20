// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { ITMPReservation } from "../src/interfaces/ITMPReservation.sol";
import { TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { RemoteSponsoredTaskHookV2 } from "../src/hooks/sponsored-task/RemoteSponsoredTaskHookV2.sol";
import { SponsoredTaskTerms } from "../src/hooks/sponsored-task/libraries/SponsoredTaskTerms.sol";
import { SponsoredSettledAwardsBase } from "./Rev030SponsoredTaskSettledAwards.t.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev Rev031 (Cyclops 4445): the remote hook's terms hash commits a reserved worker too.
contract RemoteSponsoredReservedTermsTest is SponsoredSettledAwardsBase {
    RemoteSponsoredTaskHookV2 internal hook;
    address internal reserved = address(0xC0);

    function setUp() public {
        _baseSetUp();
        address implementation = address(new RemoteSponsoredTaskHookV2(address(market)));
        hook = RemoteSponsoredTaskHookV2(
            address(
                new ERC1967Proxy(implementation, abi.encodeCall(RemoteSponsoredTaskHookV2.initialize, (address(this))))
            )
        );
    }

    function _hashes() internal view returns (bytes32 withoutWorker, bytes32 withWorker) {
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
        bytes32 core = keccak256(abi.encode(SponsoredTaskTerms.TASK_TERMS_TYPEHASH, t));
        bytes32 settle = keccak256(abi.encode(SponsoredTaskTerms.SETTLEMENT_TERMS_TYPEHASH, settlement));
        withoutWorker = keccak256(abi.encode(SponsoredTaskTerms.TERMS_HASH_TYPEHASH, core, settle));
        withWorker = keccak256(abi.encode(SponsoredTaskTerms.RESERVED_TERMS_HASH_TYPEHASH, withoutWorker, reserved));
    }

    function _call(bytes32 termsHash, uint64 nonce) internal view returns (bytes memory) {
        address[] memory hooks = new address[](1);
        hooks[0] = address(hook);
        bytes[] memory configs = new bytes[](1);
        configs[0] = hook.encodeHookData(
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
        return abi.encodeCall(
            ITMPReservation.createTask,
            (
                taskConfig(REWARD, DURATION, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: hooks, data: abi.encode(configs) }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                stakeTerms(false, 0),
                reserved
            )
        );
    }

    function test_Remote_ReservedWorkerIsPartOfTheTermsHash() public {
        (bytes32 withoutWorker, bytes32 withWorker) = _hashes();
        bytes memory unbound = _call(withoutWorker, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITMPHooksV2.HookRejected.selector,
                uint8(0),
                uint8(0),
                abi.encodeWithSelector(RemoteSponsoredTaskHookV2.TaskTermsMismatch.selector, withoutWorker, withWorker)
            )
        );
        _relay(requester, REWARD, unbound);

        bytes32 taskId = abi.decode(_relay(requester, REWARD, _call(withWorker, 1)), (bytes32));
        assertEq(hook.currentTaskTermsHash(taskId), withWorker, "the reservation's worker is committed");
        assertEq(uint8(hook.outcome(taskId).status), uint8(RemoteSponsoredTaskHookV2.HookStatus.Committed));
    }
}
