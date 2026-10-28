mod common;

use anchor_lang::prelude::{AccountMeta, Pubkey};
use common::*;
use solana_instruction::Instruction;
use solana_keypair::Keypair;
use solana_signer::Signer;
use spl_token_2022_interface::extension::ExtensionType;
use sponsored_tasks::error::SponsoredTasksError as E;
use sponsored_tasks::events::*;
use sponsored_tasks::state::{ManagerInput, ReservationState, VaultStatus};

fn input(key: sponsored_tasks::state::ManagerKey, cap: u64, active: bool) -> ManagerInput {
    ManagerInput { key, cap, active }
}

#[test]
fn init_config_by_upgrade_authority() {
    let env = Env::with_threshold(3, 2);
    let config = env.config();
    assert_eq!(config.admin, env.admin.pubkey());
    assert_eq!(config.settlers.len(), 3);
    assert_eq!(config.threshold, 2);
    assert!(!config.paused);
    assert_eq!(config.fee_bps, 750);
    let events = env.events::<ConfigInitialized>();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].admin, env.admin.pubkey());
    assert_eq!(events[0].threshold, 2);
}

#[test]
fn init_config_rejects_non_upgrade_authority() {
    let mut env = Env::bare();
    let intruder = env.admin.insecure_clone();
    let settlers = vec![env.settlers[0].pubkey()];
    assert_error(env.init_config(&intruder, settlers, 1, 0), E::NotAdmin);
}

#[test]
fn init_config_rejects_bad_settler_sets() {
    let mut env = Env::bare();
    let authority = env.upgrade_authority.insecure_clone();
    let s = env.settlers[0].pubkey();
    assert_error(
        env.init_config(&authority, vec![], 1, 0),
        E::InvalidSettlers,
    );
    assert_error(
        env.init_config(&authority, vec![s, s], 1, 0),
        E::InvalidSettlers,
    );
    let six = (0..6).map(|_| Keypair::new().pubkey()).collect();
    assert_error(env.init_config(&authority, six, 1, 0), E::InvalidSettlers);
    assert_error(
        env.init_config(&authority, vec![s], 0, 0),
        E::InvalidThreshold,
    );
    assert_error(
        env.init_config(&authority, vec![s], 2, 0),
        E::InvalidThreshold,
    );
    assert_error(
        env.init_config(&authority, vec![s], 1, 10_001),
        E::InvalidFeeBps,
    );
}

#[test]
fn init_config_runs_once() {
    let mut env = Env::new();
    let authority = env.upgrade_authority.insecure_clone();
    let s = env.settlers[0].pubkey();
    // System program AccountAlreadyInUse.
    assert_custom(env.init_config(&authority, vec![s], 1, 0), 0);
}

#[test]
fn set_admin_rotates_admin() {
    let mut env = Env::new();
    let admin = env.admin.insecure_clone();
    let next = Keypair::new();
    env.svm.airdrop(&next.pubkey(), 1_000_000_000).unwrap();
    env.send(&[set_admin_ix(&admin.pubkey(), next.pubkey())], &[&admin])
        .unwrap();
    assert_eq!(env.config().admin, next.pubkey());
    let events = env.events::<AdminChanged>();
    assert_eq!(events[0].previous, admin.pubkey());
    assert_eq!(events[0].admin, next.pubkey());

    assert_error(
        env.send(&[pause_ix(&admin.pubkey(), true)], &[&admin]),
        E::NotAdmin,
    );
    env.send(&[pause_ix(&next.pubkey(), true)], &[&next])
        .unwrap();
}

#[test]
fn set_admin_rejects_non_admin() {
    let mut env = Env::new();
    let intruder = env.settlers[0].insecure_clone();
    assert_error(
        env.send(
            &[set_admin_ix(&intruder.pubkey(), intruder.pubkey())],
            &[&intruder],
        ),
        E::NotAdmin,
    );
}

#[test]
fn set_settlers_rotates_set_and_threshold() {
    let mut env = Env::new();
    let f = env.ready_vault(SPL_TOKEN, 1_000, manager(1), 1_000);
    let admin = env.admin.insecure_clone();
    let s0 = env.settlers[0].insecure_clone();
    let s1 = env.settlers[1].insecure_clone();
    let s2 = env.settlers[2].insecure_clone();
    env.send(
        &[set_settlers_ix(
            &admin.pubkey(),
            vec![s1.pubkey(), s2.pubkey()],
            2,
        )],
        &[&admin],
    )
    .unwrap();
    let config = env.config();
    assert_eq!(config.settlers, vec![s1.pubkey(), s2.pubkey()]);
    assert_eq!(config.threshold, 2);
    assert_eq!(env.events::<SettlersChanged>()[0].threshold, 2);

    let payer = env.payer.pubkey();
    // The old settler is out, and one new settler is below the threshold.
    assert_error(
        env.send(
            &[f.reserve_ix(&payer, &[&s0], task_id(1), 1, manager(1))],
            &[&s0],
        ),
        E::SettlerThresholdNotMet,
    );
    assert_error(
        env.send(
            &[f.reserve_ix(&payer, &[&s1], task_id(1), 1, manager(1))],
            &[&s1],
        ),
        E::SettlerThresholdNotMet,
    );
    env.send(
        &[f.reserve_ix(&payer, &[&s1, &s2], task_id(1), 1, manager(1))],
        &[&s1, &s2],
    )
    .unwrap();
}

