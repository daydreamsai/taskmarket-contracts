mod common;

use anchor_lang::prelude::Pubkey;
use anchor_lang::Space;
use common::*;
use solana_keypair::Keypair;
use solana_signer::Signer;
use spl_associated_token_account_interface::address::get_associated_token_address_with_program_id;
use sponsored_tasks::error::SponsoredTasksError as E;
use sponsored_tasks::events::*;
use sponsored_tasks::state::{ClaimReceipt, Manager, Vault, VaultStatus};

const WORKER_A: [u8; 20] = [0xa1; 20];
const WORKER_B: [u8; 20] = [0xb2; 20];
const FEE: u64 = 30;

/// A settled 400 reservation: worker A 300, worker B 70, fee 30, both workers bound.
struct Settled {
    f: VaultFixture,
    r: Pubkey,
    awards: Vec<Award>,
    proofs: Vec<Vec<[u8; 32]>>,
    payouts: Vec<Pubkey>,
}

fn settled(env: &mut Env, token_program: Pubkey) -> Settled {
    let f = env.ready_vault(token_program, 1_000, manager(1), 1_000);
    let s = env.settlers[0].insecure_clone();
    let payer = env.payer.pubkey();
    env.send(
        &[f.reserve_ix(&payer, &[&s], task_id(1), 400, manager(1))],
        &[&s],
    )
    .unwrap();
    let r = reservation_pda(&f.vault, &task_id(1));
    let awards: Vec<Award> = vec![(0, WORKER_A, 300), (1, WORKER_B, 70)];
    let (root, proofs) = award_tree(&f.vault, 1, &r, &task_id(1), &awards);
    env.send(
        &[f.settle_ix(&[&s], r, SettleTerms::awards(root, 2, 370, FEE))],
        &[&s],
    )
    .unwrap();
    env.pass_claim_delay();
    let mut payouts = Vec::new();
    for (_, worker, _) in &awards {
        let owner = Keypair::new().pubkey();
        env.put_binding(*worker, owner);
        payouts.push(env.mint_to(&token_program, &f.mint, &owner, 0));
    }
    Settled {
        f,
        r,
        awards,
        proofs,
        payouts,
    }
}

impl Settled {
    fn claim_ix(&self, payer: &Pubkey, leaf: usize) -> solana_instruction::Instruction {
        let (index, worker, amount) = self.awards[leaf];
        self.f.claim_ix(
            payer,
            self.r,
            index,
            worker,
            amount,
            self.proofs[leaf].clone(),
            self.payouts[leaf],
        )
    }
}

#[test]
fn claim_pays_each_bound_worker() {
    let mut env = Env::new();
    let t = settled(&mut env, SPL_TOKEN);
    // Any account may relay a claim.
    let relayer = Keypair::new();
    env.svm.airdrop(&relayer.pubkey(), 1_000_000_000).unwrap();
    env.send(&[t.claim_ix(&relayer.pubkey(), 0)], &[&relayer])
        .unwrap();

    assert_eq!(env.token_balance(&t.payouts[0]), 300);
    assert_eq!(env.token_balance(&t.f.vault_token), 700);
    let receipt: ClaimReceipt = env.account(&receipt_pda(&t.r, 0));
    assert_eq!((receipt.reservation, receipt.leaf_index), (t.r, 0));
    let reservation = env.reservation(&t.r);
    assert_eq!(
        (reservation.claimed_count, reservation.claimed_total),
        (1, 300)
    );
    let vault = env.vault(&t.f.vault);
    assert_eq!(vault.total_claimed, 300);
    assert_eq!(vault.claimable(), 100);
    assert_eq!(vault.available(), 600);

    let events = env.events::<SponsoredTaskClaimed>();
    assert_eq!(events.len(), 1);
    let e = &events[0];
    assert_eq!((e.vault, e.reservation), (t.f.vault, t.r));
    assert_eq!((e.task_chain_id, e.task_id), (TASK_CHAIN_ID, task_id(1)));
    assert_eq!((e.leaf_index, e.worker), (0, WORKER_A));
    assert_eq!((e.destination, e.amount), (t.payouts[0], 300));

    let payer = env.payer.pubkey();
    env.send(&[t.claim_ix(&payer, 1)], &[]).unwrap();
    assert_eq!(env.token_balance(&t.payouts[1]), 70);
    let reservation = env.reservation(&t.r);
    assert_eq!(
        (reservation.claimed_count, reservation.claimed_total),
        (2, 370)
    );
    assert_eq!(env.vault(&t.f.vault).claimable(), FEE);
}

