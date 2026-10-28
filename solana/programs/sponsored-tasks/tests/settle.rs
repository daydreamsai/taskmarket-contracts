mod common;

use anchor_lang::prelude::Pubkey;
use common::*;
use solana_keypair::Keypair;
use solana_signer::Signer;
use sponsored_tasks::error::SponsoredTasksError as E;
use sponsored_tasks::events::*;
use sponsored_tasks::state::{ReservationState, DEFAULT_CLAIM_DELAY_SECONDS};
use sponsored_tasks::{award_leaf, verify_award_proof, ID};

const ROOT: [u8; 32] = [7; 32];

fn settler(env: &Env) -> Keypair {
    env.settlers[0].insecure_clone()
}

#[test]
fn settle_installs_root_carves_fee_and_releases_the_rest() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    let s = settler(&env);
    // 750 bps of a 400 gross is at most 30.
    let terms = SettleTerms::awards(ROOT, 3, 370, 30);
    env.send(&[f.settle_ix(&[&s], r, terms)], &[&s]).unwrap();

    let reservation = env.reservation(&r);
    assert_eq!(reservation.state, ReservationState::Settled);
    assert_eq!(reservation.root, ROOT);
    assert_eq!(reservation.leaf_count, 3);
    assert_eq!(
        (reservation.settled_total, reservation.fee_total),
        (370, 30)
    );

    let vault = env.vault(&f.vault);
    assert_eq!(vault.total_reserved, 0);
    assert_eq!(vault.total_settled, 400);
    assert_eq!(vault.claimable(), 400);
    assert_eq!(vault.available(), 600);
    let m = vault.managers[0];
    assert_eq!((m.reserved, m.spent), (0, 400));

    let events = env.events::<SettlementInstalled>();
    assert_eq!(events.len(), 1);
    let e = &events[0];
    assert_eq!((e.vault, e.reservation), (f.vault, r));
    assert_eq!(
        (e.base_chain_id, e.base_task_id),
        (BASE_CHAIN_ID, task_id(1))
    );
    assert_eq!((e.epoch, e.root, e.leaf_count), (1, ROOT, 3));
    assert_eq!(
        (
            e.distributed_gross,
            e.settled_total,
            e.fee_total,
            e.released_amount
        ),
        (400, 370, 30, 0)
    );
}

#[test]
fn settle_below_reservation_returns_the_remainder() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    let s = settler(&env);
    env.send(
        &[f.settle_ix(&[&s], r, SettleTerms::awards(ROOT, 1, 250, 0))],
        &[&s],
    )
    .unwrap();
    let vault = env.vault(&f.vault);
    assert_eq!(vault.total_settled, 250);
    assert_eq!(vault.available(), 750);
    let m = vault.managers[0];
    assert_eq!((m.reserved, m.spent), (0, 250));
    assert_eq!(env.events::<SettlementInstalled>()[0].released_amount, 150);
}

#[test]
fn settle_with_no_awards_releases_everything() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    let s = settler(&env);
    env.send(
        &[f.settle_ix(&[&s], r, SettleTerms::awards([0; 32], 0, 0, 0))],
        &[&s],
    )
    .unwrap();
    assert_eq!(env.reservation(&r).state, ReservationState::Settled);
    let vault = env.vault(&f.vault);
    assert_eq!(vault.available(), 1_000);
    assert_eq!(env.events::<SettlementInstalled>()[0].released_amount, 400);
}

#[test]
fn settle_rejects_wrong_signer() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    let intruder = Keypair::new();
    assert_error(
        env.send(
            &[f.settle_ix(&[&intruder], r, SettleTerms::awards(ROOT, 1, 400, 0))],
            &[&intruder],
        ),
        E::SettlerThresholdNotMet,
    );
}

#[test]
fn settle_enforces_settler_threshold() {
    // A 1-of-1 set reserves, then the admin raises it to 2-of-3 before the settle.
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    let admin = env.admin.insecure_clone();
    let set: Vec<Pubkey> = env.settlers.iter().map(|k| k.pubkey()).collect();
    env.send(&[set_settlers_ix(&admin.pubkey(), set, 2)], &[&admin])
        .unwrap();
    let a = env.settlers[0].insecure_clone();
    let b = env.settlers[1].insecure_clone();
    let terms = SettleTerms::awards(ROOT, 1, 400, 0);
    assert_error(
        env.send(&[f.settle_ix(&[&a], r, terms)], &[&a]),
        E::SettlerThresholdNotMet,
    );
    // The same settler twice still counts once.
    assert_error(
        env.send(&[f.settle_ix(&[&a, &a], r, terms)], &[&a]),
        E::SettlerThresholdNotMet,
    );
    env.send(&[f.settle_ix(&[&a, &b], r, terms)], &[&a, &b])
        .unwrap();
}