#[test]
fn set_settlers_rejects_bad_sets_and_non_admin() {
    let mut env = Env::new();
    let admin = env.admin.insecure_clone();
    let s = env.settlers[0].pubkey();
    assert_error(
        env.send(&[set_settlers_ix(&admin.pubkey(), vec![], 1)], &[&admin]),
        E::InvalidSettlers,
    );
    assert_error(
        env.send(&[set_settlers_ix(&admin.pubkey(), vec![s], 2)], &[&admin]),
        E::InvalidThreshold,
    );
    let settler = env.settlers[0].insecure_clone();
    assert_error(
        env.send(
            &[set_settlers_ix(&settler.pubkey(), vec![s], 1)],
            &[&settler],
        ),
        E::NotAdmin,
    );
}

#[test]
fn pause_toggles_and_rejects_non_admin() {
    let mut env = Env::new();
    env.pause(true);
    assert!(env.config().paused);
    assert!(env.events::<PauseSet>()[0].paused);
    env.pause(false);
    assert!(!env.config().paused);

    for intruder in [
        env.settlers[0].insecure_clone(),
        env.upgrade_authority.insecure_clone(),
    ] {
        assert_error(
            env.send(&[pause_ix(&intruder.pubkey(), true)], &[&intruder]),
            E::NotAdmin,
        );
    }
}

#[test]
fn create_vault_spl_token() {
    let mut env = Env::new();
    let f = env.vault_fixture(SPL_TOKEN, 0);
    let vault = env.vault(&f.vault);
    assert_eq!(vault.sponsor, f.sponsor.pubkey());
    assert_eq!(vault.mint, f.mint);
    assert_eq!(vault.token_program, SPL_TOKEN);
    assert_eq!(vault.token_account, f.vault_token);
    assert_eq!(vault.vault_id, f.vault_id);
    assert_eq!(vault.status, VaultStatus::Active);
    assert_eq!(vault.epoch, 1);
    assert!(vault.managers.is_empty());
    let events = env.events::<VaultCreated>();
    assert_eq!(events[0].vault, f.vault);
    assert_eq!(events[0].epoch, 1);
}

fn allowed_mint(env: &mut Env, ext: ExtensionType, ixs: impl Fn(&Pubkey) -> Vec<Instruction>) {
    let mint = env.create_mint_with(&TOKEN_2022, &[ext], ixs);
    let f = env.vault_fixture_for(TOKEN_2022, mint, 0);
    assert_eq!(env.vault(&f.vault).mint, mint);
}

#[test]
fn create_vault_accepts_token_2022_plain_and_allowed_extensions() {
    let mut env = Env::new();
    let f = env.vault_fixture(TOKEN_2022, 0);
    assert_eq!(env.vault(&f.vault).token_program, TOKEN_2022);

    let payer = env.payer.pubkey();
    allowed_mint(&mut env, ExtensionType::MintCloseAuthority, |mint| {
        vec![
            spl_token_2022_interface::instruction::initialize_mint_close_authority(
                &TOKEN_2022,
                mint,
                Some(&payer),
            )
            .unwrap(),
        ]
    });
    allowed_mint(&mut env, ExtensionType::Pausable, |mint| {
        vec![
            spl_token_2022_interface::extension::pausable::instruction::initialize(
                &TOKEN_2022,
                mint,
                &payer,
            )
            .unwrap(),
        ]
    });
    allowed_mint(&mut env, ExtensionType::MetadataPointer, |mint| {
        vec![
            spl_token_2022_interface::extension::metadata_pointer::instruction::initialize(
                &TOKEN_2022,
                mint,
                Some(payer),
                Some(*mint),
            )
            .unwrap(),
        ]
    });
}

#[test]
fn create_vault_accepts_default_frozen_mint() {
    let mut env = Env::new();
    let mint = env.create_mint_with(&TOKEN_2022, &[ExtensionType::DefaultAccountState], |mint| {
        vec![
            spl_token_2022_interface::extension::default_account_state::instruction::initialize_default_account_state(
                &TOKEN_2022,
                mint,
                &spl_token_2022_interface::state::AccountState::Frozen,
            )
            .unwrap(),
        ]
    });
    let sponsor = Keypair::new();
    env.svm.airdrop(&sponsor.pubkey(), 10_000_000_000).unwrap();
    env.send(
        &[create_vault_ix(&sponsor.pubkey(), &mint, &TOKEN_2022, 1)],
        &[&sponsor],
    )
    .unwrap();
}

