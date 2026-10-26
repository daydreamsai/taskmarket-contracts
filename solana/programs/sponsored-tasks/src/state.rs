use anchor_lang::prelude::*;

pub const CONFIG_SEED: &[u8] = b"config";
pub const VAULT_SEED: &[u8] = b"vault";
pub const RESERVATION_SEED: &[u8] = b"task";

pub const MAX_SETTLERS: usize = 5;
pub const MAX_MANAGERS: usize = 8;
pub const MAX_FEE_BPS: u16 = 10_000;

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
    /// Total the installed root awards; `settle` sets it and adds it to `Vault::total_settled`
    /// while moving `amount` out of `Vault::total_reserved`, leaving the manager's `reserved`
    /// untouched so `revoke_settlement` can reverse it exactly.
    pub settled_total: u64,
    /// Claims paid against `root`; `revoke_settlement` only acts while it is zero.
    pub claimed_count: u32,
    pub bump: u8,
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