#[test]
fn rotating_a_one_of_one_settler_moves_settle_to_the_new_key() {
    // The launch shape: one backend-held settler, threshold 1. A reservation made by the old key
    // is in flight when the admin rotates, as it would be during a key compromise.
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    let admin = env.admin.insecure_clone();
    let old = env.settlers[0].insecure_clone();
    let new = env.settlers[1].insecure_clone();
    env.send(
        &[set_settlers_ix(&admin.pubkey(), vec![new.pubkey()], 1)],
        &[&admin],
    )
    .unwrap();
    let config = env.config();
    assert_eq!(config.settlers, vec![new.pubkey()]);
    assert_eq!(config.threshold, 1);
    assert_eq!(env.events::<SettlersChanged>()[0].threshold, 1);

    let terms = SettleTerms::awards(ROOT, 1, 400, 0);
    assert_error(
        env.send(&[f.settle_ix(&[&old], r, terms)], &[&old]),
        E::SettlerThresholdNotMet,
    );
    env.send(&[f.settle_ix(&[&new], r, terms)], &[&new])
        .unwrap();
    assert_eq!(env.reservation(&r).state, ReservationState::Settled);
}

#[test]
fn settle_rejects_replay_and_double_settle() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    let s = settler(&env);
    let terms = SettleTerms::awards(ROOT, 1, 400, 0);
    env.send(&[f.settle_ix(&[&s], r, terms)], &[&s]).unwrap();
    // The same signed settle again, and a different root.
    assert_error(
        env.send(&[f.settle_ix(&[&s], r, terms)], &[&s]),
        E::ReservationWrongState,
    );
    assert_error(
        env.send(
            &[f.settle_ix(&[&s], r, SettleTerms::awards([8; 32], 1, 300, 0))],
            &[&s],
        ),
        E::ReservationWrongState,
    );
    assert_eq!(env.vault(&f.vault).total_settled, 400);
}

#[test]
fn settle_rejects_over_reserved() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    let s = settler(&env);
    assert_error(
        env.send(
            &[f.settle_ix(&[&s], r, SettleTerms::awards(ROOT, 1, 401, 0))],
            &[&s],
        ),
        E::SettlementExceedsReservation,
    );
    assert_error(
        env.send(
            &[f.settle_ix(&[&s], r, SettleTerms::awards(ROOT, 1, 380, 21))],
            &[&s],
        ),
        E::SettlementExceedsReservation,
    );
}

#[test]
fn settle_rejects_fee_above_config_bps() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    let s = settler(&env);
    assert_error(
        env.send(
            &[f.settle_ix(&[&s], r, SettleTerms::awards(ROOT, 1, 369, 31))],
            &[&s],
        ),
        E::InvalidFeeBps,
    );
}

#[test]
fn settle_rejects_inconsistent_totals() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    let s = settler(&env);
    let cases = [
        // Net plus fee differs from the distributed gross.
        SettleTerms {
            root: ROOT,
            leaf_count: 1,
            distributed_gross: 300,
            settled_total: 250,
            fee_total: 0,
        },
        // Awards with no root, or no leaves.
        SettleTerms::awards([0; 32], 1, 300, 0),
        SettleTerms::awards(ROOT, 0, 300, 0),
        // A root with nothing to claim.
        SettleTerms::awards(ROOT, 1, 0, 0),
        SettleTerms::awards([0; 32], 2, 0, 0),
    ];
    for terms in cases {
        assert_error(
            env.send(&[f.settle_ix(&[&s], r, terms)], &[&s]),
            E::InvalidSettlementTotals,
        );
    }
}

#[test]
fn settle_rejected_while_paused() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    env.pause(true);
    let s = settler(&env);
    let terms = SettleTerms::awards(ROOT, 1, 400, 0);
    assert_error(env.send(&[f.settle_ix(&[&s], r, terms)], &[&s]), E::Paused);
    env.pause(false);
    env.send(&[f.settle_ix(&[&s], r, terms)], &[&s]).unwrap();
}