fn assert_mint_rejected(
    env: &mut Env,
    ext: ExtensionType,
    ixs: impl Fn(&Pubkey) -> Vec<Instruction>,
) {
    let mint = env.create_mint_with(&TOKEN_2022, &[ext], ixs);
    let sponsor = Keypair::new();
    env.svm.airdrop(&sponsor.pubkey(), 10_000_000_000).unwrap();
    let ix = create_vault_ix(&sponsor.pubkey(), &mint, &TOKEN_2022, 1);
    assert_error(env.send(&[ix], &[&sponsor]), E::UnsupportedMintExtension);
}

#[test]
fn create_vault_rejects_transfer_fee_mint() {
    let mut env = Env::new();
    let payer = env.payer.pubkey();
    assert_mint_rejected(&mut env, ExtensionType::TransferFeeConfig, |mint| {
        vec![
            spl_token_2022_interface::extension::transfer_fee::instruction::initialize_transfer_fee_config(
                &TOKEN_2022,
                mint,
                Some(&payer),
                Some(&payer),
                100,
                1_000,
            )
            .unwrap(),
        ]
    });
}

#[test]
fn create_vault_rejects_transfer_hook_mint() {
    let mut env = Env::new();
    let payer = env.payer.pubkey();
    assert_mint_rejected(&mut env, ExtensionType::TransferHook, |mint| {
        vec![
            spl_token_2022_interface::extension::transfer_hook::instruction::initialize(
                &TOKEN_2022,
                mint,
                Some(payer),
                Some(Pubkey::new_unique()),
            )
            .unwrap(),
        ]
    });
}

#[test]
fn create_vault_rejects_permanent_delegate_mint() {
    let mut env = Env::new();
    let payer = env.payer.pubkey();
    assert_mint_rejected(&mut env, ExtensionType::PermanentDelegate, |mint| {
        vec![
            spl_token_2022_interface::instruction::initialize_permanent_delegate(
                &TOKEN_2022,
                mint,
                &payer,
            )
            .unwrap(),
        ]
    });
}

#[test]
fn create_vault_rejects_non_transferable_mint() {
    let mut env = Env::new();
    assert_mint_rejected(&mut env, ExtensionType::NonTransferable, |mint| {
        vec![
            spl_token_2022_interface::instruction::initialize_non_transferable_mint(
                &TOKEN_2022,
                mint,
            )
            .unwrap(),
        ]
    });
}

#[test]
fn create_vault_rejects_confidential_transfer_mint() {
    let mut env = Env::new();
    let payer = env.payer.pubkey();
    assert_mint_rejected(&mut env, ExtensionType::ConfidentialTransferMint, |mint| {
        vec![
            spl_token_2022_interface::extension::confidential_transfer::instruction::initialize_mint(
                &TOKEN_2022,
                mint,
                Some(payer),
                true,
                None,
            )
            .unwrap(),
        ]
    });
}

#[test]
fn create_vault_rejected_while_paused() {
    let mut env = Env::new();
    env.pause(true);
    let mint = env.create_mint(&SPL_TOKEN);
    let sponsor = Keypair::new();
    env.svm.airdrop(&sponsor.pubkey(), 10_000_000_000).unwrap();
    let ix = create_vault_ix(&sponsor.pubkey(), &mint, &SPL_TOKEN, 1);
    assert_error(env.send(&[ix], &[&sponsor]), E::Paused);
}

#[test]
fn fund_moves_tokens_and_records_total() {
    for program in [SPL_TOKEN, TOKEN_2022] {
        let mut env = Env::new();
        let f = env.vault_fixture(program, 1_000);
        let sponsor = f.sponsor.insecure_clone();
        env.send(
            &[f.fund_ix(&sponsor.pubkey(), &f.sponsor_token, 400)],
            &[&sponsor],
        )
        .unwrap();
        let events = env.events::<VaultFunded>();
        assert_eq!(events[0].funder, sponsor.pubkey());
        assert_eq!(events[0].amount, 400);

        // Anyone may fund, not only the sponsor.
        let other = Keypair::new();
        let other_token = env.mint_to(&program, &f.mint, &other.pubkey(), 100);
        env.send(&[f.fund_ix(&other.pubkey(), &other_token, 100)], &[&other])
            .unwrap();

        assert_eq!(env.token_balance(&f.vault_token), 500);
        assert_eq!(env.token_balance(&f.sponsor_token), 600);
        let vault = env.vault(&f.vault);
        assert_eq!(vault.total_funded, 500);
        assert_eq!(vault.available(), 500);
    }
}

#[test]
fn fund_rejects_zero_amount() {
    let mut env = Env::new();
    let f = env.vault_fixture(SPL_TOKEN, 1_000);
    let sponsor = f.sponsor.insecure_clone();
    assert_error(
        env.send(
            &[f.fund_ix(&sponsor.pubkey(), &f.sponsor_token, 0)],
            &[&sponsor],
        ),
        E::ZeroAmount,
    );
}