#[test]
fn claim_rejects_double_claim() {
    let mut env = Env::new();
    let t = settled(&mut env, SPL_TOKEN);
    let payer = env.payer.pubkey();
    env.send(&[t.claim_ix(&payer, 0)], &[]).unwrap();
    assert_error(env.send(&[t.claim_ix(&payer, 0)], &[]), E::ClaimAlreadyPaid);
    assert_eq!(env.token_balance(&t.payouts[0]), 300);
}

#[test]
fn claim_rejects_bad_proof() {
    let mut env = Env::new();
    let t = settled(&mut env, SPL_TOKEN);
    let payer = env.payer.pubkey();
    let proof = t.proofs[0].clone();
    let cases = [
        // Another amount, another worker, another index, another leaf's proof, no proof.
        (0, WORKER_A, 301, proof.clone()),
        (0, WORKER_B, 300, proof.clone()),
        (1, WORKER_A, 300, proof.clone()),
        (0, WORKER_A, 300, t.proofs[1].clone()),
        (0, WORKER_A, 300, vec![]),
    ];
    for (index, worker, amount, proof) in cases {
        let ix =
            t.f.claim_ix(&payer, t.r, index, worker, amount, proof, t.payouts[0]);
        assert_error(env.send(&[ix], &[]), E::InvalidClaimProof);
    }
}

#[test]
fn claim_rejects_index_out_of_bounds_and_zero_amount() {
    let mut env = Env::new();
    let t = settled(&mut env, SPL_TOKEN);
    let payer = env.payer.pubkey();
    let ix =
        t.f.claim_ix(&payer, t.r, 2, WORKER_A, 300, vec![], t.payouts[0]);
    assert_error(env.send(&[ix], &[]), E::ClaimIndexOutOfBounds);
    let ix = t.f.claim_ix(
        &payer,
        t.r,
        0,
        WORKER_A,
        0,
        t.proofs[0].clone(),
        t.payouts[0],
    );
    assert_error(env.send(&[ix], &[]), E::NothingToClaim);
}

#[test]
fn claim_rejects_unbound_worker_and_other_destination() {
    let mut env = Env::new();
    let f = env.ready_vault(SPL_TOKEN, 1_000, manager(1), 1_000);
    let s = env.settlers[0].insecure_clone();
    let payer = env.payer.pubkey();
    env.send(
        &[f.reserve_ix(&payer, &[&s], task_id(1), 400, manager(1))],
        &[&s],
    )
    .unwrap();
    let r = reservation_pda(&f.vault, &task_id(1));
    let (root, proofs) = award_tree(&f.vault, 1, &r, &task_id(1), &[(0, WORKER_A, 400)]);
    env.send(
        &[f.settle_ix(&[&s], r, SettleTerms::awards(root, 1, 400, 0))],
        &[&s],
    )
    .unwrap();
    env.pass_claim_delay();
    let owner = Keypair::new().pubkey();
    let payout = env.mint_to(&SPL_TOKEN, &f.mint, &owner, 0);
    let ix = |dest| f.claim_ix(&payer, r, 0, WORKER_A, 400, proofs[0].clone(), dest);

    assert_error(env.send(&[ix(payout)], &[]), E::PayoutNotBound);

    env.put_binding(WORKER_A, owner);
    let elsewhere = env.mint_to(&SPL_TOKEN, &f.mint, &Keypair::new().pubkey(), 0);
    // Anchor ConstraintTokenOwner.
    assert_custom(env.send(&[ix(elsewhere)], &[]), 2015);

    env.send(&[ix(payout)], &[]).unwrap();
    assert_eq!(env.token_balance(&payout), 400);
}

