#![allow(dead_code, clippy::result_large_err)]

use anchor_lang::prelude::{AccountMeta, Pubkey};
use anchor_lang::{
    AccountDeserialize, AccountSerialize, AnchorDeserialize, Discriminator, InstructionData,
    ToAccountMetas,
};
use litesvm::types::{FailedTransactionMetadata, TransactionMetadata};
use litesvm::LiteSVM;
use solana_instruction::Instruction;
use solana_keypair::Keypair;
use solana_message::Message;
use solana_program_pack::Pack;
use solana_signer::Signer;
use solana_transaction::Transaction;
use spl_associated_token_account_interface::address::get_associated_token_address_with_program_id;
use spl_token_2022_interface::extension::{ExtensionType, StateWithExtensions};
use sponsored_tasks::error::SponsoredTasksError;
use sponsored_tasks::state::{
    Config, ManagerInput, ManagerKey, Reservation, Vault, CONFIG_SEED, RESERVATION_SEED, VAULT_SEED,
};
use sponsored_tasks::{accounts, instruction, ID};

const PROGRAM_SO: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../target/deploy/sponsored_tasks.so"
);

pub const SPL_TOKEN: Pubkey = spl_token_interface::ID;
pub const TOKEN_2022: Pubkey = spl_token_2022_interface::ID;
pub const DECIMALS: u8 = 6;
pub const BASE_CHAIN_ID: u64 = 8453;
pub const TEMPO_CHAIN_ID: u64 = 4217;
pub const DEADLINE: i64 = 1_000_000;

pub fn code(e: SponsoredTasksError) -> u32 {
    e as u32 + anchor_lang::error::ERROR_CODE_OFFSET
}

pub fn assert_custom(result: Result<(), FailedTransactionMetadata>, expected: u32) {
    let err = result.expect_err("transaction should fail");
    let text = format!("{:?}", err.err);
    assert!(
        text.contains(&format!("Custom({expected})")),
        "expected Custom({expected}), got {text}\nlogs: {:#?}",
        err.meta.logs
    );
}

pub fn assert_error(result: Result<(), FailedTransactionMetadata>, e: SponsoredTasksError) {
    assert_custom(result, code(e));
}

pub fn manager(n: u8) -> ManagerKey {
    manager_on(BASE_CHAIN_ID, n)
}

pub fn manager_on(chain_id: u64, n: u8) -> ManagerKey {
    ManagerKey {
        chain_id,
        evm_address: [n; 20],
    }
}

pub fn config_pda() -> Pubkey {
    Pubkey::find_program_address(&[CONFIG_SEED], &ID).0
}

pub fn event_authority() -> Pubkey {
    Pubkey::find_program_address(&[b"__event_authority"], &ID).0
}

pub fn vault_pda(mint: &Pubkey, sponsor: &Pubkey, vault_id: u64) -> Pubkey {
    Pubkey::find_program_address(
        &[
            VAULT_SEED,
            mint.as_ref(),
            sponsor.as_ref(),
            &vault_id.to_le_bytes(),
        ],
        &ID,
    )
    .0
}

pub fn reservation_pda(vault: &Pubkey, task_id: &[u8; 32]) -> Pubkey {
    Pubkey::find_program_address(
        &[
            RESERVATION_SEED,
            vault.as_ref(),
            &BASE_CHAIN_ID.to_le_bytes(),
            task_id,
        ],
        &ID,
    )
    .0
}

pub fn task_id(n: u8) -> [u8; 32] {
    let mut id = [0u8; 32];
    id[31] = n;
    id
}

pub fn programdata_pda() -> Pubkey {
    Pubkey::find_program_address(
        &[ID.as_ref()],
        &anchor_lang::solana_program::bpf_loader_upgradeable::ID,
    )
    .0
}

pub struct Env {
    pub svm: LiteSVM,
    pub payer: Keypair,
    pub upgrade_authority: Keypair,
    pub admin: Keypair,
    pub settlers: Vec<Keypair>,
    pub last: Option<TransactionMetadata>,
}