#[test]
fn fund_open_while_paused() {
    let mut env = Env::new();
    let f = env.vault_fixture(SPL_TOKEN, 1_000);
    env.pause(true);
    let sponsor = f.sponsor.insecure_clone();
    env.send(
        &[f.fund_ix(&sponsor.pubkey(), &f.sponsor_token, 10)],
        &[&sponsor],
    )
    .unwrap();
    assert_eq!(env.vault(&f.vault).total_funded, 10);
}

#[test]
fn fund_rejected_after_exit() {
    let mut env = Env::new();
    let f = env.vault_fixture(SPL_TOKEN, 1_000);
    let sponsor = f.sponsor.insecure_clone();
    env.send(
        &[f.exit_ix(&sponsor.pubkey(), &f.sponsor_token)],
        &[&sponsor],
    )
    .unwrap();
    assert_error(
        env.send(
            &[f.fund_ix(&sponsor.pubkey(), &f.sponsor_token, 10)],
            &[&sponsor],
        ),
        E::VaultNotActive,
    );
}

#[test]
fn set_managers_adds_and_updates() {
    let mut env = Env::new();
    let f = env.vault_fixture(SPL_TOKEN, 0);
    let sponsor = f.sponsor.insecure_clone();
    let tempo = manager_on(TEMPO_CHAIN_ID, 1);
    env.send(
        &[f.set_managers_ix(
            &sponsor.pubkey(),
            vec![input(manager(1), 100, true), input(tempo, 50, true)],
        )],
        &[&sponsor],
    )
    .unwrap();
    assert_eq!(env.events::<ManagerConfigured>().len(), 2);
    env.send(
        &[f.set_managers_ix(&sponsor.pubkey(), vec![input(manager(1), 300, false)])],
        &[&sponsor],
    )
    .unwrap();
    let vault = env.vault(&f.vault);
    // Same address on two chains is two managers.
    assert_eq!(vault.managers.len(), 2);
    assert_eq!(vault.managers[0].key, manager(1));
    assert_eq!(vault.managers[0].cap, 300);
    assert!(!vault.managers[0].active);
    assert_eq!(vault.managers[1].key, tempo);
    assert_eq!(vault.managers[1].cap, 50);
    let events = env.events::<ManagerConfigured>();
    assert_eq!(events[0].manager, manager(1));
    assert_eq!(events[0].cap, 300);
    assert!(!events[0].active);
}

#[test]
fn set_managers_rejects_non_sponsor() {
    let mut env = Env::new();
    let f = env.vault_fixture(SPL_TOKEN, 0);
    let intruder = Keypair::new();
    assert_error(
        env.send(
            &[f.set_managers_ix(&intruder.pubkey(), vec![input(manager(1), 1, true)])],
            &[&intruder],
        ),
        E::NotSponsor,
    );
}

#[test]
fn set_managers_rejects_too_many() {
    let mut env = Env::new();
    let f = env.vault_fixture(SPL_TOKEN, 0);
    let sponsor = f.sponsor.insecure_clone();
    let nine = (0..9).map(|n| input(manager(n), 1, true)).collect();
    assert_error(
        env.send(&[f.set_managers_ix(&sponsor.pubkey(), nine)], &[&sponsor]),
        E::TooManyManagers,
    );
}

#[test]
fn set_managers_rejects_cap_below_reserved() {
    let mut env = Env::new();
    let (f, _) = env.reserved_vault(300);
    let sponsor = f.sponsor.insecure_clone();
    assert_error(
        env.send(
            &[f.set_managers_ix(&sponsor.pubkey(), vec![input(manager(1), 299, true)])],
            &[&sponsor],
        ),
        E::InvalidManagerCap,
    );
}

#[test]
fn set_managers_open_while_paused() {
    let mut env = Env::new();
    let f = env.vault_fixture(SPL_TOKEN, 0);
    env.pause(true);
    let sponsor = f.sponsor.insecure_clone();
    env.send(
        &[f.set_managers_ix(&sponsor.pubkey(), vec![input(manager(1), 5, true)])],
        &[&sponsor],
    )
    .unwrap();
    assert_eq!(env.vault(&f.vault).managers.len(), 1);
}

#[test]
fn set_managers_rejected_after_exit() {
    let mut env = Env::new();
    let f = env.vault_fixture(SPL_TOKEN, 0);
    let sponsor = f.sponsor.insecure_clone();
    env.send(
        &[f.exit_ix(&sponsor.pubkey(), &f.sponsor_token)],
        &[&sponsor],
    )
    .unwrap();
    assert_error(
        env.send(
            &[f.set_managers_ix(&sponsor.pubkey(), vec![input(manager(1), 1, true)])],
            &[&sponsor],
        ),
        E::VaultNotActive,
    );
}