#[test]
fn claim_never_pays_more_than_the_settled_total() {
    let mut env = Env::new();
    let f = env.ready_vault(SPL_TOKEN, 1_000, manager(1), 1_000);
    let s = env.settlers[0].insecure_clone();
    let payer = env.payer.pubkey();
    env.send(
        &[f.reserve_ix(&payer, &[&s], task_id(1), 400, manager(1))],
        &[&s],
    )
    .unwrap();
    let r = reservation_pda(&f.vault, &task_id(1));
    // A root whose leaves add up to more than the settled total.
    let awards: Vec<Award> = vec![(0, WORKER_A, 300), (1, WORKER_B, 300)];
    let (root, proofs) = award_tree(&f.vault, 1, &r, &task_id(1), &awards);
    env.send(
        &[f.settle_ix(&[&s], r, SettleTerms::awards(root, 2, 400, 0))],
        &[&s],
    )
    .unwrap();
    env.pass_claim_delay();
    let mut payouts = Vec::new();
    for (_, worker, _) in &awards {
        let owner = Keypair::new().pubkey();
        env.put_binding(*worker, owner);
        payouts.push(env.mint_to(&SPL_TOKEN, &f.mint, &owner, 0));
    }
    let claim = |i: usize| {
        let (index, worker, amount) = awards[i];
        f.claim_ix(
            &payer,
            r,
            index,
            worker,
            amount,
            proofs[i].clone(),
            payouts[i],
        )
    };
    env.send(&[claim(0)], &[]).unwrap();
    assert_error(env.send(&[claim(1)], &[]), E::InvalidSettlementTotals);
    assert_eq!(env.vault(&f.vault).total_claimed, 300);
}

#[test]
fn claim_rejected_while_paused() {
    let mut env = Env::new();
    let t = settled(&mut env, SPL_TOKEN);
    env.pause(true);
    let payer = env.payer.pubkey();
    assert_error(env.send(&[t.claim_ix(&payer, 0)], &[]), E::Paused);
    env.pause(false);
    env.send(&[t.claim_ix(&payer, 0)], &[]).unwrap();
}

#[test]
fn claim_rejects_unsettled_reservation() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    env.put_binding(WORKER_A, Keypair::new().pubkey());
    let dest = env.mint_to(&SPL_TOKEN, &f.mint, &Keypair::new().pubkey(), 0);
    let payer = env.payer.pubkey();
    let ix = f.claim_ix(&payer, r, 0, WORKER_A, 400, vec![], dest);
    assert_error(env.send(&[ix], &[]), E::ReservationWrongState);
}

#[test]
fn claim_rejected_after_exit() {
    let mut env = Env::new();
    let t = settled(&mut env, SPL_TOKEN);
    let sponsor = t.f.sponsor.insecure_clone();
    env.send(
        &[t.f.exit_ix(&sponsor.pubkey(), &t.f.sponsor_token)],
        &[&sponsor],
    )
    .unwrap();
    let payer = env.payer.pubkey();
    assert_error(env.send(&[t.claim_ix(&payer, 0)], &[]), E::VaultNotActive);
    let recipient = env.fee_recipient.insecure_clone();
    let dest = env.mint_to(&SPL_TOKEN, &t.f.mint, &recipient.pubkey(), 0);
    assert_error(
        env.send(
            &[t.f.claim_fee_ix(&recipient.pubkey(), t.r, dest)],
            &[&recipient],
        ),
        E::VaultNotActive,
    );
}

#[test]
fn claim_works_for_token_2022_vault() {
    let mut env = Env::new();
    let t = settled(&mut env, TOKEN_2022);
    let payer = env.payer.pubkey();
    env.send(&[t.claim_ix(&payer, 0), t.claim_ix(&payer, 1)], &[])
        .unwrap();
    assert_eq!(env.token_balance(&t.payouts[0]), 300);
    assert_eq!(env.token_balance(&t.payouts[1]), 70);
}

