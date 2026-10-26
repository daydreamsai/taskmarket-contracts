use anchor_lang::prelude::*;

// Placeholder id with no keypair anywhere; the deploy task generates the real one outside the repo.
declare_id!("STvau1t111111111111111111111111111111111111");

#[program]
pub mod sponsored_tasks {
    use super::*;

    pub fn ping(_ctx: Context<Ping>) -> Result<()> {
        msg!("sponsored-tasks {}", env!("CARGO_PKG_VERSION"));
        Ok(())
    }
}

#[derive(Accounts)]
pub struct Ping {}