#[test]
fn settle_rejects_released_reservation() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    let s = settler(&env);
    env.send(&[f.release_ix(&[&s], r)], &[&s]).unwrap();
    assert_error(
        env.send(
            &[f.settle_ix(&[&s], r, SettleTerms::awards(ROOT, 1, 400, 0))],
            &[&s],
        ),
        E::ReservationWrongState,
    );
}

#[test]
fn settle_rejected_after_exit() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    let sponsor = f.sponsor.insecure_clone();
    env.send(
        &[f.exit_ix(&sponsor.pubkey(), &f.sponsor_token)],
        &[&sponsor],
    )
    .unwrap();
    let s = settler(&env);
    assert_error(
        env.send(
            &[f.settle_ix(&[&s], r, SettleTerms::awards(ROOT, 1, 400, 0))],
            &[&s],
        ),
        E::VaultNotActive,
    );
}

#[test]
fn settle_rejects_reservation_of_another_vault() {
    let mut env = Env::new();
    let (_, r) = env.reserved_vault(400);
    let other = env.ready_vault(SPL_TOKEN, 1_000, manager(1), 1_000);
    let s = settler(&env);
    // Anchor ConstraintHasOne.
    assert_custom(
        env.send(
            &[other.settle_ix(&[&s], r, SettleTerms::awards(ROOT, 1, 400, 0))],
            &[&s],
        ),
        2001,
    );
}

#[test]
fn settle_works_for_token_2022_vault() {
    let mut env = Env::new();
    let f = env.ready_vault(TOKEN_2022, 1_000, manager(1), 1_000);
    let s = settler(&env);
    let payer = env.payer.pubkey();
    env.send(
        &[f.reserve_ix(&payer, &[&s], task_id(1), 400, manager(1))],
        &[&s],
    )
    .unwrap();
    let r = reservation_pda(&f.vault, &task_id(1));
    env.send(
        &[f.settle_ix(&[&s], r, SettleTerms::awards(ROOT, 1, 370, 30))],
        &[&s],
    )
    .unwrap();
    assert_eq!(env.vault(&f.vault).total_settled, 400);
}

#[test]
fn revoke_after_settle_restores_reservation_and_manager_allowance() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    let s = settler(&env);
    env.send(
        &[f.settle_ix(&[&s], r, SettleTerms::awards(ROOT, 2, 340, 25))],
        &[&s],
    )
    .unwrap();
    env.pause(true);
    let admin = env.admin.insecure_clone();
    env.send(&[f.revoke_ix(&admin.pubkey(), r)], &[&admin])
        .unwrap();

    let reservation = env.reservation(&r);
    assert_eq!(reservation.state, ReservationState::Reserved);
    assert_eq!(
        (
            reservation.leaf_count,
            reservation.settled_total,
            reservation.fee_total
        ),
        (0, 0, 0)
    );
    let vault = env.vault(&f.vault);
    assert_eq!((vault.total_reserved, vault.total_settled), (400, 0));
    assert_eq!(vault.available(), 600);
    let m = vault.managers[0];
    assert_eq!((m.reserved, m.spent), (400, 0));

    // The settlers can sign a corrected root once the pause lifts.
    env.pause(false);
    env.send(
        &[f.settle_ix(&[&s], r, SettleTerms::awards([8; 32], 1, 300, 0))],
        &[&s],
    )
    .unwrap();
    assert_eq!(env.reservation(&r).root, [8; 32]);
}

#[test]
fn settle_records_when_the_root_was_installed() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    env.warp_to(5_000);
    let s = settler(&env);
    env.send(
        &[f.settle_ix(&[&s], r, SettleTerms::awards(ROOT, 1, 400, 0))],
        &[&s],
    )
    .unwrap();
    assert_eq!(env.reservation(&r).settled_at, 5_000);

    // Revoking clears it with the root.
    env.pause(true);
    let admin = env.admin.insecure_clone();
    env.send(&[f.revoke_ix(&admin.pubkey(), r)], &[&admin])
        .unwrap();
    assert_eq!(env.reservation(&r).settled_at, 0);
}

#[test]
fn claim_delay_defaults_to_an_hour_and_unset_reads_as_the_default() {
    let mut env = Env::new();
    let mut config = env.config();
    assert_eq!(config.claim_delay_seconds, DEFAULT_CLAIM_DELAY_SECONDS);
    assert_eq!(config.claim_delay(), 3_600);
    config.claim_delay_seconds = 0;
    env.write(&config_pda(), &config);
    assert_eq!(env.config().claim_delay(), 3_600);
}

