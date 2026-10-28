#![allow(clippy::result_large_err)]

mod common;

use anchor_lang::prelude::Pubkey;
use common::*;
use k256::ecdsa::SigningKey;
use sha3::{Digest, Keccak256};
use solana_keypair::Keypair;
use solana_signer::Signer;
use sponsored_tasks::error::SponsoredTasksError as E;
use sponsored_tasks::events::PayoutBound;
use sponsored_tasks::payout_binding_digest;
use sponsored_tasks::state::PayoutBinding;

fn keccak(parts: &[&[u8]]) -> [u8; 32] {
    let mut hasher = Keccak256::new();
    for part in parts {
        hasher.update(part);
    }
    hasher.finalize().into()
}

fn word(value: u64) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[24..].copy_from_slice(&value.to_be_bytes());
    w
}

/// The EIP-712 digest built here from the spec, independently of the program's own helper.
fn digest(chain_id: u64, agent: &[u8; 20], payout: &Pubkey, nonce: u64) -> [u8; 32] {
    let domain = keccak(&[
        &keccak(&[b"EIP712Domain(string name,string version,uint256 chainId,bytes32 salt)"]),
        &keccak(&[b"Taskmarket Sponsored Tasks"]),
        &keccak(&[b"1"]),
        &word(chain_id),
        sponsored_tasks::ID.as_ref(),
    ]);
    let mut agent_word = [0u8; 32];
    agent_word[12..].copy_from_slice(agent);
    let message = keccak(&[
        &keccak(&[b"PayoutBinding(address agent,bytes32 payout,uint64 nonce)"]),
        &agent_word,
        payout.as_ref(),
        &word(nonce),
    ]);
    keccak(&[b"\x19\x01", &domain, &message])
}

struct Agent {
    key: SigningKey,
    address: [u8; 20],
}

impl Agent {
    fn new() -> Self {
        let key = SigningKey::random(&mut k256::elliptic_curve::rand_core::OsRng);
        let point = key.verifying_key().to_encoded_point(false);
        let mut address = [0u8; 20];
        address.copy_from_slice(&keccak(&[&point.as_bytes()[1..]])[12..]);
        Agent { key, address }
    }

    /// `r || s || v` with `v` as 27 or 28, as an EVM wallet returns it.
    fn sign(&self, chain_id: u64, payout: &Pubkey, nonce: u64) -> [u8; 65] {
        let (sig, recovery) = self
            .key
            .sign_prehash_recoverable(&digest(chain_id, &self.address, payout, nonce))
            .unwrap();
        let mut out = [0u8; 65];
        out[..64].copy_from_slice(&sig.to_bytes());
        out[64] = 27 + recovery.to_byte();
        out
    }
}

fn bind(
    env: &mut Env,
    chain_id: u64,
    agent: [u8; 20],
    payout: Pubkey,
    nonce: u64,
    signature: [u8; 65],
) -> Result<(), litesvm::types::FailedTransactionMetadata> {
    let payer = env.payer.pubkey();
    env.send(
        &[bind_payout_ix(
            &payer, chain_id, agent, payout, nonce, signature,
        )],
        &[],
    )
}

fn hex<const N: usize>(s: &str) -> [u8; N] {
    let s = s.trim_start_matches("0x");
    let mut out = [0u8; N];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap();
    }
    out
}

// Produced by viem's `signTypedData` (the path the CLI and web app sign with) for the test-only
// key 0x11..11; see packages/contracts/docs/specs/sponsored-tasks/payout-binding.md.
const VIEM_AGENT: &str = "0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a";
const VIEM_DIGEST: &str = "0x6487768809e6bf617bfe502e362f8a0db51deee4171da691b3c8e0656f6bead7";
const VIEM_SIGNATURE: &str = "0xc34316633dae9bb4bb6bfb6041beea4144899cabe846c87d4230fcbd6611c34529b26459c488220b34abd0db636c1d3edb83f5596bc7e6451e1251a90ab727821b";