#[test]
fn claim_fee_pays_the_fee_recipient_once_even_while_paused() {
    let mut env = Env::new();
    let t = settled(&mut env, SPL_TOKEN);
    env.pause(true);
    let recipient = env.fee_recipient.insecure_clone();
    // Any token account of the mint may receive it.
    let dest = env.mint_to(&SPL_TOKEN, &t.f.mint, &Keypair::new().pubkey(), 0);
    env.send(
        &[t.f.claim_fee_ix(&recipient.pubkey(), t.r, dest)],
        &[&recipient],
    )
    .unwrap();
    assert_eq!(env.token_balance(&dest), FEE);
    assert!(env.reservation(&t.r).fee_claimed);
    let vault = env.vault(&t.f.vault);
    assert_eq!(vault.total_claimed, FEE);
    assert_eq!(vault.claimable(), 370);

    let events = env.events::<FeeClaimed>();
    assert_eq!(events.len(), 1);
    let e = &events[0];
    assert_eq!((e.vault, e.reservation), (t.f.vault, t.r));
    assert_eq!((e.task_chain_id, e.task_id), (TASK_CHAIN_ID, task_id(1)));
    assert_eq!(
        (e.fee_recipient, e.destination, e.amount),
        (recipient.pubkey(), dest, FEE)
    );

    assert_error(
        env.send(
            &[t.f.claim_fee_ix(&recipient.pubkey(), t.r, dest)],
            &[&recipient],
        ),
        E::NothingToClaim,
    );

    // A claimed fee blocks revoke_settlement like a claimed leaf.
    let admin = env.admin.insecure_clone();
    assert_error(
        env.send(&[t.f.revoke_ix(&admin.pubkey(), t.r)], &[&admin]),
        E::SettlementHasClaims,
    );
}

#[test]
fn claim_fee_rejects_other_callers_and_empty_fees() {
    let mut env = Env::new();
    let t = settled(&mut env, SPL_TOKEN);
    let intruder = Keypair::new();
    let dest = env.mint_to(&SPL_TOKEN, &t.f.mint, &intruder.pubkey(), 0);
    assert_error(
        env.send(
            &[t.f.claim_fee_ix(&intruder.pubkey(), t.r, dest)],
            &[&intruder],
        ),
        E::NotFeeRecipient,
    );

    let (f, r) = env.reserved_vault(400);
    let recipient = env.fee_recipient.insecure_clone();
    let dest = env.mint_to(&SPL_TOKEN, &f.mint, &recipient.pubkey(), 0);
    assert_error(
        env.send(
            &[f.claim_fee_ix(&recipient.pubkey(), r, dest)],
            &[&recipient],
        ),
        E::ReservationWrongState,
    );
    // Settled with no fee.
    env.stage_settlement(&f, &r, 400, 0);
    env.pass_claim_delay();
    assert_error(
        env.send(
            &[f.claim_fee_ix(&recipient.pubkey(), r, dest)],
            &[&recipient],
        ),
        E::NothingToClaim,
    );
}

#[test]
fn revoke_rejected_after_a_claim() {
    let mut env = Env::new();
    let t = settled(&mut env, SPL_TOKEN);
    let payer = env.payer.pubkey();
    env.send(&[t.claim_ix(&payer, 0)], &[]).unwrap();
    let admin = env.admin.insecure_clone();
    assert_error(
        env.send(&[t.f.revoke_ix(&admin.pubkey(), t.r)], &[&admin]),
        E::SettlementHasClaims,
    );
}

/// Settles one 400 award for worker A, with a 30 fee, bound to a fresh payout account.
fn settled_now(env: &mut Env) -> (VaultFixture, Pubkey, solana_instruction::Instruction) {
    let f = env.ready_vault(SPL_TOKEN, 1_000, manager(1), 1_000);
    let s = env.settlers[0].insecure_clone();
    let payer = env.payer.pubkey();
    env.send(
        &[f.reserve_ix(&payer, &[&s], task_id(1), 430, manager(1))],
        &[&s],
    )
    .unwrap();
    let r = reservation_pda(&f.vault, &task_id(1));
    let (root, proofs) = award_tree(&f.vault, 1, &r, &task_id(1), &[(0, WORKER_A, 400)]);
    env.send(
        &[f.settle_ix(&[&s], r, SettleTerms::awards(root, 1, 400, FEE))],
        &[&s],
    )
    .unwrap();
    let owner = Keypair::new().pubkey();
    env.put_binding(WORKER_A, owner);
    let payout = env.mint_to(&SPL_TOKEN, &f.mint, &owner, 0);
    let claim = f.claim_ix(&payer, r, 0, WORKER_A, 400, proofs[0].clone(), payout);
    (f, r, claim)
}