impl Env {
    /// Program loaded with `upgrade_authority` as its upgrade authority; config not yet created.
    pub fn bare() -> Self {
        let mut svm = LiteSVM::new();
        svm.add_program_from_file(ID, PROGRAM_SO)
            .expect("run `make contract solana build` first");
        let upgrade_authority = Keypair::new();
        let pd = programdata_pda();
        let mut account = svm.get_account(&pd).expect("programdata");
        // ProgramData metadata: u32 tag, u64 slot, Option<Pubkey> authority.
        account.data[12] = 1;
        account.data[13..45].copy_from_slice(upgrade_authority.pubkey().as_ref());
        svm.set_account(pd, account).unwrap();

        let payer = Keypair::new();
        let admin = Keypair::new();
        let settlers: Vec<Keypair> = (0..3).map(|_| Keypair::new()).collect();
        for k in [&payer, &upgrade_authority, &admin]
            .into_iter()
            .chain(settlers.iter())
        {
            svm.airdrop(&k.pubkey(), 100_000_000_000).unwrap();
        }
        Env {
            svm,
            payer,
            upgrade_authority,
            admin,
            settlers,
            last: None,
        }
    }

    /// Config initialised with one settler, threshold 1.
    pub fn new() -> Self {
        Self::with_threshold(1, 1)
    }

    pub fn with_threshold(settler_count: usize, threshold: u8) -> Self {
        let mut env = Self::bare();
        let settlers = env.settlers[..settler_count]
            .iter()
            .map(|k| k.pubkey())
            .collect();
        let authority = env.upgrade_authority.insecure_clone();
        env.init_config(&authority, settlers, threshold, 750)
            .unwrap();
        env
    }

    pub fn send(
        &mut self,
        ixs: &[Instruction],
        signers: &[&Keypair],
    ) -> Result<(), FailedTransactionMetadata> {
        self.svm.expire_blockhash();
        let mut all: Vec<&Keypair> = vec![&self.payer];
        all.extend_from_slice(signers);
        let msg = Message::new(ixs, Some(&self.payer.pubkey()));
        let tx = Transaction::new(&all, msg, self.svm.latest_blockhash());
        let meta = self.svm.send_transaction(tx)?;
        self.last = Some(meta);
        Ok(())
    }

    /// Events of type `T` emitted through self-CPI by the last successful transaction.
    pub fn events<T: AnchorDeserialize + Discriminator>(&self) -> Vec<T> {
        let meta = self.last.as_ref().expect("a transaction ran");
        let prefix: Vec<u8> = anchor_lang::event::EVENT_IX_TAG_LE
            .iter()
            .chain(T::DISCRIMINATOR.iter())
            .copied()
            .collect();
        meta.inner_instructions
            .iter()
            .flatten()
            .filter_map(|inner| {
                let data = &inner.instruction.data;
                data.starts_with(&prefix)
                    .then(|| T::deserialize(&mut &data[prefix.len()..]).unwrap())
            })
            .collect()
    }

    pub fn init_config(
        &mut self,
        authority: &Keypair,
        settlers: Vec<Pubkey>,
        threshold: u8,
        fee_bps: u16,
    ) -> Result<(), FailedTransactionMetadata> {
        let ix = Instruction {
            program_id: ID,
            accounts: accounts::InitConfig {
                config: config_pda(),
                authority: authority.pubkey(),
                this_program: ID,
                program_data: programdata_pda(),
                system_program: anchor_lang::system_program::ID,
                event_authority: event_authority(),
                program: ID,
            }
            .to_account_metas(None),
            data: instruction::InitConfig {
                admin: self.admin.pubkey(),
                settlers,
                threshold,
                fee_bps,
                fee_recipient: Pubkey::new_unique(),
            }
            .data(),
        };
        self.send(&[ix], &[authority])
    }

    pub fn account<T: AccountDeserialize>(&self, key: &Pubkey) -> T {
        let account = self.svm.get_account(key).expect("account exists");
        T::try_deserialize(&mut account.data.as_slice()).unwrap()
    }

    /// Overwrites a program account in place, to stage states no built instruction reaches yet.
    pub fn write<T: AccountSerialize>(&mut self, key: &Pubkey, value: &T) {
        let mut account = self.svm.get_account(key).expect("account exists");
        let mut data = Vec::new();
        value.try_serialize(&mut data).unwrap();
        account.data[..data.len()].copy_from_slice(&data);
        self.svm.set_account(*key, account).unwrap();
    }

    pub fn config(&self) -> Config {
        self.account(&config_pda())
    }

    pub fn vault(&self, key: &Pubkey) -> Vault {
        self.account(key)
    }

    pub fn reservation(&self, key: &Pubkey) -> Reservation {
        self.account(key)
    }

