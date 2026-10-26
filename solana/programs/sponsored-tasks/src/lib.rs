use anchor_lang::prelude::*;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token_2022::spl_token_2022::extension::{
    BaseStateWithExtensions, ExtensionType, StateWithExtensions,
};
use anchor_spl::token_2022::spl_token_2022::state::Mint as MintState;
use anchor_spl::token_interface::{
    transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked,
};

pub mod error;
pub mod events;
pub mod state;

use error::SponsoredTasksError;
use events::*;
use state::*;

// Placeholder id with no keypair anywhere; the deploy task generates the real one outside the repo.
declare_id!("STvau1t111111111111111111111111111111111111");

/// Transfer fees break balance accounting, transfer hooks run foreign code inside vault
/// transfers, a permanent delegate can move the vault's balance, and non-transferable or
/// confidential balances cannot be paid out by an ordinary checked transfer.
pub const REJECTED_MINT_EXTENSIONS: [ExtensionType; 5] = [
    ExtensionType::TransferFeeConfig,
    ExtensionType::TransferHook,
    ExtensionType::PermanentDelegate,
    ExtensionType::NonTransferable,
    ExtensionType::ConfidentialTransferMint,
];

#[program]
pub mod sponsored_tasks {
    use super::*;

    pub fn init_config(
        ctx: Context<InitConfig>,
        admin: Pubkey,
        settlers: Vec<Pubkey>,
        threshold: u8,
        fee_bps: u16,
        fee_recipient: Pubkey,
    ) -> Result<()> {
        validate_settlers(&settlers, threshold)?;
        require!(fee_bps <= MAX_FEE_BPS, SponsoredTasksError::InvalidFeeBps);
        let config = &mut ctx.accounts.config;
        config.admin = admin;
        config.settlers = settlers.clone();
        config.threshold = threshold;
        config.paused = false;
        config.fee_bps = fee_bps;
        config.fee_recipient = fee_recipient;
        config.bump = ctx.bumps.config;
        emit_cpi!(ConfigInitialized {
            admin,
            settlers,
            threshold,
            fee_bps,
            fee_recipient,
        });
        Ok(())
    }

    pub fn set_admin(ctx: Context<AdminConfig>, new_admin: Pubkey) -> Result<()> {
        let previous = ctx.accounts.config.admin;
        ctx.accounts.config.admin = new_admin;
        emit_cpi!(AdminChanged {
            previous,
            admin: new_admin,
        });
        Ok(())
    }

    pub fn set_settlers(
        ctx: Context<AdminConfig>,
        settlers: Vec<Pubkey>,
        threshold: u8,
    ) -> Result<()> {
        validate_settlers(&settlers, threshold)?;
        ctx.accounts.config.settlers = settlers.clone();
        ctx.accounts.config.threshold = threshold;
        emit_cpi!(SettlersChanged {
            settlers,
            threshold
        });
        Ok(())
    }

    pub fn pause(ctx: Context<AdminConfig>, paused: bool) -> Result<()> {
        ctx.accounts.config.paused = paused;
        emit_cpi!(PauseSet { paused });
        Ok(())
    }

    pub fn create_vault(ctx: Context<CreateVault>, vault_id: u64) -> Result<()> {
        require!(!ctx.accounts.config.paused, SponsoredTasksError::Paused);
        check_mint_extensions(&ctx.accounts.mint.to_account_info())?;
        let vault = &mut ctx.accounts.vault;
        vault.sponsor = ctx.accounts.sponsor.key();
        vault.mint = ctx.accounts.mint.key();
        vault.token_program = ctx.accounts.token_program.key();
        vault.token_account = ctx.accounts.vault_token_account.key();
        vault.vault_id = vault_id;
        vault.status = VaultStatus::Active;
        vault.epoch = 1;
        vault.cap = 0;
        vault.total_funded = 0;
        vault.total_reserved = 0;
        vault.total_settled = 0;
        vault.total_claimed = 0;
        vault.total_withdrawn = 0;
        vault.total_defaulted_reserved = 0;
        vault.total_defaulted_claimable = 0;
        vault.managers = Vec::new();
        vault.bump = ctx.bumps.vault;
        emit_cpi!(VaultCreated {
            vault: vault.key(),
            sponsor: vault.sponsor,
            mint: vault.mint,
            token_program: vault.token_program,
            vault_id,
            epoch: vault.epoch,
        });
        Ok(())
    }