#[test]
fn claim_and_claim_fee_wait_for_the_claim_delay() {
    let mut env = Env::new();
    env.warp_to(10_000);
    let (f, r, claim) = settled_now(&mut env);
    let recipient = env.fee_recipient.insecure_clone();
    let fee_dest = env.mint_to(&SPL_TOKEN, &f.mint, &recipient.pubkey(), 0);
    let claim_fee = f.claim_fee_ix(&recipient.pubkey(), r, fee_dest);

    // One second short of the default hour.
    env.warp_to(10_000 + 3_599);
    assert_error(
        env.send(std::slice::from_ref(&claim), &[]),
        E::ClaimDelayNotElapsed,
    );
    assert_error(
        env.send(std::slice::from_ref(&claim_fee), &[&recipient]),
        E::ClaimDelayNotElapsed,
    );

    env.warp_to(10_000 + 3_600);
    env.send(&[claim], &[]).unwrap();
    env.send(&[claim_fee], &[&recipient]).unwrap();
    assert_eq!(env.token_balance(&fee_dest), FEE);
}

#[test]
fn claim_follows_the_admin_set_claim_delay() {
    let mut env = Env::new();
    let admin = env.admin.insecure_clone();
    env.send(&[set_claim_delay_ix(&admin.pubkey(), 60)], &[&admin])
        .unwrap();
    env.warp_to(10_000);
    let (_, _, claim) = settled_now(&mut env);
    env.warp_to(10_059);
    assert_error(
        env.send(std::slice::from_ref(&claim), &[]),
        E::ClaimDelayNotElapsed,
    );
    env.warp_to(10_060);
    env.send(&[claim], &[]).unwrap();
}

#[test]
fn revoke_during_the_claim_delay_blocks_claims_on_that_root() {
    let mut env = Env::new();
    env.warp_to(10_000);
    let (f, r, claim) = settled_now(&mut env);
    env.warp_to(10_600);
    // No pause: revoke acts on this one reservation only.
    let admin = env.admin.insecure_clone();
    env.send(&[f.revoke_ix(&admin.pubkey(), r)], &[&admin])
        .unwrap();

    // Long after the delay the revoked root still pays nothing, nor does its fee.
    env.warp_to(100_000);
    assert_error(env.send(&[claim], &[]), E::ReservationWrongState);
    let recipient = env.fee_recipient.insecure_clone();
    let dest = env.mint_to(&SPL_TOKEN, &f.mint, &recipient.pubkey(), 0);
    assert_error(
        env.send(
            &[f.claim_fee_ix(&recipient.pubkey(), r, dest)],
            &[&recipient],
        ),
        E::ReservationWrongState,
    );
    assert_eq!(env.vault(&f.vault).total_claimed, 0);
}