#[test]
fn set_claim_delay_is_admin_only_and_never_zero() {
    let mut env = Env::new();
    let admin = env.admin.insecure_clone();
    env.send(&[set_claim_delay_ix(&admin.pubkey(), 60)], &[&admin])
        .unwrap();
    assert_eq!(env.config().claim_delay(), 60);
    assert_eq!(env.events::<ClaimDelaySet>()[0].claim_delay_seconds, 60);

    let s = settler(&env);
    assert_error(
        env.send(&[set_claim_delay_ix(&s.pubkey(), 1)], &[&s]),
        E::NotAdmin,
    );
    assert_error(
        env.send(&[set_claim_delay_ix(&admin.pubkey(), 0)], &[&admin]),
        E::InvalidClaimDelay,
    );
    assert_error(
        env.send(&[set_claim_delay_ix(&admin.pubkey(), u64::MAX)], &[&admin]),
        E::InvalidClaimDelay,
    );
    // Open while paused.
    env.pause(true);
    env.send(&[set_claim_delay_ix(&admin.pubkey(), 120)], &[&admin])
        .unwrap();
    assert_eq!(env.config().claim_delay(), 120);
}

// The shared award leaf test vector, packages/contracts/docs/specs/sponsored-tasks/vectors.
const VECTOR: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../docs/specs/sponsored-tasks/vectors/solana-award-leaf-v1.json"
);

fn hex<const N: usize>(value: &serde_json::Value) -> [u8; N] {
    let s = value.as_str().unwrap().trim_start_matches("0x");
    let mut out = [0u8; N];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap();
    }
    out
}

fn hex32(value: &serde_json::Value) -> [u8; 32] {
    hex(value)
}

fn pubkey(value: &serde_json::Value) -> Pubkey {
    value.as_str().unwrap().parse().unwrap()
}

#[test]
fn award_leaf_and_proof_match_the_shared_test_vector() {
    let v: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(VECTOR).unwrap()).unwrap();
    let inputs = &v["inputs"];
    assert_eq!(pubkey(&inputs["programId"]), ID);

    let mint = pubkey(&inputs["mint"]);
    let sponsor = pubkey(&inputs["sponsor"]);
    let vault_id: u64 = inputs["vaultIdU64"].as_str().unwrap().parse().unwrap();
    let vault = vault_pda(&mint, &sponsor, vault_id);
    assert_eq!(vault, pubkey(&inputs["vault"]));
    assert_eq!(vault.to_bytes(), hex32(&v["packed"]["vaultId"]));

    let base_chain_id: u64 = inputs["baseChainId"].as_str().unwrap().parse().unwrap();
    assert_eq!(base_chain_id, BASE_CHAIN_ID);
    let task = hex32(&inputs["baseTaskId"]);
    let reservation = reservation_pda(&vault, &task);
    assert_eq!(reservation, pubkey(&inputs["reservation"]));
    assert_eq!(reservation.to_bytes(), hex32(&v["packed"]["allocationId"]));

    let epoch: u64 = inputs["epoch"].as_str().unwrap().parse().unwrap();
    let root = hex32(&v["root"]);
    for leaf in v["leaves"].as_array().unwrap() {
        let index = leaf["leafIndex"].as_u64().unwrap() as u32;
        let worker: [u8; 20] = hex(&leaf["worker"]);
        let amount: u64 = leaf["netAmount"].as_str().unwrap().parse().unwrap();
        let hash = award_leaf(&vault, epoch, &reservation, &task, index, &worker, amount);
        assert_eq!(hash, hex32(&leaf["leafHash"]), "leaf {index}");
        let proof: Vec<[u8; 32]> = leaf["proof"]
            .as_array()
            .unwrap()
            .iter()
            .map(hex32)
            .collect();
        assert!(verify_award_proof(&proof, &root, hash), "proof {index}");
        // Any other amount, worker or index breaks the proof.
        let wrong = award_leaf(
            &vault,
            epoch,
            &reservation,
            &task,
            index,
            &worker,
            amount + 1,
        );
        assert!(!verify_award_proof(&proof, &root, wrong));
        let wrong = award_leaf(
            &vault,
            epoch,
            &reservation,
            &task,
            index + 1,
            &worker,
            amount,
        );
        assert!(!verify_award_proof(&proof, &root, wrong));
        let wrong = award_leaf(
            &vault,
            epoch + 1,
            &reservation,
            &task,
            index,
            &worker,
            amount,
        );
        assert!(!verify_award_proof(&proof, &root, wrong));
    }
}