#[test]
fn reserve_records_reservation_and_totals() {
    let mut env = Env::new();
    let f = env.ready_vault(SPL_TOKEN, 1_000, manager(1), 600);
    let settler = env.settlers[0].insecure_clone();
    let payer = env.payer.pubkey();
    env.send(
        &[f.reserve_ix(&payer, &[&settler], task_id(1), 250, manager(1))],
        &[&settler],
    )
    .unwrap();

    let key = reservation_pda(&f.vault, &task_id(1));
    let r = env.reservation(&key);
    assert_eq!(r.vault, f.vault);
    assert_eq!(r.epoch, 1);
    assert_eq!(r.task_chain_id, TASK_CHAIN_ID);
    assert_eq!(r.task_id, task_id(1));
    assert_eq!(r.nonce, 1);
    assert_eq!(r.deadline, DEADLINE);
    assert_eq!(r.manager, manager(1));
    assert_eq!(r.amount, 250);
    assert_eq!(r.state, ReservationState::Reserved);
    assert_eq!(r.root, [0; 32]);
    assert_eq!((r.settled_total, r.claimed_count), (0, 0));

    let vault = env.vault(&f.vault);
    assert_eq!(vault.total_reserved, 250);
    assert_eq!(vault.available(), 750);
    assert_eq!(vault.managers[0].reserved, 250);
    assert_eq!(env.token_balance(&f.vault_token), 1_000);

    let events = env.events::<TaskReserved>();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].reservation, key);
    assert_eq!(events[0].manager, manager(1));
    assert_eq!(events[0].amount, 250);
    assert_eq!(events[0].epoch, 1);
}

#[test]
fn reserve_rejects_manager_on_another_chain() {
    let mut env = Env::new();
    let tempo = manager_on(TEMPO_CHAIN_ID, 1);
    let f = env.ready_vault(SPL_TOKEN, 1_000, tempo, 1_000);
    let settler = env.settlers[0].insecure_clone();
    let payer = env.payer.pubkey();
    // The task is on Base; the manager is a Tempo creator.
    assert_error(
        env.send(
            &[f.reserve_ix(&payer, &[&settler], task_id(1), 1, tempo)],
            &[&settler],
        ),
        E::ManagerChainMismatch,
    );
    // The same address on Base is a different, unconfigured manager.
    assert_error(
        env.send(
            &[f.reserve_ix(&payer, &[&settler], task_id(1), 1, manager(1))],
            &[&settler],
        ),
        E::ManagerNotActive,
    );
}

#[test]
fn reserve_rejects_non_settler() {
    let mut env = Env::new();
    let f = env.ready_vault(SPL_TOKEN, 1_000, manager(1), 1_000);
    let payer = env.payer.pubkey();
    for intruder in [Keypair::new(), f.sponsor.insecure_clone()] {
        assert_error(
            env.send(
                &[f.reserve_ix(&payer, &[&intruder], task_id(1), 10, manager(1))],
                &[&intruder],
            ),
            E::SettlerThresholdNotMet,
        );
    }
}

#[test]
fn reserve_ignores_unsigned_settler_account() {
    let mut env = Env::new();
    let f = env.ready_vault(SPL_TOKEN, 1_000, manager(1), 1_000);
    let settler = env.settlers[0].pubkey();
    let payer = env.payer.pubkey();
    let mut ix = f.reserve_ix(&payer, &[], task_id(1), 10, manager(1));
    ix.accounts.push(AccountMeta::new_readonly(settler, false));
    assert_error(env.send(&[ix], &[]), E::SettlerThresholdNotMet);
}

#[test]
fn reserve_enforces_settler_threshold() {
    let mut env = Env::with_threshold(3, 2);
    let f = env.ready_vault(SPL_TOKEN, 1_000, manager(1), 1_000);
    let s0 = env.settlers[0].insecure_clone();
    let s1 = env.settlers[1].insecure_clone();
    let payer = env.payer.pubkey();
    assert_error(
        env.send(
            &[f.reserve_ix(&payer, &[&s0], task_id(1), 10, manager(1))],
            &[&s0],
        ),
        E::SettlerThresholdNotMet,
    );
    // The same settler twice counts once.
    assert_error(
        env.send(
            &[f.reserve_ix(&payer, &[&s0, &s0], task_id(1), 10, manager(1))],
            &[&s0],
        ),
        E::SettlerThresholdNotMet,
    );
    env.send(
        &[f.reserve_ix(&payer, &[&s0, &s1], task_id(1), 10, manager(1))],
        &[&s0, &s1],
    )
    .unwrap();
}

#[test]
fn reserve_rejected_while_paused() {
    let mut env = Env::new();
    let f = env.ready_vault(SPL_TOKEN, 1_000, manager(1), 1_000);
    env.pause(true);
    let settler = env.settlers[0].insecure_clone();
    let payer = env.payer.pubkey();
    let ix = f.reserve_ix(&payer, &[&settler], task_id(1), 10, manager(1));
    assert_error(env.send(std::slice::from_ref(&ix), &[&settler]), E::Paused);
    env.pause(false);
    env.send(&[ix], &[&settler]).unwrap();
}

