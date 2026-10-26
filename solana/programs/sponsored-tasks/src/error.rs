use anchor_lang::prelude::*;

#[error_code]
pub enum SponsoredTasksError {
    #[msg("Caller is not the config admin")]
    NotAdmin,
    #[msg("Caller is not the vault sponsor")]
    NotSponsor,
    #[msg("Settler set is empty, too large or has duplicates")]
    InvalidSettlers,
    #[msg("Threshold must be between 1 and the number of settlers")]
    InvalidThreshold,
    #[msg("Not enough settler signatures")]
    SettlerThresholdNotMet,
    #[msg("Fee basis points above 10000")]
    InvalidFeeBps,
    #[msg("Program is paused")]
    Paused,
    #[msg("Vault is not active")]
    VaultNotActive,
    #[msg("Mint has an extension the vault does not accept")]
    UnsupportedMintExtension,
    #[msg("Amount must be greater than zero")]
    ZeroAmount,
    #[msg("Vault received a different amount than was sent")]
    TransferAmountMismatch,
    #[msg("Too many managers")]
    TooManyManagers,
    #[msg("Manager cap is below its reserved plus spent amount")]
    InvalidManagerCap,
    #[msg("Manager is not active on this vault")]
    ManagerNotActive,
    #[msg("Manager is on a different chain than the task")]
    ManagerChainMismatch,
    #[msg("Reservation exceeds the manager's remaining allowance")]
    ManagerAllowanceExceeded,
    #[msg("Reservation exceeds the vault cap")]
    VaultCapExceeded,
    #[msg("Reservation exceeds the vault's available balance")]
    InsufficientAvailable,
    #[msg("Reservation deadline is in the past")]
    DeadlineInPast,
    #[msg("Reservation is not in the reserved state")]
    ReservationWrongState,
    #[msg("Reservation belongs to an earlier vault epoch")]
    EpochMismatch,
    #[msg("Only allowed while the program is paused")]
    NotPaused,
    #[msg("Settlement already has claims against it")]
    SettlementHasClaims,
    #[msg("Arithmetic overflow")]
    Overflow,
}
