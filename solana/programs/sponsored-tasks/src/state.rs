use anchor_lang::prelude::*;

pub const CONFIG_SEED: &[u8] = b"config";
pub const VAULT_SEED: &[u8] = b"vault";
pub const RESERVATION_SEED: &[u8] = b"task";
pub const PAYOUT_SEED: &[u8] = b"payout";
pub const CLAIM_SEED: &[u8] = b"claim";

pub const MAX_SETTLERS: usize = 5;
pub const MAX_MANAGERS: usize = 8;
pub const MAX_FEE_BPS: u16 = 10_000;
/// Claim delay used while `Config::claim_delay_seconds` is unset (zero).
pub const DEFAULT_CLAIM_DELAY_SECONDS: u64 = 3_600;

#[account]
#[derive(InitSpace)]
pub struct Config {
    pub admin: Pubkey,
    #[max_len(MAX_SETTLERS)]
    pub settlers: Vec<Pubkey>,
    pub threshold: u8,
    /// Blocks `create_vault`, `reserve`, `settle` and `claim`. `fund`, `release`,
    /// `set_managers`, `emergency_exit` and `claim_fee` stay open so a pause never traps
    /// sponsor or fee funds.
    pub paused: bool,
    pub fee_bps: u16,
    pub fee_recipient: Pubkey,
    pub bump: u8,
    /// Seconds after `settle` before `claim` and `claim_fee` pay against the installed root.
    /// Zero (unset) reads as `DEFAULT_CLAIM_DELAY_SECONDS`; `set_claim_delay` never stores zero.
    pub claim_delay_seconds: u64,
}

impl Config {
    pub fn claim_delay(&self) -> u64 {
        if self.claim_delay_seconds == 0 {
            DEFAULT_CLAIM_DELAY_SECONDS
        } else {
            self.claim_delay_seconds
        }
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug, InitSpace)]
pub enum VaultStatus {
    Active,
    Exited,
}

/// A Base or Tempo task creator, identified by its EVM chain id and address.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug, InitSpace)]
pub struct ManagerKey {
    pub chain_id: u64,
    pub evm_address: [u8; 20],
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug, InitSpace)]
pub struct Manager {
    pub key: ManagerKey,
    /// Lifetime allowance; never below `reserved + spent`.
    pub cap: u64,
    pub reserved: u64,
    pub spent: u64,
    pub active: bool,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub struct ManagerInput {
    pub key: ManagerKey,
    pub cap: u64,
    pub active: bool,
}

#[account]
#[derive(InitSpace)]
pub struct Vault {
    pub sponsor: Pubkey,
    pub mint: Pubkey,
    pub token_program: Pubkey,
    pub token_account: Pubkey,
    pub vault_id: u64,
    pub status: VaultStatus,
    /// Reservations from an earlier epoch were defaulted by an emergency exit.
    pub epoch: u64,
    pub total_funded: u64,
    pub total_reserved: u64,
    pub total_settled: u64,
    pub total_claimed: u64,
    pub total_withdrawn: u64,
    pub total_defaulted_reserved: u64,
    pub total_defaulted_claimable: u64,
    #[max_len(MAX_MANAGERS)]
    pub managers: Vec<Manager>,
    pub bump: u8,
}

impl Vault {
    /// Settled awards not yet claimed in the current epoch.
    pub fn claimable(&self) -> u64 {
        self.total_settled.saturating_sub(self.total_claimed)
    }

    /// Tokens not backing a live reservation or a settled-but-unclaimed award.
    pub fn available(&self) -> u64 {
        self.total_funded
            .saturating_sub(self.total_withdrawn)
            .saturating_sub(self.total_claimed)
            .saturating_sub(self.total_reserved)
            .saturating_sub(self.claimable())
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug, InitSpace)]
pub enum ReservationState {
    Reserved,
    Settled,
    Released,
    /// Never stored: reported by `Reservation::effective_state` after an emergency exit.
    DefaultedByOwner,
}

#[account]
#[derive(InitSpace)]
pub struct Reservation {
    pub vault: Pubkey,
    pub epoch: u64,
    pub base_chain_id: u64,
    pub base_task_id: [u8; 32],
    pub nonce: u64,
    pub deadline: i64,
    pub manager: ManagerKey,
    pub amount: u64,
    pub state: ReservationState,
    /// Zero until a settlement installs the award root.
    pub root: [u8; 32],
    /// Leaves under `root`; a claim's `leaf_index` must be below it.
    pub leaf_count: u32,
    /// Sum of the leaves' net amounts under `root`.
    pub settled_total: u64,
    /// Fee carved from the awarded gross at `settle`, paid out by `claim_fee`.
    /// `settle` moves `amount` out of `Vault::total_reserved` and adds `settled_total + fee_total`
    /// to `Vault::total_settled`; the rest of `amount` returns to the available balance.
    pub fee_total: u64,
    /// Claims paid against `root`; `revoke_settlement` only acts while it is zero.
    pub claimed_count: u32,
    /// Net amount paid by claims against `root`, never above `settled_total`.
    pub claimed_total: u64,
    /// `claim_fee` has paid `fee_total`; `revoke_settlement` only acts while it is false.
    pub fee_claimed: bool,
    pub bump: u8,
    /// Unix time `settle` installed `root`; zero while no root is installed.
    pub settled_at: i64,
}

impl Reservation {
    pub fn effective_state(&self, vault: &Vault) -> ReservationState {
        let open = matches!(
            self.state,
            ReservationState::Reserved | ReservationState::Settled
        );
        if vault.status == VaultStatus::Exited && self.epoch != vault.epoch && open {
            ReservationState::DefaultedByOwner
        } else {
            self.state
        }
    }
}

/// Where a Base agent's Solana awards are paid. `bind_payout` creates or replaces it from an
/// EIP-712 signature by the agent; a replacement must carry a higher nonce.
#[account]
#[derive(InitSpace)]
pub struct PayoutBinding {
    pub base_chain_id: u64,
    pub base_agent: [u8; 20],
    pub payout: Pubkey,
    pub nonce: u64,
    pub bump: u8,
}

/// Exists once leaf `leaf_index` of a reservation's root has been paid; its existence is the
/// double-claim guard. Seeds: `"claim", reservation, leaf_index (u32 LE)`.
#[account]
#[derive(InitSpace)]
pub struct ClaimReceipt {
    pub reservation: Pubkey,
    pub leaf_index: u32,
    pub bump: u8,
}
