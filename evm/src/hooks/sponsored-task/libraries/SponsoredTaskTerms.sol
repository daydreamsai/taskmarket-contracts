// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SponsoredTaskTerms
/// @notice Canonical commitment to the Taskmarket terms a vault manager intended to create.
library SponsoredTaskTerms {
    bytes32 internal constant TASK_TERMS_TYPEHASH = keccak256(
        "SponsoredTaskTerms(uint256 reward,uint256 duration,bytes4 mode,uint256 pitchDuration,uint256 bidDuration,bytes4 auctionSubtype,bool stakeRequired,uint16 stakeBps,uint16 feeBps,address evaluator,uint256 evaluatorStake,uint16 evaluatorFeeBps,uint32 evaluationWindow,uint32 appealWindow,address disputeResolver,bytes32 contentHash,bytes32 contentURIHash,bytes32 tagsHash,bytes32 hooksHash)"
    );

    struct Terms {
        uint256 reward;
        uint256 duration;
        bytes4 mode;
        uint256 pitchDuration;
        uint256 bidDuration;
        bytes4 auctionSubtype;
        bool stakeRequired;
        uint16 stakeBps;
        uint16 feeBps;
        address evaluator;
        uint256 evaluatorStake;
        uint16 evaluatorFeeBps;
        uint32 evaluationWindow;
        uint32 appealWindow;
        address disputeResolver;
        bytes32 contentHash;
        bytes32 contentURIHash;
        bytes32 tagsHash;
        bytes32 hooksHash;
    }

    error InvalidTaskContext(bytes32 taskId);

    /// @dev No `hash(Terms memory)` function lives here. A call across this library's boundary
    ///      into a function that reads all 19 `Terms` fields to build one `abi.encode` -- however
    ///      trivial the function body -- tripped `forge coverage --ir-minimum`'s stack-too-deep
    ///      limit for every caller tried (a bare wrapper with no other code, `SponsoredTaskHook`'s
    ///      full hook dispatcher, this library's own test contract): confirmed by isolating the
    ///      two variants against solc directly, where swapping only the call-vs-inline boundary
    ///      was the entire difference between crashing and compiling clean. `SponsoredTaskHook`'s
    ///      `_currentTermsHash` and `test/SponsoredTaskTerms.t.sol`'s pinned vector check both
    ///      compute `keccak256(abi.encode(TASK_TERMS_TYPEHASH, terms))` inline instead --
    ///      `abi.encode` of a struct with no dynamic fields is byte-identical to `abi.encode` of
    ///      its fields in order, so this is the same commitment, not a different one.
}
