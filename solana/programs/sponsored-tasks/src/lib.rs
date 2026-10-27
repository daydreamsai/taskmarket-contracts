use anchor_lang::prelude::*;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token_2022::spl_token_2022::extension::{
    BaseStateWithExtensions, ExtensionType, StateWithExtensions,
};
use anchor_spl::token_2022::spl_token_2022::state::Mint as MintState;
use anchor_spl::token_interface::{
    transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked,
};
use solana_keccak_hasher as keccak;
use solana_secp256k1_recover::secp256k1_recover;

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

/// EIP-712 domain of the payout binding a Base agent signs. `chainId` is the agent's EVM chain and
/// `salt` is this program's id, so a binding cannot be replayed on another chain or program.
pub const PAYOUT_DOMAIN_NAME: &str = "Taskmarket Sponsored Tasks";
pub const PAYOUT_DOMAIN_VERSION: &str = "1";
const EIP712_DOMAIN_TYPE: &[u8] =
    b"EIP712Domain(string name,string version,uint256 chainId,bytes32 salt)";
const PAYOUT_BINDING_TYPE: &[u8] = b"PayoutBinding(address agent,bytes32 payout,uint64 nonce)";

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
        config.claim_delay_seconds = DEFAULT_CLAIM_DELAY_SECONDS;
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

    /// Admin-only and open while paused. Sets how long after `settle` claims wait, so the root
    /// watcher can flag a forged root and the admin can revoke it before it pays.
    pub fn set_claim_delay(ctx: Context<AdminConfig>, claim_delay_seconds: u64) -> Result<()> {
        require!(
            claim_delay_seconds > 0 && claim_delay_seconds <= i64::MAX as u64,
            SponsoredTasksError::InvalidClaimDelay
        );
        ctx.accounts.config.claim_delay_seconds = claim_delay_seconds;
        emit_cpi!(ClaimDelaySet {
            claim_delay_seconds
        });
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
        reservation.leaf_count = 0;
        reservation.settled_total = 0;
        reservation.fee_total = 0;
        reservation.claimed_count = 0;
        reservation.claimed_total = 0;
        reservation.fee_claimed = false;
        reservation.bump = ctx.bumps.reservation;
        reservation.settled_at = 0;
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

    /// Settler-gated and blocked while paused. Installs the award root of a reserved task, as
    /// the EVM vault's `installSettlement`: `settled_total` is the sum of the leaves' net
    /// amounts, `fee_total` the fee carved from `distributed_gross`, and the reserved amount the
    /// awards do not cover returns to the vault's available balance. A second settle fails.
    pub fn settle(
        ctx: Context<Settle>,
        root: [u8; 32],
        leaf_count: u32,
        distributed_gross: u64,
        settled_total: u64,
        fee_total: u64,
    ) -> Result<()> {
        let config = &ctx.accounts.config;
        require_settlers(config, ctx.remaining_accounts)?;
        require!(!config.paused, SponsoredTasksError::Paused);
        let fee_bps = config.fee_bps;

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
            reservation.state == ReservationState::Reserved,
            SponsoredTasksError::ReservationWrongState
        );
        require!(
            distributed_gross <= reservation.amount,
            SponsoredTasksError::SettlementExceedsReservation
        );
        require!(
            settled_total.checked_add(fee_total) == Some(distributed_gross),
            SponsoredTasksError::InvalidSettlementTotals
        );
        let maximum_fee = (distributed_gross as u128 * fee_bps as u128 / 10_000) as u64;
        require!(fee_total <= maximum_fee, SponsoredTasksError::InvalidFeeBps);
        // A root exactly when there are awards to claim.
        let has_awards = settled_total > 0;
        require!(
            has_awards == (root != [0; 32]) && has_awards == (leaf_count > 0),
            SponsoredTasksError::InvalidSettlementTotals
        );

        let amount = reservation.amount;
        let account = vault
            .managers
            .iter_mut()
            .find(|m| m.key == reservation.manager)
            .ok_or(SponsoredTasksError::ManagerNotActive)?;
        account.reserved = account
            .reserved
            .checked_sub(amount)
            .ok_or(SponsoredTasksError::Overflow)?;
        account.spent = account
            .spent
            .checked_add(distributed_gross)
            .ok_or(SponsoredTasksError::Overflow)?;
        vault.total_reserved = vault
            .total_reserved
            .checked_sub(amount)
            .ok_or(SponsoredTasksError::Overflow)?;
        vault.total_settled = vault
            .total_settled
            .checked_add(distributed_gross)
            .ok_or(SponsoredTasksError::Overflow)?;

        reservation.state = ReservationState::Settled;
        reservation.root = root;
        reservation.leaf_count = leaf_count;
        reservation.settled_total = settled_total;
        reservation.fee_total = fee_total;
        reservation.settled_at = Clock::get()?.unix_timestamp;
        emit_cpi!(SettlementInstalled {
            vault: vault_key,
            reservation: reservation.key(),
            base_chain_id: reservation.base_chain_id,
            base_task_id: reservation.base_task_id,
            epoch: reservation.epoch,
            root,
            leaf_count,
            distributed_gross,
            settled_total,
            fee_total,
            released_amount: amount - distributed_gross,
        });
        Ok(())
    }

    /// Blocked while paused. Pays award leaf `leaf_index` of a settled reservation to the
    /// worker's bound payout address. Anyone may relay it: the proof against the settled root
    /// authorizes, and the `ClaimReceipt` it creates makes a second claim of the leaf fail.
    /// It pays only once `Config::claim_delay` has passed since `settle`.
    pub fn claim(
        ctx: Context<Claim>,
        leaf_index: u32,
        worker: [u8; 20],
        amount: u64,
        proof: Vec<[u8; 32]>,
    ) -> Result<()> {
        require!(!ctx.accounts.config.paused, SponsoredTasksError::Paused);
        let vault_key = ctx.accounts.vault.key();
        let reservation_key = ctx.accounts.reservation.key();
        let vault = &ctx.accounts.vault;
        require!(
            vault.status == VaultStatus::Active,
            SponsoredTasksError::VaultNotActive
        );
        let reservation = &ctx.accounts.reservation;
        require!(
            reservation.epoch == vault.epoch,
            SponsoredTasksError::EpochMismatch
        );
        require!(
            reservation.state == ReservationState::Settled,
            SponsoredTasksError::ReservationWrongState
        );
        require_claim_delay_elapsed(&ctx.accounts.config, reservation)?;
        require!(
            leaf_index < reservation.leaf_count,
            SponsoredTasksError::ClaimIndexOutOfBounds
        );
        require!(amount > 0, SponsoredTasksError::NothingToClaim);
        // A fresh receipt is zeroed; an existing one already names this reservation.
        require!(
            ctx.accounts.receipt.reservation != reservation_key,
            SponsoredTasksError::ClaimAlreadyPaid
        );
        let leaf = award_leaf(
            &vault_key,
            reservation.epoch,
            &reservation_key,
            &reservation.base_task_id,
            leaf_index,
            &worker,
            amount,
        );
        require!(
            verify_award_proof(&proof, &reservation.root, leaf),
            SponsoredTasksError::InvalidClaimProof
        );
        let claimed_total = reservation
            .claimed_total
            .checked_add(amount)
            .filter(|total| *total <= reservation.settled_total)
            .ok_or(SponsoredTasksError::InvalidSettlementTotals)?;

        let binding = &ctx.accounts.binding;
        require!(
            *binding.owner == ID && !binding.data_is_empty(),
            SponsoredTasksError::PayoutNotBound
        );
        let payout = PayoutBinding::try_deserialize(&mut &binding.try_borrow_data()?[..])?.payout;
        let destination = &ctx.accounts.destination_token_account;
        require_keys_eq!(
            destination.owner,
            payout,
            anchor_lang::error::ErrorCode::ConstraintTokenOwner
        );

        pay_from_vault(
            vault,
            &ctx.accounts.mint,
            &ctx.accounts.vault_token_account,
            destination,
            &ctx.accounts.token_program,
            amount,
        )?;
        let destination_key = destination.key();

        let receipt = &mut ctx.accounts.receipt;
        receipt.reservation = reservation_key;
        receipt.leaf_index = leaf_index;
        receipt.bump = ctx.bumps.receipt;
        let reservation = &mut ctx.accounts.reservation;
        reservation.claimed_total = claimed_total;
        reservation.claimed_count = reservation
            .claimed_count
            .checked_add(1)
            .ok_or(SponsoredTasksError::Overflow)?;
        let vault = &mut ctx.accounts.vault;
        vault.total_claimed = vault
            .total_claimed
            .checked_add(amount)
            .ok_or(SponsoredTasksError::Overflow)?;
        emit_cpi!(SponsoredTaskClaimed {
            vault: vault_key,
            reservation: reservation_key,
            base_chain_id: reservation.base_chain_id,
            base_task_id: reservation.base_task_id,
            leaf_index,
            worker,
            destination: destination_key,
            amount,
        });
        Ok(())
    }

    /// Open while paused. The config fee recipient takes a settled reservation's fee to any
    /// token account of the vault's mint, once, after the claim delay.
    pub fn claim_fee(ctx: Context<ClaimFee>) -> Result<()> {
        let vault_key = ctx.accounts.vault.key();
        let reservation_key = ctx.accounts.reservation.key();
        let vault = &ctx.accounts.vault;
        require!(
            vault.status == VaultStatus::Active,
            SponsoredTasksError::VaultNotActive
        );
        let reservation = &ctx.accounts.reservation;
        require!(
            reservation.epoch == vault.epoch,
            SponsoredTasksError::EpochMismatch
        );
        require!(
            reservation.state == ReservationState::Settled,
            SponsoredTasksError::ReservationWrongState
        );
        require_claim_delay_elapsed(&ctx.accounts.config, reservation)?;
        let amount = reservation.fee_total;
        require!(
            amount > 0 && !reservation.fee_claimed,
            SponsoredTasksError::NothingToClaim
        );

        pay_from_vault(
            vault,
            &ctx.accounts.mint,
            &ctx.accounts.vault_token_account,
            &ctx.accounts.destination_token_account,
            &ctx.accounts.token_program,
            amount,
        )?;

        ctx.accounts.reservation.fee_claimed = true;
        let vault = &mut ctx.accounts.vault;
        vault.total_claimed = vault
            .total_claimed
            .checked_add(amount)
            .ok_or(SponsoredTasksError::Overflow)?;
        let reservation = &ctx.accounts.reservation;
        emit_cpi!(FeeClaimed {
            vault: vault_key,
            reservation: reservation_key,
            base_chain_id: reservation.base_chain_id,
            base_task_id: reservation.base_task_id,
            fee_recipient: ctx.accounts.fee_recipient.key(),
            destination: ctx.accounts.destination_token_account.key(),
            amount,
        });
        Ok(())
    }

    /// Admin-only and open whether or not the program is paused: undoes a settlement nobody has
    /// claimed against, so the settlers can sign a corrected root. It needs no pause because it
    /// touches only the one reservation, so revoking a bad root leaves claims on every other
    /// vault running; a claimed leaf or fee still blocks it.
    pub fn revoke_settlement(ctx: Context<RevokeSettlement>) -> Result<()> {
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
            reservation.claimed_count == 0 && !reservation.fee_claimed,
            SponsoredTasksError::SettlementHasClaims
        );
        let settled_total = reservation.settled_total;
        let distributed_gross = settled_total
            .checked_add(reservation.fee_total)
            .ok_or(SponsoredTasksError::Overflow)?;
        let amount = reservation.amount;
        if let Some(account) = vault
            .managers
            .iter_mut()
            .find(|m| m.key == reservation.manager)
        {
            account.reserved = account
                .reserved
                .checked_add(amount)
                .ok_or(SponsoredTasksError::Overflow)?;
            account.spent = account.spent.saturating_sub(distributed_gross);
        }
        vault.total_settled = vault
            .total_settled
            .checked_sub(distributed_gross)
            .ok_or(SponsoredTasksError::Overflow)?;
        vault.total_reserved = vault
            .total_reserved
            .checked_add(amount)
            .ok_or(SponsoredTasksError::Overflow)?;
        let root = reservation.root;
        reservation.state = ReservationState::Reserved;
        reservation.root = [0; 32];
        reservation.leaf_count = 0;
        reservation.settled_total = 0;
        reservation.fee_total = 0;
        reservation.settled_at = 0;
        emit_cpi!(SettlementRevoked {
            vault: vault_key,
            reservation: reservation.key(),
            root,
            settled_total,
        });
        Ok(())
    }

    /// Binds a Base agent's Solana payout address from the agent's EIP-712 signature over
    /// `PayoutBinding(agent, payout, nonce)`. Anyone may relay it: the signature, not the payer,
    /// authorizes. A newer binding replaces the old one only with a higher nonce. Open while
    /// paused, since it moves no funds.
    pub fn bind_payout(
        ctx: Context<BindPayout>,
        base_chain_id: u64,
        base_agent: [u8; 20],
        payout: Pubkey,
        nonce: u64,
        signature: [u8; 65],
    ) -> Result<()> {
        let digest = payout_binding_digest(base_chain_id, &base_agent, &payout, nonce);
        require!(
            recover_evm_address(&digest, &signature)? == base_agent,
            SponsoredTasksError::InvalidPayoutSignature
        );
        let binding = &mut ctx.accounts.binding;
        // A fresh account is zeroed; the seeds tie an existing one to this agent.
        if binding.base_agent == base_agent {
            require!(nonce > binding.nonce, SponsoredTasksError::StalePayoutNonce);
        }
        binding.base_chain_id = base_chain_id;
        binding.base_agent = base_agent;
        binding.payout = payout;
        binding.nonce = nonce;
        binding.bump = ctx.bumps.binding;
        emit_cpi!(PayoutBound {
            base_chain_id,
            base_agent,
            payout,
            nonce,
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
            pay_from_vault(
                vault,
                &ctx.accounts.mint,
                &ctx.accounts.vault_token_account,
                &ctx.accounts.recipient_token_account,
                &ctx.accounts.token_program,
                amount,
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

/// Claims against a root wait `Config::claim_delay` seconds after `settle` installed it.
fn require_claim_delay_elapsed(config: &Config, reservation: &Reservation) -> Result<()> {
    let claimable_at = reservation
        .settled_at
        .saturating_add(config.claim_delay() as i64);
    require!(
        Clock::get()?.unix_timestamp >= claimable_at,
        SponsoredTasksError::ClaimDelayNotElapsed
    );
    Ok(())
}

/// Transfers `amount` out of the vault's token account, signed by the vault PDA.
fn pay_from_vault<'info>(
    vault: &Account<'info, Vault>,
    mint: &InterfaceAccount<'info, Mint>,
    from: &InterfaceAccount<'info, TokenAccount>,
    to: &InterfaceAccount<'info, TokenAccount>,
    token_program: &Interface<'info, TokenInterface>,
    amount: u64,
) -> Result<()> {
    let id_bytes = vault.vault_id.to_le_bytes();
    let bump = [vault.bump];
    let seeds: &[&[u8]] = &[
        VAULT_SEED,
        vault.mint.as_ref(),
        vault.sponsor.as_ref(),
        &id_bytes,
        &bump,
    ];
    transfer_checked(
        CpiContext::new_with_signer(
            token_program.key(),
            TransferChecked {
                from: from.to_account_info(),
                mint: mint.to_account_info(),
                to: to.to_account_info(),
                authority: vault.to_account_info(),
            },
            &[seeds],
        ),
        amount,
        mint.decimals,
    )
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

/// The EIP-712 digest of a payout binding, as `eth_signTypedData_v4` builds it.
pub fn payout_binding_digest(
    base_chain_id: u64,
    base_agent: &[u8; 20],
    payout: &Pubkey,
    nonce: u64,
) -> [u8; 32] {
    let domain = keccak::hashv(&[
        keccak::hash(EIP712_DOMAIN_TYPE).as_ref(),
        keccak::hash(PAYOUT_DOMAIN_NAME.as_bytes()).as_ref(),
        keccak::hash(PAYOUT_DOMAIN_VERSION.as_bytes()).as_ref(),
        &abi_word(base_chain_id),
        ID.as_ref(),
    ]);
    let mut agent = [0u8; 32];
    agent[12..].copy_from_slice(base_agent);
    let message = keccak::hashv(&[
        keccak::hash(PAYOUT_BINDING_TYPE).as_ref(),
        &agent,
        payout.as_ref(),
        &abi_word(nonce),
    ]);
    keccak::hashv(&[b"\x19\x01", domain.as_ref(), message.as_ref()]).to_bytes()
}

/// An award leaf in the EVM vault's format, as OpenZeppelin `StandardMerkleTree` builds it:
/// `keccak256(keccak256(abi.encode(vaultId, epoch, allocationId, taskId, leafIndex, worker,
/// netAmount)))`, with the vault and reservation PDAs as `vaultId` and `allocationId`.
pub fn award_leaf(
    vault: &Pubkey,
    epoch: u64,
    reservation: &Pubkey,
    base_task_id: &[u8; 32],
    leaf_index: u32,
    worker: &[u8; 20],
    net_amount: u64,
) -> [u8; 32] {
    let mut worker_word = [0u8; 32];
    worker_word[12..].copy_from_slice(worker);
    let inner = keccak::hashv(&[
        vault.as_ref(),
        &abi_word(epoch),
        reservation.as_ref(),
        base_task_id,
        &abi_word(leaf_index as u64),
        &worker_word,
        &abi_word(net_amount),
    ]);
    keccak::hash(inner.as_ref()).to_bytes()
}

/// Folds `proof` into `leaf` with sorted-pair keccak nodes and compares the result with `root`.
pub fn verify_award_proof(proof: &[[u8; 32]], root: &[u8; 32], leaf: [u8; 32]) -> bool {
    let computed = proof.iter().fold(leaf, |node, sibling| {
        let (a, b) = if node <= *sibling {
            (node, *sibling)
        } else {
            (*sibling, node)
        };
        keccak::hashv(&[&a, &b]).to_bytes()
    });
    computed == *root
}

fn abi_word(value: u64) -> [u8; 32] {
    let mut word = [0u8; 32];
    word[24..].copy_from_slice(&value.to_be_bytes());
    word
}

/// The EVM address that produced a 65-byte `r || s || v` signature over `digest`; `v` may be
/// 0/1 or 27/28.
fn recover_evm_address(digest: &[u8; 32], signature: &[u8; 65]) -> Result<[u8; 20]> {
    let recovery_id = match signature[64] {
        v @ (0 | 1) => v,
        v @ (27 | 28) => v - 27,
        _ => return err!(SponsoredTasksError::InvalidPayoutSignature),
    };
    let pubkey = secp256k1_recover(digest, recovery_id, &signature[..64])
        .map_err(|_| error!(SponsoredTasksError::InvalidPayoutSignature))?;
    let hash = keccak::hash(&pubkey.to_bytes());
    let mut address = [0u8; 20];
    address.copy_from_slice(&hash.as_ref()[12..]);
    Ok(address)
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
pub struct Settle<'info> {
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut)]
    pub vault: Account<'info, Vault>,
    #[account(mut, has_one = vault)]
    pub reservation: Account<'info, Reservation>,
}

#[event_cpi]
#[derive(Accounts)]
#[instruction(leaf_index: u32, worker: [u8; 20])]
pub struct Claim<'info> {
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut, has_one = mint, has_one = token_program)]
    pub vault: Account<'info, Vault>,
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(mut, address = vault.token_account)]
    pub vault_token_account: InterfaceAccount<'info, TokenAccount>,
    #[account(mut, has_one = vault)]
    pub reservation: Account<'info, Reservation>,
    /// CHECK: the worker's `PayoutBinding` PDA; `claim` fails with `PayoutNotBound` while it
    /// does not exist, and deserializes it otherwise.
    #[account(
        seeds = [PAYOUT_SEED, &reservation.base_chain_id.to_le_bytes(), &worker],
        bump
    )]
    pub binding: UncheckedAccount<'info>,
    #[account(
        init_if_needed,
        payer = payer,
        space = 8 + ClaimReceipt::INIT_SPACE,
        seeds = [CLAIM_SEED, reservation.key().as_ref(), &leaf_index.to_le_bytes()],
        bump
    )]
    pub receipt: Account<'info, ClaimReceipt>,
    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub destination_token_account: InterfaceAccount<'info, TokenAccount>,
    #[account(mut)]
    pub payer: Signer<'info>,
    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

#[event_cpi]
#[derive(Accounts)]
pub struct ClaimFee<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = config.fee_recipient == fee_recipient.key()
            @ SponsoredTasksError::NotFeeRecipient
    )]
    pub config: Account<'info, Config>,
    pub fee_recipient: Signer<'info>,
    #[account(mut, has_one = mint, has_one = token_program)]
    pub vault: Account<'info, Vault>,
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(mut, address = vault.token_account)]
    pub vault_token_account: InterfaceAccount<'info, TokenAccount>,
    #[account(mut, has_one = vault)]
    pub reservation: Account<'info, Reservation>,
    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub destination_token_account: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
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
#[instruction(base_chain_id: u64, base_agent: [u8; 20])]
pub struct BindPayout<'info> {
    #[account(
        init_if_needed,
        payer = payer,
        space = 8 + PayoutBinding::INIT_SPACE,
        seeds = [PAYOUT_SEED, &base_chain_id.to_le_bytes(), &base_agent],
        bump
    )]
    pub binding: Account<'info, PayoutBinding>,
    #[account(mut)]
    pub payer: Signer<'info>,
    pub system_program: Program<'info, System>,
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