    pub fn token_balance(&self, token_account: &Pubkey) -> u64 {
        let account = self.svm.get_account(token_account).unwrap();
        StateWithExtensions::<spl_token_2022_interface::state::Account>::unpack(&account.data)
            .unwrap()
            .base
            .amount
    }

    /// Creates a mint under `token_program`, running `extension_ixs` before initialising it.
    pub fn create_mint_with(
        &mut self,
        token_program: &Pubkey,
        extensions: &[ExtensionType],
        extension_ixs: impl Fn(&Pubkey) -> Vec<Instruction>,
    ) -> Pubkey {
        let mint = Keypair::new();
        let space = if extensions.is_empty() {
            spl_token_2022_interface::state::Mint::LEN
        } else {
            ExtensionType::try_calculate_account_len::<spl_token_2022_interface::state::Mint>(
                extensions,
            )
            .unwrap()
        };
        let lamports = self.svm.minimum_balance_for_rent_exemption(space);
        let mut ixs = vec![solana_system_interface::instruction::create_account(
            &self.payer.pubkey(),
            &mint.pubkey(),
            lamports,
            space as u64,
            token_program,
        )];
        ixs.extend(extension_ixs(&mint.pubkey()));
        ixs.push(
            spl_token_2022_interface::instruction::initialize_mint2(
                token_program,
                &mint.pubkey(),
                &self.payer.pubkey(),
                Some(&self.payer.pubkey()),
                DECIMALS,
            )
            .unwrap(),
        );
        self.send(&ixs, &[&mint]).expect("create mint");
        mint.pubkey()
    }

    pub fn create_mint(&mut self, token_program: &Pubkey) -> Pubkey {
        self.create_mint_with(token_program, &[], |_| vec![])
    }

    /// Creates `owner`'s associated token account if needed and mints `amount` into it.
    pub fn mint_to(
        &mut self,
        token_program: &Pubkey,
        mint: &Pubkey,
        owner: &Pubkey,
        amount: u64,
    ) -> Pubkey {
        let ata = get_associated_token_address_with_program_id(owner, mint, token_program);
        let mut ixs = Vec::new();
        if self.svm.get_account(&ata).is_none() {
            ixs.push(
                spl_associated_token_account_interface::instruction::create_associated_token_account(
                    &self.payer.pubkey(),
                    owner,
                    mint,
                    token_program,
                ),
            );
        }
        if amount > 0 {
            ixs.push(
                spl_token_2022_interface::instruction::mint_to(
                    token_program,
                    mint,
                    &ata,
                    &self.payer.pubkey(),
                    &[],
                    amount,
                )
                .unwrap(),
            );
        }
        if !ixs.is_empty() {
            self.send(&ixs, &[]).expect("mint to");
        }
        ata
    }

    pub fn pause(&mut self, paused: bool) {
        let admin = self.admin.insecure_clone();
        self.send(&[pause_ix(&admin.pubkey(), paused)], &[&admin])
            .expect("pause");
    }
}

pub struct VaultFixture {
    pub sponsor: Keypair,
    pub mint: Pubkey,
    pub token_program: Pubkey,
    pub vault: Pubkey,
    pub vault_token: Pubkey,
    pub sponsor_token: Pubkey,
    pub vault_id: u64,
}

pub fn create_vault_ix(
    sponsor: &Pubkey,
    mint: &Pubkey,
    token_program: &Pubkey,
    vault_id: u64,
) -> Instruction {
    let vault = vault_pda(mint, sponsor, vault_id);
    Instruction {
        program_id: ID,
        accounts: accounts::CreateVault {
            config: config_pda(),
            sponsor: *sponsor,
            mint: *mint,
            vault,
            vault_token_account: get_associated_token_address_with_program_id(
                &vault,
                mint,
                token_program,
            ),
            token_program: *token_program,
            associated_token_program: spl_associated_token_account_interface::program::ID,
            system_program: anchor_lang::system_program::ID,
            event_authority: event_authority(),
            program: ID,
        }
        .to_account_metas(None),
        data: instruction::CreateVault { vault_id }.data(),
    }
}

fn settler_metas(settlers: &[&Keypair]) -> Vec<AccountMeta> {
    settlers
        .iter()
        .map(|k| AccountMeta::new_readonly(k.pubkey(), true))
        .collect()
}