    pub fn set_caps(ctx: Context<SetCaps>, cap: u64) -> Result<()> {
        ctx.accounts.vault.cap = cap;
        emit_cpi!(VaultCapSet {
            vault: ctx.accounts.vault.key(),
            cap,
        });
        Ok(())
    }

    /// Open while paused, like the other paths that only add to or return sponsor funds.
    pub fn fund(ctx: Context<Fund>, amount: u64) -> Result<()> {
        require!(
            ctx.accounts.vault.status == VaultStatus::Active,
            SponsoredTasksError::VaultNotActive
        );
        require!(amount > 0, SponsoredTasksError::ZeroAmount);

        let before = ctx.accounts.vault_token_account.amount;
        transfer_checked(
            CpiContext::new(
                ctx.accounts.token_program.key(),
                TransferChecked {
                    from: ctx.accounts.funder_token_account.to_account_info(),
                    mint: ctx.accounts.mint.to_account_info(),
                    to: ctx.accounts.vault_token_account.to_account_info(),
                    authority: ctx.accounts.funder.to_account_info(),
                },
            ),
            amount,
            ctx.accounts.mint.decimals,
        )?;
        ctx.accounts.vault_token_account.reload()?;
        let received = ctx
            .accounts
            .vault_token_account
            .amount
            .checked_sub(before)
            .ok_or(SponsoredTasksError::TransferAmountMismatch)?;
        require!(
            received == amount,
            SponsoredTasksError::TransferAmountMismatch
        );

        let vault = &mut ctx.accounts.vault;
        vault.total_funded = vault
            .total_funded
            .checked_add(amount)
            .ok_or(SponsoredTasksError::Overflow)?;
        emit_cpi!(VaultFunded {
            vault: vault.key(),
            funder: ctx.accounts.funder.key(),
            amount,
        });
        Ok(())
    }

    /// Adds or updates managers; an existing manager's cap may not drop below what it has
    /// already reserved or spent.
    pub fn set_managers(ctx: Context<SetManagers>, managers: Vec<ManagerInput>) -> Result<()> {
        let vault_key = ctx.accounts.vault.key();
        let vault = &mut ctx.accounts.vault;
        require!(
            vault.status == VaultStatus::Active,
            SponsoredTasksError::VaultNotActive
        );
        for input in managers {
            let configured = match vault.managers.iter_mut().find(|m| m.key == input.key) {
                Some(existing) => {
                    let minimum = existing
                        .reserved
                        .checked_add(existing.spent)
                        .ok_or(SponsoredTasksError::Overflow)?;
                    require!(input.cap >= minimum, SponsoredTasksError::InvalidManagerCap);
                    existing.cap = input.cap;
                    existing.active = input.active;
                    *existing
                }
                None => {
                    require!(
                        vault.managers.len() < MAX_MANAGERS,
                        SponsoredTasksError::TooManyManagers
                    );
                    let manager = Manager {
                        key: input.key,
                        cap: input.cap,
                        reserved: 0,
                        spent: 0,
                        active: input.active,
                    };
                    vault.managers.push(manager);
                    manager
                }
            };
            emit_cpi!(ManagerConfigured {
                vault: vault_key,
                manager: configured.key,
                cap: configured.cap,
                reserved: configured.reserved,
                spent: configured.spent,
                active: configured.active,
            });
        }
        Ok(())
    }

