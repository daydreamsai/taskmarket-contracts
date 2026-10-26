use anchor_lang::prelude::*;

use crate::state::ManagerKey;

#[event]
pub struct ConfigInitialized {
    pub admin: Pubkey,
    pub settlers: Vec<Pubkey>,
    pub threshold: u8,
    pub fee_bps: u16,
    pub fee_recipient: Pubkey,
}

#[event]
pub struct AdminChanged {
    pub previous: Pubkey,
    pub admin: Pubkey,
}

#[event]
pub struct SettlersChanged {
    pub settlers: Vec<Pubkey>,
    pub threshold: u8,
}

#[event]
pub struct PauseSet {
    pub paused: bool,
}

#[event]
pub struct VaultCreated {
    pub vault: Pubkey,
    pub sponsor: Pubkey,
    pub mint: Pubkey,
    pub token_program: Pubkey,
    pub vault_id: u64,
    pub epoch: u64,
}

#[event]
pub struct VaultFunded {
    pub vault: Pubkey,
    pub funder: Pubkey,
    pub amount: u64,
}

#[event]
pub struct ManagerConfigured {
    pub vault: Pubkey,
    pub manager: ManagerKey,
    pub cap: u64,
    pub reserved: u64,
    pub spent: u64,
    pub active: bool,
}

#[event]
pub struct TaskReserved {
    pub vault: Pubkey,
    pub reservation: Pubkey,
    pub base_chain_id: u64,
    pub base_task_id: [u8; 32],
    pub manager: ManagerKey,
    pub epoch: u64,
    pub nonce: u64,
    pub deadline: i64,
    pub amount: u64,
}

#[event]
pub struct TaskReleased {
    pub vault: Pubkey,
    pub reservation: Pubkey,
    pub base_chain_id: u64,
    pub base_task_id: [u8; 32],
    pub manager: ManagerKey,
    pub amount: u64,
}

#[event]
pub struct SettlementRevoked {
    pub vault: Pubkey,
    pub reservation: Pubkey,
    pub root: [u8; 32],
    pub settled_total: u64,
}

#[event]
pub struct VaultEmergencyExited {
    pub vault: Pubkey,
    pub sponsor: Pubkey,
    pub recipient: Pubkey,
    pub closed_epoch: u64,
    pub new_epoch: u64,
    pub amount_withdrawn: u64,
    pub affected_reserved: u64,
    pub affected_claimable: u64,
}