impl VaultFixture {
    pub fn fund_ix(&self, funder: &Pubkey, funder_token: &Pubkey, amount: u64) -> Instruction {
        Instruction {
            program_id: ID,
            accounts: accounts::Fund {
                vault: self.vault,
                mint: self.mint,
                vault_token_account: self.vault_token,
                funder: *funder,
                funder_token_account: *funder_token,
                token_program: self.token_program,
                event_authority: event_authority(),
                program: ID,
            }
            .to_account_metas(None),
            data: instruction::Fund { amount }.data(),
        }
    }

    pub fn set_managers_ix(&self, sponsor: &Pubkey, managers: Vec<ManagerInput>) -> Instruction {
        Instruction {
            program_id: ID,
            accounts: accounts::SetManagers {
                vault: self.vault,
                sponsor: *sponsor,
                event_authority: event_authority(),
                program: ID,
            }
            .to_account_metas(None),
            data: instruction::SetManagers { managers }.data(),
        }
    }

    pub fn reserve_ix(
        &self,
        payer: &Pubkey,
        settlers: &[&Keypair],
        task: [u8; 32],
        amount: u64,
        manager: ManagerKey,
    ) -> Instruction {
        self.reserve_ix_with(payer, settlers, task, DEADLINE, amount, manager)
    }

    pub fn reserve_ix_with(
        &self,
        payer: &Pubkey,
        settlers: &[&Keypair],
        task: [u8; 32],
        deadline: i64,
        amount: u64,
        manager: ManagerKey,
    ) -> Instruction {
        let mut metas = accounts::Reserve {
            config: config_pda(),
            vault: self.vault,
            reservation: reservation_pda(&self.vault, &task),
            payer: *payer,
            system_program: anchor_lang::system_program::ID,
            event_authority: event_authority(),
            program: ID,
        }
        .to_account_metas(None);
        metas.extend(settler_metas(settlers));
        Instruction {
            program_id: ID,
            accounts: metas,
            data: instruction::Reserve {
                base_chain_id: BASE_CHAIN_ID,
                base_task_id: task,
                nonce: 1,
                deadline,
                amount,
                manager,
            }
            .data(),
        }
    }

    pub fn release_ix(&self, settlers: &[&Keypair], reservation: Pubkey) -> Instruction {
        let mut metas = accounts::Release {
            config: config_pda(),
            vault: self.vault,
            reservation,
            event_authority: event_authority(),
            program: ID,
        }
        .to_account_metas(None);
        metas.extend(settler_metas(settlers));
        Instruction {
            program_id: ID,
            accounts: metas,
            data: instruction::Release {}.data(),
        }
    }

    pub fn revoke_ix(&self, admin: &Pubkey, reservation: Pubkey) -> Instruction {
        Instruction {
            program_id: ID,
            accounts: accounts::RevokeSettlement {
                config: config_pda(),
                admin: *admin,
                vault: self.vault,
                reservation,
                event_authority: event_authority(),
                program: ID,
            }
            .to_account_metas(None),
            data: instruction::RevokeSettlement {}.data(),
        }
    }

    pub fn exit_ix(&self, sponsor: &Pubkey, recipient_token: &Pubkey) -> Instruction {
        Instruction {
            program_id: ID,
            accounts: accounts::EmergencyExit {
                vault: self.vault,
                sponsor: *sponsor,
                mint: self.mint,
                vault_token_account: self.vault_token,
                recipient_token_account: *recipient_token,
                token_program: self.token_program,
                event_authority: event_authority(),
                program: ID,
            }
            .to_account_metas(None),
            data: instruction::EmergencyExit {}.data(),
        }
    }

    pub fn set_caps_ix(&self, admin: &Pubkey, cap: u64) -> Instruction {
        Instruction {
            program_id: ID,
            accounts: accounts::SetCaps {
                config: config_pda(),
                admin: *admin,
                vault: self.vault,
                event_authority: event_authority(),
                program: ID,
            }
            .to_account_metas(None),
            data: instruction::SetCaps { cap }.data(),
        }
    }
}

fn admin_accounts(admin: &Pubkey) -> Vec<AccountMeta> {
    accounts::AdminConfig {
        config: config_pda(),
        admin: *admin,
        event_authority: event_authority(),
        program: ID,
    }
    .to_account_metas(None)
}