#[test]
fn digest_matches_viem_typed_data() {
    let agent: [u8; 20] = hex(VIEM_AGENT);
    let payout = Pubkey::new_from_array([0x44; 32]);
    let expected: [u8; 32] = hex(VIEM_DIGEST);
    assert_eq!(digest(TASK_CHAIN_ID, &agent, &payout, 1), expected);
    assert_eq!(
        payout_binding_digest(TASK_CHAIN_ID, &agent, &payout, 1),
        expected
    );
}

#[test]
fn bind_payout_accepts_a_viem_signature() {
    let mut env = Env::new();
    let agent: [u8; 20] = hex(VIEM_AGENT);
    let payout = Pubkey::new_from_array([0x44; 32]);
    bind(
        &mut env,
        TASK_CHAIN_ID,
        agent,
        payout,
        1,
        hex(VIEM_SIGNATURE),
    )
    .unwrap();

    let binding: PayoutBinding = env.account(&payout_pda(TASK_CHAIN_ID, &agent));
    assert_eq!(binding.task_chain_id, TASK_CHAIN_ID);
    assert_eq!(binding.agent, agent);
    assert_eq!(binding.payout, payout);
    assert_eq!(binding.nonce, 1);
    let events = env.events::<PayoutBound>();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].task_chain_id, TASK_CHAIN_ID);
    assert_eq!(events[0].agent, agent);
    assert_eq!(events[0].payout, payout);
    assert_eq!(events[0].nonce, 1);
}

#[test]
fn bind_payout_accepts_v_as_zero_or_one() {
    let mut env = Env::new();
    let agent = Agent::new();
    let payout = Pubkey::new_unique();
    let mut sig = agent.sign(TASK_CHAIN_ID, &payout, 0);
    sig[64] -= 27;
    bind(&mut env, TASK_CHAIN_ID, agent.address, payout, 0, sig).unwrap();
    let binding: PayoutBinding = env.account(&payout_pda(TASK_CHAIN_ID, &agent.address));
    assert_eq!(binding.payout, payout);
}

#[test]
fn rebind_with_a_higher_nonce_replaces_the_payout() {
    let mut env = Env::new();
    let agent = Agent::new();
    let first = Pubkey::new_unique();
    let second = Pubkey::new_unique();
    bind(
        &mut env,
        TASK_CHAIN_ID,
        agent.address,
        first,
        1,
        agent.sign(TASK_CHAIN_ID, &first, 1),
    )
    .unwrap();
    bind(
        &mut env,
        TASK_CHAIN_ID,
        agent.address,
        second,
        5,
        agent.sign(TASK_CHAIN_ID, &second, 5),
    )
    .unwrap();

    let binding: PayoutBinding = env.account(&payout_pda(TASK_CHAIN_ID, &agent.address));
    assert_eq!(binding.payout, second);
    assert_eq!(binding.nonce, 5);
    assert_eq!(env.events::<PayoutBound>()[0].payout, second);
}

#[test]
fn rebind_rejects_a_stale_nonce() {
    let mut env = Env::new();
    let agent = Agent::new();
    let bound = Pubkey::new_unique();
    let other = Pubkey::new_unique();
    bind(
        &mut env,
        TASK_CHAIN_ID,
        agent.address,
        bound,
        3,
        agent.sign(TASK_CHAIN_ID, &bound, 3),
    )
    .unwrap();

    // The same nonce: a replay of the current binding, or a second binding signed at that nonce.
    let replay = bind(
        &mut env,
        TASK_CHAIN_ID,
        agent.address,
        bound,
        3,
        agent.sign(TASK_CHAIN_ID, &bound, 3),
    );
    assert_error(replay, E::StalePayoutNonce);
    let same = bind(
        &mut env,
        TASK_CHAIN_ID,
        agent.address,
        other,
        3,
        agent.sign(TASK_CHAIN_ID, &other, 3),
    );
    assert_error(same, E::StalePayoutNonce);
    let lower = bind(
        &mut env,
        TASK_CHAIN_ID,
        agent.address,
        other,
        2,
        agent.sign(TASK_CHAIN_ID, &other, 2),
    );
    assert_error(lower, E::StalePayoutNonce);

    let binding: PayoutBinding = env.account(&payout_pda(TASK_CHAIN_ID, &agent.address));
    assert_eq!(binding.payout, bound);
    assert_eq!(binding.nonce, 3);
}