#[test]
fn revoke_without_pause_leaves_claims_on_other_vaults_running() {
    let mut env = Env::new();
    env.warp_to(10_000);
    let (bad, bad_r, _) = settled_now(&mut env);
    let other = settled(&mut env, SPL_TOKEN);
    let admin = env.admin.insecure_clone();
    env.send(&[bad.revoke_ix(&admin.pubkey(), bad_r)], &[&admin])
        .unwrap();
    assert!(!env.config().paused);

    let payer = env.payer.pubkey();
    env.send(&[other.claim_ix(&payer, 0)], &[]).unwrap();
    env.send(&[other.claim_ix(&payer, 1)], &[]).unwrap();
    assert_eq!(env.token_balance(&other.payouts[0]), 300);
    assert_eq!(env.token_balance(&other.payouts[1]), 70);
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

fn text<T: std::str::FromStr>(value: &serde_json::Value) -> T
where
    T::Err: std::fmt::Debug,
{
    value.as_str().unwrap().parse().unwrap()
}

/// Rebuilds the vector's vault (mint and sponsor at the vector's fixed keys) inside LiteSVM,
/// settles its root and pays every leaf with the vector's own proofs.
#[test]
fn claim_pays_the_shared_test_vector() {
    let v: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(VECTOR).unwrap()).unwrap();
    let inputs = &v["inputs"];
    let mut env = Env::new();

    let mint: Pubkey = text(&inputs["mint"]);
    let sponsor: Pubkey = text(&inputs["sponsor"]);
    let vault_id: u64 = text(&inputs["vaultIdU64"]);
    let task: [u8; 32] = hex(&inputs["taskId"]);
    let template = env.create_mint(&SPL_TOKEN);
    let mint_account = env.svm.get_account(&template).unwrap();
    env.svm.set_account(mint, mint_account).unwrap();

    let leaves = v["leaves"].as_array().unwrap();
    let total: u64 = leaves.iter().map(|l| text::<u64>(&l["netAmount"])).sum();
    let (vault, bump) = Pubkey::find_program_address(
        &[
            sponsored_tasks::state::VAULT_SEED,
            mint.as_ref(),
            sponsor.as_ref(),
            &vault_id.to_le_bytes(),
        ],
        &sponsored_tasks::ID,
    );
    assert_eq!(vault, text::<Pubkey>(&inputs["vault"]));
    let vault_token = env.mint_to(&SPL_TOKEN, &mint, &vault, total);
    assert_eq!(
        vault_token,
        get_associated_token_address_with_program_id(&vault, &mint, &SPL_TOKEN)
    );
    let state = Vault {
        sponsor,
        mint,
        token_program: SPL_TOKEN,
        token_account: vault_token,
        vault_id,
        status: VaultStatus::Active,
        epoch: text(&inputs["epoch"]),
        total_funded: total,
        total_reserved: 0,
        total_settled: 0,
        total_claimed: 0,
        total_withdrawn: 0,
        total_defaulted_reserved: 0,
        total_defaulted_claimable: 0,
        managers: vec![Manager {
            key: manager(1),
            cap: total,
            reserved: 0,
            spent: 0,
            active: true,
        }],
        bump,
    };
    env.put(&vault, &state, 8 + Vault::INIT_SPACE);
    let f = VaultFixture {
        sponsor: Keypair::new(),
        mint,
        token_program: SPL_TOKEN,
        vault,
        vault_token,
        sponsor_token: vault_token,
        vault_id,
    };

    let s = env.settlers[0].insecure_clone();
    let payer = env.payer.pubkey();
    env.send(
        &[f.reserve_ix(&payer, &[&s], task, total, manager(1))],
        &[&s],
    )
    .unwrap();
    let r = reservation_pda(&vault, &task);
    assert_eq!(r, text::<Pubkey>(&inputs["reservation"]));
    let root: [u8; 32] = hex(&v["root"]);
    env.send(
        &[f.settle_ix(
            &[&s],
            r,
            SettleTerms::awards(root, leaves.len() as u32, total, 0),
        )],
        &[&s],
    )
    .unwrap();
    env.pass_claim_delay();

    for leaf in leaves {
        let index = leaf["leafIndex"].as_u64().unwrap() as u32;
        let worker: [u8; 20] = hex(&leaf["worker"]);
        let amount: u64 = text(&leaf["netAmount"]);
        let proof: Vec<[u8; 32]> = leaf["proof"].as_array().unwrap().iter().map(hex).collect();
        let owner = Keypair::new().pubkey();
        env.put_binding(worker, owner);
        let dest = env.mint_to(&SPL_TOKEN, &mint, &owner, 0);
        env.send(
            &[f.claim_ix(&payer, r, index, worker, amount, proof, dest)],
            &[],
        )
        .unwrap();
        assert_eq!(env.token_balance(&dest), amount, "leaf {index}");
    }
    assert_eq!(env.token_balance(&vault_token), 0);
    assert_eq!(env.vault(&vault).claimable(), 0);
}