#[test]
fn reserve_bounded_by_manager_allowance_not_vault_size() {
    let mut env = Env::new();
    let f = env.ready_vault(SPL_TOKEN, 1_000, manager(1), 300);
    let settler = env.settlers[0].insecure_clone();
    let payer = env.payer.pubkey();
    env.send(
        &[f.reserve_ix(&payer, &[&settler], task_id(1), 200, manager(1))],
        &[&settler],
    )
    .unwrap();
    // The allowance bounds the manager's outstanding reservations, not each one.
    assert_error(
        env.send(
            &[f.reserve_ix(&payer, &[&settler], task_id(2), 101, manager(1))],
            &[&settler],
        ),
        E::ManagerAllowanceExceeded,
    );
    env.send(
        &[f.reserve_ix(&payer, &[&settler], task_id(2), 100, manager(1))],
        &[&settler],
    )
    .unwrap();
    assert_eq!(env.vault(&f.vault).managers[0].reserved, 300);
    assert_error(
        env.send(
            &[f.reserve_ix(&payer, &[&settler], task_id(3), 1, manager(1))],
            &[&settler],
        ),
        E::ManagerAllowanceExceeded,
    );
}

#[test]
fn reserve_rejects_over_manager_allowance() {
    let mut env = Env::new();
    let f = env.ready_vault(SPL_TOKEN, 1_000, manager(1), 100);
    let settler = env.settlers[0].insecure_clone();
    let payer = env.payer.pubkey();
    assert_error(
        env.send(
            &[f.reserve_ix(&payer, &[&settler], task_id(1), 101, manager(1))],
            &[&settler],
        ),
        E::ManagerAllowanceExceeded,
    );
}

#[test]
fn reserve_rejects_unknown_or_inactive_manager() {
    let mut env = Env::new();
    let f = env.ready_vault(SPL_TOKEN, 1_000, manager(1), 1_000);
    let settler = env.settlers[0].insecure_clone();
    let payer = env.payer.pubkey();
    assert_error(
        env.send(
            &[f.reserve_ix(&payer, &[&settler], task_id(1), 1, manager(2))],
            &[&settler],
        ),
        E::ManagerNotActive,
    );
    let sponsor = f.sponsor.insecure_clone();
    env.send(
        &[f.set_managers_ix(&sponsor.pubkey(), vec![input(manager(1), 1_000, false)])],
        &[&sponsor],
    )
    .unwrap();
    assert_error(
        env.send(
            &[f.reserve_ix(&payer, &[&settler], task_id(1), 1, manager(1))],
            &[&settler],
        ),
        E::ManagerNotActive,
    );
}

#[test]
fn reserve_rejects_over_available() {
    let mut env = Env::new();
    let f = env.ready_vault(SPL_TOKEN, 100, manager(1), 1_000);
    let settler = env.settlers[0].insecure_clone();
    let payer = env.payer.pubkey();
    assert_error(
        env.send(
            &[f.reserve_ix(&payer, &[&settler], task_id(1), 101, manager(1))],
            &[&settler],
        ),
        E::InsufficientAvailable,
    );
}

#[test]
fn reserve_rejects_zero_amount_and_past_deadline() {
    let mut env = Env::new();
    let f = env.ready_vault(SPL_TOKEN, 1_000, manager(1), 1_000);
    let settler = env.settlers[0].insecure_clone();
    let payer = env.payer.pubkey();
    assert_error(
        env.send(
            &[f.reserve_ix(&payer, &[&settler], task_id(1), 0, manager(1))],
            &[&settler],
        ),
        E::ZeroAmount,
    );
    let mut clock = env.svm.get_sysvar::<anchor_lang::prelude::Clock>();
    clock.unix_timestamp = DEADLINE;
    env.svm.set_sysvar(&clock);
    assert_error(
        env.send(
            &[f.reserve_ix_with(&payer, &[&settler], task_id(1), DEADLINE, 1, manager(1))],
            &[&settler],
        ),
        E::DeadlineInPast,
    );
}

#[test]
fn reserve_rejects_duplicate_task() {
    let mut env = Env::new();
    let (f, _) = env.reserved_vault(1);
    let settler = env.settlers[0].insecure_clone();
    let payer = env.payer.pubkey();
    // System program AccountAlreadyInUse.
    assert_custom(
        env.send(
            &[f.reserve_ix(&payer, &[&settler], task_id(1), 2, manager(1))],
            &[&settler],
        ),
        0,
    );
}