#[test]
fn bind_payout_rejects_a_signature_from_another_key() {
    let mut env = Env::new();
    let agent = Agent::new();
    let attacker = Agent::new();
    let payout = Pubkey::new_unique();
    let forged = bind(
        &mut env,
        TASK_CHAIN_ID,
        agent.address,
        payout,
        1,
        attacker.sign(TASK_CHAIN_ID, &payout, 1),
    );
    assert_error(forged, E::InvalidPayoutSignature);
    assert!(env
        .svm
        .get_account(&payout_pda(TASK_CHAIN_ID, &agent.address))
        .is_none());
}

#[test]
fn bind_payout_rejects_a_signature_over_other_fields() {
    let mut env = Env::new();
    let agent = Agent::new();
    let signed = Pubkey::new_unique();
    let other = Pubkey::new_unique();
    let sig = agent.sign(TASK_CHAIN_ID, &signed, 1);

    let payout = bind(&mut env, TASK_CHAIN_ID, agent.address, other, 1, sig);
    assert_error(payout, E::InvalidPayoutSignature);
    let nonce = bind(&mut env, TASK_CHAIN_ID, agent.address, signed, 2, sig);
    assert_error(nonce, E::InvalidPayoutSignature);
    // Signed for Base, submitted for Tempo: the domain's chainId differs.
    let chain = bind(&mut env, TEMPO_CHAIN_ID, agent.address, signed, 1, sig);
    assert_error(chain, E::InvalidPayoutSignature);
}

#[test]
fn bind_payout_rejects_a_malformed_signature() {
    let mut env = Env::new();
    let agent = Agent::new();
    let payout = Pubkey::new_unique();
    let mut bad_v = agent.sign(TASK_CHAIN_ID, &payout, 1);
    bad_v[64] = 29;
    assert_error(
        bind(&mut env, TASK_CHAIN_ID, agent.address, payout, 1, bad_v),
        E::InvalidPayoutSignature,
    );
    assert_error(
        bind(&mut env, TASK_CHAIN_ID, agent.address, payout, 1, [0u8; 65]),
        E::InvalidPayoutSignature,
    );
}

#[test]
fn bindings_are_per_chain_and_relayed_by_anyone_while_paused() {
    let mut env = Env::new();
    env.pause(true);
    let agent = Agent::new();
    let on_base = Pubkey::new_unique();
    let on_tempo = Pubkey::new_unique();

    let relayer = Keypair::new();
    env.svm.airdrop(&relayer.pubkey(), 1_000_000_000).unwrap();
    let ix = bind_payout_ix(
        &relayer.pubkey(),
        TASK_CHAIN_ID,
        agent.address,
        on_base,
        1,
        agent.sign(TASK_CHAIN_ID, &on_base, 1),
    );
    env.send(&[ix], &[&relayer]).unwrap();
    bind(
        &mut env,
        TEMPO_CHAIN_ID,
        agent.address,
        on_tempo,
        1,
        agent.sign(TEMPO_CHAIN_ID, &on_tempo, 1),
    )
    .unwrap();

    let base: PayoutBinding = env.account(&payout_pda(TASK_CHAIN_ID, &agent.address));
    let tempo: PayoutBinding = env.account(&payout_pda(TEMPO_CHAIN_ID, &agent.address));
    assert_eq!(base.payout, on_base);
    assert_eq!(tempo.payout, on_tempo);
    assert_eq!(tempo.task_chain_id, TEMPO_CHAIN_ID);
}