    /// Settler-gated: the settler signatures come in as signer remaining accounts.
    #[allow(clippy::too_many_arguments)]
    pub fn reserve(
        ctx: Context<Reserve>,
        base_chain_id: u64,
        base_task_id: [u8; 32],
        nonce: u64,
        deadline: i64,
        amount: u64,
        manager: ManagerKey,
    ) -> Result<()> {
        let config = &ctx.accounts.config;
        require_settlers(config, ctx.remaining_accounts)?;
        require!(!config.paused, SponsoredTasksError::Paused);
        require!(amount > 0, SponsoredTasksError::ZeroAmount);
        require!(
            manager.chain_id == base_chain_id,
            SponsoredTasksError::ManagerChainMismatch
        );
        require!(
            deadline > Clock::get()?.unix_timestamp,
            SponsoredTasksError::DeadlineInPast
        );

        let vault_key = ctx.accounts.vault.key();
        let vault = &mut ctx.accounts.vault;
        require!(
            vault.status == VaultStatus::Active,
            SponsoredTasksError::VaultNotActive
        );
        let reserved_after = vault
            .total_reserved
            .checked_add(amount)
            .ok_or(SponsoredTasksError::Overflow)?;
        require!(
            reserved_after <= vault.cap,
            SponsoredTasksError::VaultCapExceeded
        );
        require!(
            amount <= vault.available(),
            SponsoredTasksError::InsufficientAvailable
        );
        let account = vault
            .managers
            .iter_mut()
            .find(|m| m.key == manager)
            .ok_or(SponsoredTasksError::ManagerNotActive)?;
        require!(account.active, SponsoredTasksError::ManagerNotActive);
        let remaining = account
            .cap
            .saturating_sub(account.reserved)
            .saturating_sub(account.spent);
        require!(
            amount <= remaining,
            SponsoredTasksError::ManagerAllowanceExceeded
        );
        account.reserved += amount;
        vault.total_reserved = reserved_after;
        let epoch = vault.epoch;

        let reservation = &mut ctx.accounts.reservation;
        reservation.vault = vault_key;
        reservation.epoch = epoch;
        reservation.base_chain_id = base_chain_id;
        reservation.base_task_id = base_task_id;
        reservation.nonce = nonce;
        reservation.deadline = deadline;
        reservation.manager = manager;
        reservation.amount = amount;
        reservation.state = ReservationState::Reserved;
        reservation.root = [0; 32];
        reservation.settled_total = 0;
        reservation.claimed_count = 0;
        reservation.bump = ctx.bumps.reservation;
        emit_cpi!(TaskReserved {
            vault: vault_key,
            reservation: reservation.key(),
            base_chain_id,
            base_task_id,
            manager,
            epoch,
            nonce,
            deadline,
            amount,
        });
        Ok(())
    }

    /// Settler-gated and open while paused. Releasing an already released reservation is a no-op.
    pub fn release(ctx: Context<Release>) -> Result<()> {
        require_settlers(&ctx.accounts.config, ctx.remaining_accounts)?;
        let vault_key = ctx.accounts.vault.key();
        let vault = &mut ctx.accounts.vault;
        require!(
            vault.status == VaultStatus::Active,
            SponsoredTasksError::VaultNotActive
        );
        let reservation = &mut ctx.accounts.reservation;
        require!(
            reservation.epoch == vault.epoch,
            SponsoredTasksError::EpochMismatch
        );
        match reservation.state {
            ReservationState::Released => return Ok(()),
            ReservationState::Reserved => {}
            _ => return err!(SponsoredTasksError::ReservationWrongState),
        }
        let amount = reservation.amount;
        if let Some(account) = vault
            .managers
            .iter_mut()
            .find(|m| m.key == reservation.manager)
        {
            account.reserved = account.reserved.saturating_sub(amount);
        }
        vault.total_reserved = vault
            .total_reserved
            .checked_sub(amount)
            .ok_or(SponsoredTasksError::Overflow)?;
        reservation.state = ReservationState::Released;
        emit_cpi!(TaskReleased {
            vault: vault_key,
            reservation: reservation.key(),
            base_chain_id: reservation.base_chain_id,
            base_task_id: reservation.base_task_id,
            manager: reservation.manager,
            amount,
        });
        Ok(())
    }

    /// Admin-only and only while paused: undoes a settlement nobody has claimed against, so the
    /// settlers can sign a corrected root.
    pub fn revoke_settlement(ctx: Context<RevokeSettlement>) -> Result<()> {
        require!(ctx.accounts.config.paused, SponsoredTasksError::NotPaused);
        let vault_key = ctx.accounts.vault.key();
        let vault = &mut ctx.accounts.vault;
        require!(
            vault.status == VaultStatus::Active,
            SponsoredTasksError::VaultNotActive
        );
        let reservation = &mut ctx.accounts.reservation;
        require!(
            reservation.epoch == vault.epoch,
            SponsoredTasksError::EpochMismatch
        );
        require!(
            reservation.state == ReservationState::Settled,
            SponsoredTasksError::ReservationWrongState
        );
        require!(
            reservation.claimed_count == 0,
            SponsoredTasksError::SettlementHasClaims
        );
        let settled_total = reservation.settled_total;
        vault.total_settled = vault
            .total_settled
            .checked_sub(settled_total)
            .ok_or(SponsoredTasksError::Overflow)?;
        vault.total_reserved = vault
            .total_reserved
            .checked_add(reservation.amount)
            .ok_or(SponsoredTasksError::Overflow)?;
        let root = reservation.root;
        reservation.state = ReservationState::Reserved;
        reservation.root = [0; 32];
        reservation.settled_total = 0;
        emit_cpi!(SettlementRevoked {
            vault: vault_key,
            reservation: reservation.key(),
            root,
            settled_total,
        });
        Ok(())
    }