pub fn pause_ix(admin: &Pubkey, paused: bool) -> Instruction {
    Instruction {
        program_id: ID,
        accounts: admin_accounts(admin),
        data: instruction::Pause { paused }.data(),
    }
}

pub fn set_admin_ix(admin: &Pubkey, new_admin: Pubkey) -> Instruction {
    Instruction {
        program_id: ID,
        accounts: admin_accounts(admin),
        data: instruction::SetAdmin { new_admin }.data(),
    }
}

pub fn set_settlers_ix(admin: &Pubkey, settlers: Vec<Pubkey>, threshold: u8) -> Instruction {
    Instruction {
        program_id: ID,
        accounts: admin_accounts(admin),
        data: instruction::SetSettlers {
            settlers,
            threshold,
        }
        .data(),
    }
}

impl Env {
    /// A vault whose sponsor holds `minted` tokens: not funded, cap zero, no managers.
    pub fn vault_fixture(&mut self, token_program: Pubkey, minted: u64) -> VaultFixture {
        let mint = self.create_mint(&token_program);
        self.vault_fixture_for(token_program, mint, minted)
    }

    pub fn vault_fixture_for(
        &mut self,
        token_program: Pubkey,
        mint: Pubkey,
        minted: u64,
    ) -> VaultFixture {
        let sponsor = Keypair::new();
        self.svm.airdrop(&sponsor.pubkey(), 10_000_000_000).unwrap();
        let sponsor_token = self.mint_to(&token_program, &mint, &sponsor.pubkey(), minted);
        let vault_id = 7;
        let vault = vault_pda(&mint, &sponsor.pubkey(), vault_id);
        let ix = create_vault_ix(&sponsor.pubkey(), &mint, &token_program, vault_id);
        self.send(&[ix], &[&sponsor]).expect("create vault");
        VaultFixture {
            vault_token: get_associated_token_address_with_program_id(
                &vault,
                &mint,
                &token_program,
            ),
            sponsor,
            mint,
            token_program,
            vault,
            sponsor_token,
            vault_id,
        }
    }

    /// Funded with `funded`, vault cap `cap`, one active manager with allowance `allowance`.
    pub fn ready_vault(
        &mut self,
        token_program: Pubkey,
        funded: u64,
        cap: u64,
        key: ManagerKey,
        allowance: u64,
    ) -> VaultFixture {
        let f = self.vault_fixture(token_program, funded);
        let sponsor = f.sponsor.insecure_clone();
        let admin = self.admin.insecure_clone();
        self.send(
            &[
                f.fund_ix(&sponsor.pubkey(), &f.sponsor_token, funded),
                f.set_managers_ix(
                    &sponsor.pubkey(),
                    vec![ManagerInput {
                        key,
                        cap: allowance,
                        active: true,
                    }],
                ),
            ],
            &[&sponsor],
        )
        .expect("fund and set managers");
        self.send(&[f.set_caps_ix(&admin.pubkey(), cap)], &[&admin])
            .expect("set vault cap");
        f
    }

    /// A 1_000-token SPL vault with one `amount` reservation for `task_id(1)` by `manager(1)`.
    pub fn reserved_vault(&mut self, amount: u64) -> (VaultFixture, Pubkey) {
        let f = self.ready_vault(SPL_TOKEN, 1_000, 1_000, manager(1), 1_000);
        let settler = self.settlers[0].insecure_clone();
        let payer = self.payer.pubkey();
        self.send(
            &[f.reserve_ix(&payer, &[&settler], task_id(1), amount, manager(1))],
            &[&settler],
        )
        .unwrap();
        let r = reservation_pda(&f.vault, &task_id(1));
        (f, r)
    }

    /// Stages what `settle` will leave behind: the reservation settled with `root` and
    /// `settled_total`, and the vault totals moved from reserved to settled.
    pub fn stage_settlement(
        &mut self,
        f: &VaultFixture,
        r: &Pubkey,
        settled_total: u64,
        claimed_count: u32,
    ) {
        let mut reservation = self.reservation(r);
        reservation.state = sponsored_tasks::state::ReservationState::Settled;
        reservation.root = [9; 32];
        reservation.settled_total = settled_total;
        reservation.claimed_count = claimed_count;
        self.write(r, &reservation);
        let mut vault = self.vault(&f.vault);
        vault.total_reserved -= reservation.amount;
        vault.total_settled += settled_total;
        self.write(&f.vault, &vault);
    }
}