#[test]
fn reserve_rejected_after_exit() {
    let mut env = Env::new();
    let f = env.ready_vault(SPL_TOKEN, 1_000, manager(1), 1_000);
    let sponsor = f.sponsor.insecure_clone();
    env.send(
        &[f.exit_ix(&sponsor.pubkey(), &f.sponsor_token)],
        &[&sponsor],
    )
    .unwrap();
    let settler = env.settlers[0].insecure_clone();
    let payer = env.payer.pubkey();
    assert_error(
        env.send(
            &[f.reserve_ix(&payer, &[&settler], task_id(1), 1, manager(1))],
            &[&settler],
        ),
        E::VaultNotActive,
    );
}

#[test]
fn release_returns_reservation_to_vault() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    let settler = env.settlers[0].insecure_clone();
    env.send(&[f.release_ix(&[&settler], r)], &[&settler])
        .unwrap();
    assert_eq!(env.reservation(&r).state, ReservationState::Released);
    let vault = env.vault(&f.vault);
    assert_eq!(vault.total_reserved, 0);
    assert_eq!(vault.available(), 1_000);
    assert_eq!(vault.managers[0].reserved, 0);
    let events = env.events::<TaskReleased>();
    assert_eq!(events[0].reservation, r);
    assert_eq!(events[0].amount, 400);

    // A second release is a no-op and emits nothing.
    env.send(&[f.release_ix(&[&settler], r)], &[&settler])
        .unwrap();
    assert!(env.events::<TaskReleased>().is_empty());
    assert_eq!(env.vault(&f.vault).total_reserved, 0);
}

#[test]
fn release_open_while_paused() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    env.pause(true);
    let settler = env.settlers[0].insecure_clone();
    env.send(&[f.release_ix(&[&settler], r)], &[&settler])
        .unwrap();
    assert_eq!(env.reservation(&r).state, ReservationState::Released);
}

#[test]
fn release_rejects_non_settler() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    let sponsor = f.sponsor.insecure_clone();
    assert_error(
        env.send(&[f.release_ix(&[&sponsor], r)], &[&sponsor]),
        E::SettlerThresholdNotMet,
    );
}

#[test]
fn release_rejects_settled_reservation() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    env.stage_settlement(&f, &r, 400, 0);
    let settler = env.settlers[0].insecure_clone();
    assert_error(
        env.send(&[f.release_ix(&[&settler], r)], &[&settler]),
        E::ReservationWrongState,
    );
}

#[test]
fn release_rejects_reservation_of_another_vault() {
    let mut env = Env::new();
    let (_, r) = env.reserved_vault(400);
    let other = env.ready_vault(SPL_TOKEN, 1_000, manager(1), 1_000);
    let settler = env.settlers[0].insecure_clone();
    // Anchor ConstraintHasOne.
    assert_custom(
        env.send(&[other.release_ix(&[&settler], r)], &[&settler]),
        2001,
    );
}

#[test]
fn release_rejected_after_exit() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    let sponsor = f.sponsor.insecure_clone();
    env.send(
        &[f.exit_ix(&sponsor.pubkey(), &f.sponsor_token)],
        &[&sponsor],
    )
    .unwrap();
    let settler = env.settlers[0].insecure_clone();
    assert_error(
        env.send(&[f.release_ix(&[&settler], r)], &[&settler]),
        E::VaultNotActive,
    );
}

#[test]
fn emergency_exit_takes_whole_balance_and_defaults_open_reservations() {
    let mut env = Env::new();
    let f = env.ready_vault(SPL_TOKEN, 1_000, manager(1), 1_000);
    let settler = env.settlers[0].insecure_clone();
    let payer = env.payer.pubkey();
    env.send(
        &[
            f.reserve_ix(&payer, &[&settler], task_id(1), 300, manager(1)),
            f.reserve_ix(&payer, &[&settler], task_id(2), 200, manager(1)),
            f.reserve_ix(&payer, &[&settler], task_id(3), 100, manager(1)),
        ],
        &[&settler],
    )
    .unwrap();
    let r1 = reservation_pda(&f.vault, &task_id(1));
    let r2 = reservation_pda(&f.vault, &task_id(2));
    let r3 = reservation_pda(&f.vault, &task_id(3));
    env.send(&[f.release_ix(&[&settler], r3)], &[&settler])
        .unwrap();
    env.stage_settlement(&f, &r2, 150, 0);

    // Open while paused.
    env.pause(true);
    let sponsor = f.sponsor.insecure_clone();
    let recipient = Keypair::new().pubkey();
    let recipient_token = env.mint_to(&SPL_TOKEN, &f.mint, &recipient, 0);
    env.send(
        &[f.exit_ix(&sponsor.pubkey(), &recipient_token)],
        &[&sponsor],
    )
    .unwrap();

    assert_eq!(env.token_balance(&recipient_token), 1_000);
    assert_eq!(env.token_balance(&f.vault_token), 0);
    let vault = env.vault(&f.vault);
    assert_eq!(vault.status, VaultStatus::Exited);
    assert_eq!(vault.epoch, 2);
    assert_eq!(vault.total_reserved, 0);
    assert_eq!(vault.claimable(), 0);
    assert_eq!(vault.total_defaulted_reserved, 300);
    assert_eq!(vault.total_defaulted_claimable, 150);
    assert_eq!(vault.total_withdrawn, 1_000);
    assert_eq!(vault.available(), 0);

    assert_eq!(
        env.reservation(&r1).effective_state(&vault),
        ReservationState::DefaultedByOwner
    );
    assert_eq!(
        env.reservation(&r2).effective_state(&vault),
        ReservationState::DefaultedByOwner
    );
    assert_eq!(
        env.reservation(&r3).effective_state(&vault),
        ReservationState::Released
    );

    let events = env.events::<VaultEmergencyExited>();
    assert_eq!(events.len(), 1);
    let e = &events[0];
    assert_eq!(e.recipient, recipient_token);
    assert_eq!((e.closed_epoch, e.new_epoch), (1, 2));
    assert_eq!(e.amount_withdrawn, 1_000);
    assert_eq!((e.affected_reserved, e.affected_claimable), (300, 150));
}