    /// Sponsor-only and open while paused. Takes the whole token balance, defaults every open
    /// reservation and unclaimed award by advancing the epoch, and closes the vault.
    pub fn emergency_exit(ctx: Context<EmergencyExit>) -> Result<()> {
        let vault = &ctx.accounts.vault;
        require!(
            vault.status == VaultStatus::Active,
            SponsoredTasksError::VaultNotActive
        );
        let amount = ctx.accounts.vault_token_account.amount;

        if amount > 0 {
            let mint_key = vault.mint;
            let sponsor_key = vault.sponsor;
            let id_bytes = vault.vault_id.to_le_bytes();
            let bump = [vault.bump];
            let seeds: &[&[u8]] = &[
                VAULT_SEED,
                mint_key.as_ref(),
                sponsor_key.as_ref(),
                &id_bytes,
                &bump,
            ];
            let signer = &[seeds];
            transfer_checked(
                CpiContext::new_with_signer(
                    ctx.accounts.token_program.key(),
                    TransferChecked {
                        from: ctx.accounts.vault_token_account.to_account_info(),
                        mint: ctx.accounts.mint.to_account_info(),
                        to: ctx.accounts.recipient_token_account.to_account_info(),
                        authority: ctx.accounts.vault.to_account_info(),
                    },
                    signer,
                ),
                amount,
                ctx.accounts.mint.decimals,
            )?;
        }

        let vault_key = ctx.accounts.vault.key();
        let vault = &mut ctx.accounts.vault;
        let closed_epoch = vault.epoch;
        let affected_reserved = vault.total_reserved;
        let affected_claimable = vault.claimable();
        vault.status = VaultStatus::Exited;
        vault.epoch = closed_epoch
            .checked_add(1)
            .ok_or(SponsoredTasksError::Overflow)?;
        vault.total_defaulted_reserved = vault
            .total_defaulted_reserved
            .checked_add(affected_reserved)
            .ok_or(SponsoredTasksError::Overflow)?;
        vault.total_defaulted_claimable = vault
            .total_defaulted_claimable
            .checked_add(affected_claimable)
            .ok_or(SponsoredTasksError::Overflow)?;
        vault.total_reserved = 0;
        vault.total_settled = vault.total_claimed;
        vault.total_withdrawn = vault
            .total_withdrawn
            .checked_add(amount)
            .ok_or(SponsoredTasksError::Overflow)?;
        emit_cpi!(VaultEmergencyExited {
            vault: vault_key,
            sponsor: vault.sponsor,
            recipient: ctx.accounts.recipient_token_account.key(),
            closed_epoch,
            new_epoch: vault.epoch,
            amount_withdrawn: amount,
            affected_reserved,
            affected_claimable,
        });
        Ok(())
    }
}

fn validate_settlers(settlers: &[Pubkey], threshold: u8) -> Result<()> {
    require!(
        !settlers.is_empty() && settlers.len() <= MAX_SETTLERS,
        SponsoredTasksError::InvalidSettlers
    );
    for (i, s) in settlers.iter().enumerate() {
        require!(
            !settlers[..i].contains(s),
            SponsoredTasksError::InvalidSettlers
        );
    }
    require!(
        threshold >= 1 && threshold as usize <= settlers.len(),
        SponsoredTasksError::InvalidThreshold
    );
    Ok(())
}

fn require_settlers(config: &Config, signers: &[AccountInfo]) -> Result<()> {
    let mut seen: Vec<Pubkey> = Vec::with_capacity(MAX_SETTLERS);
    for info in signers {
        if info.is_signer && config.settlers.contains(info.key) && !seen.contains(info.key) {
            seen.push(*info.key);
        }
    }
    require!(
        seen.len() >= config.threshold as usize,
        SponsoredTasksError::SettlerThresholdNotMet
    );
    Ok(())
}

fn check_mint_extensions(mint: &AccountInfo) -> Result<()> {
    if *mint.owner != anchor_spl::token_2022::ID {
        return Ok(());
    }
    let data = mint.try_borrow_data()?;
    let state = StateWithExtensions::<MintState>::unpack(&data)?;
    let types = state.get_extension_types()?;
    require!(
        !types.iter().any(|t| REJECTED_MINT_EXTENSIONS.contains(t)),
        SponsoredTasksError::UnsupportedMintExtension
    );
    Ok(())
}