#[test]
fn emergency_exit_works_for_token_2022() {
    let mut env = Env::new();
    let f = env.ready_vault(TOKEN_2022, 1_000, manager(1), 1_000);
    let sponsor = f.sponsor.insecure_clone();
    env.send(
        &[f.exit_ix(&sponsor.pubkey(), &f.sponsor_token)],
        &[&sponsor],
    )
    .unwrap();
    assert_eq!(env.token_balance(&f.sponsor_token), 1_000);
    assert_eq!(env.token_balance(&f.vault_token), 0);
}

#[test]
fn emergency_exit_runs_once() {
    let mut env = Env::new();
    let f = env.vault_fixture(SPL_TOKEN, 0);
    let sponsor = f.sponsor.insecure_clone();
    env.send(
        &[f.exit_ix(&sponsor.pubkey(), &f.sponsor_token)],
        &[&sponsor],
    )
    .unwrap();
    assert_error(
        env.send(
            &[f.exit_ix(&sponsor.pubkey(), &f.sponsor_token)],
            &[&sponsor],
        ),
        E::VaultNotActive,
    );
}

#[test]
fn emergency_exit_rejects_non_sponsor() {
    let mut env = Env::new();
    let (f, _) = env.reserved_vault(400);
    let intruder = Keypair::new();
    let intruder_token = env.mint_to(&SPL_TOKEN, &f.mint, &intruder.pubkey(), 0);
    assert_error(
        env.send(
            &[f.exit_ix(&intruder.pubkey(), &intruder_token)],
            &[&intruder],
        ),
        E::NotSponsor,
    );
}

#[test]
fn revoke_settlement_resets_unclaimed_settlement_while_paused() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    env.stage_settlement(&f, &r, 350, 0);
    env.pause(true);
    let admin = env.admin.insecure_clone();
    env.send(&[f.revoke_ix(&admin.pubkey(), r)], &[&admin])
        .unwrap();

    let reservation = env.reservation(&r);
    assert_eq!(reservation.state, ReservationState::Reserved);
    assert_eq!(reservation.root, [0; 32]);
    assert_eq!(reservation.settled_total, 0);
    let vault = env.vault(&f.vault);
    assert_eq!(vault.total_reserved, 400);
    assert_eq!(vault.total_settled, 0);
    assert_eq!(vault.available(), 600);
    let events = env.events::<SettlementRevoked>();
    assert_eq!(events[0].root, [9; 32]);
    assert_eq!(events[0].settled_total, 350);

    // Back in the reserved state, the settlers can release it.
    let settler = env.settlers[0].insecure_clone();
    env.send(&[f.release_ix(&[&settler], r)], &[&settler])
        .unwrap();
}

#[test]
fn revoke_settlement_works_without_pause() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    env.stage_settlement(&f, &r, 400, 0);
    assert!(!env.config().paused);
    let admin = env.admin.insecure_clone();
    env.send(&[f.revoke_ix(&admin.pubkey(), r)], &[&admin])
        .unwrap();
    assert_eq!(env.reservation(&r).state, ReservationState::Reserved);
    assert_eq!(env.vault(&f.vault).total_settled, 0);
}

#[test]
fn revoke_settlement_rejects_claimed_or_unsettled_or_non_admin() {
    let mut env = Env::new();
    let (f, r) = env.reserved_vault(400);
    env.pause(true);
    let admin = env.admin.insecure_clone();
    assert_error(
        env.send(&[f.revoke_ix(&admin.pubkey(), r)], &[&admin]),
        E::ReservationWrongState,
    );
    env.stage_settlement(&f, &r, 400, 1);
    assert_error(
        env.send(&[f.revoke_ix(&admin.pubkey(), r)], &[&admin]),
        E::SettlementHasClaims,
    );
    let settler = env.settlers[0].insecure_clone();
    assert_error(
        env.send(&[f.revoke_ix(&settler.pubkey(), r)], &[&settler]),
        E::NotAdmin,
    );
}