#[event_cpi]
#[derive(Accounts)]
pub struct InitConfig<'info> {
    #[account(
        init,
        payer = authority,
        space = 8 + Config::INIT_SPACE,
        seeds = [CONFIG_SEED],
        bump
    )]
    pub config: Account<'info, Config>,
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(constraint = this_program.programdata_address()? == Some(program_data.key()))]
    pub this_program: Program<'info, program::SponsoredTasks>,
    #[account(
        constraint = program_data.upgrade_authority_address == Some(authority.key())
            @ SponsoredTasksError::NotAdmin
    )]
    pub program_data: Account<'info, ProgramData>,
    pub system_program: Program<'info, System>,
}

#[event_cpi]
#[derive(Accounts)]
pub struct AdminConfig<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        has_one = admin @ SponsoredTasksError::NotAdmin
    )]
    pub config: Account<'info, Config>,
    pub admin: Signer<'info>,
}

#[event_cpi]
#[derive(Accounts)]
#[instruction(vault_id: u64)]
pub struct CreateVault<'info> {
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut)]
    pub sponsor: Signer<'info>,
    #[account(mint::token_program = token_program)]
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(
        init,
        payer = sponsor,
        space = 8 + Vault::INIT_SPACE,
        seeds = [VAULT_SEED, mint.key().as_ref(), sponsor.key().as_ref(), &vault_id.to_le_bytes()],
        bump
    )]
    pub vault: Account<'info, Vault>,
    #[account(
        init,
        payer = sponsor,
        associated_token::mint = mint,
        associated_token::authority = vault,
        associated_token::token_program = token_program
    )]
    pub vault_token_account: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

#[event_cpi]
#[derive(Accounts)]
pub struct SetCaps<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        has_one = admin @ SponsoredTasksError::NotAdmin
    )]
    pub config: Account<'info, Config>,
    pub admin: Signer<'info>,
    #[account(mut)]
    pub vault: Account<'info, Vault>,
}

#[event_cpi]
#[derive(Accounts)]
pub struct Fund<'info> {
    #[account(mut, has_one = mint, has_one = token_program)]
    pub vault: Account<'info, Vault>,
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(mut, address = vault.token_account)]
    pub vault_token_account: InterfaceAccount<'info, TokenAccount>,
    pub funder: Signer<'info>,
    #[account(
        mut,
        token::mint = mint,
        token::authority = funder,
        token::token_program = token_program
    )]
    pub funder_token_account: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
}

#[event_cpi]
#[derive(Accounts)]
pub struct SetManagers<'info> {
    #[account(mut, has_one = sponsor @ SponsoredTasksError::NotSponsor)]
    pub vault: Account<'info, Vault>,
    pub sponsor: Signer<'info>,
}

#[event_cpi]
#[derive(Accounts)]
#[instruction(base_chain_id: u64, base_task_id: [u8; 32])]
pub struct Reserve<'info> {
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut)]
    pub vault: Account<'info, Vault>,
    #[account(
        init,
        payer = payer,
        space = 8 + Reservation::INIT_SPACE,
        seeds = [RESERVATION_SEED, vault.key().as_ref(), &base_chain_id.to_le_bytes(), &base_task_id],
        bump
    )]
    pub reservation: Account<'info, Reservation>,
    #[account(mut)]
    pub payer: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[event_cpi]
#[derive(Accounts)]
pub struct Release<'info> {
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut)]
    pub vault: Account<'info, Vault>,
    #[account(mut, has_one = vault)]
    pub reservation: Account<'info, Reservation>,
}

#[event_cpi]
#[derive(Accounts)]
pub struct RevokeSettlement<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        has_one = admin @ SponsoredTasksError::NotAdmin
    )]
    pub config: Account<'info, Config>,
    pub admin: Signer<'info>,
    #[account(mut)]
    pub vault: Account<'info, Vault>,
    #[account(mut, has_one = vault)]
    pub reservation: Account<'info, Reservation>,
}

#[event_cpi]
#[derive(Accounts)]
pub struct EmergencyExit<'info> {
    #[account(
        mut,
        has_one = sponsor @ SponsoredTasksError::NotSponsor,
        has_one = mint,
        has_one = token_program
    )]
    pub vault: Account<'info, Vault>,
    pub sponsor: Signer<'info>,
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(mut, address = vault.token_account)]
    pub vault_token_account: InterfaceAccount<'info, TokenAccount>,
    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub recipient_token_account: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
}
