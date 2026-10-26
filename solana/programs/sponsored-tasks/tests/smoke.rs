use anchor_lang::{InstructionData, ToAccountMetas};
use litesvm::LiteSVM;
use solana_instruction::Instruction;
use solana_keypair::Keypair;
use solana_message::Message;
use solana_signer::Signer;
use solana_transaction::Transaction;

const PROGRAM_SO: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../target/deploy/sponsored_tasks.so"
);

fn setup() -> (LiteSVM, Keypair) {
    let mut svm = LiteSVM::new();
    svm.add_program_from_file(sponsored_tasks::ID, PROGRAM_SO)
        .expect("run `make contract solana build` first");
    let payer = Keypair::new();
    svm.airdrop(&payer.pubkey(), 1_000_000_000).unwrap();
    (svm, payer)
}

#[test]
fn ping_succeeds() {
    let (mut svm, payer) = setup();
    let ix = Instruction {
        program_id: sponsored_tasks::ID,
        accounts: sponsored_tasks::accounts::Ping {}.to_account_metas(None),
        data: sponsored_tasks::instruction::Ping {}.data(),
    };
    let msg = Message::new(&[ix], Some(&payer.pubkey()));
    let tx = Transaction::new(&[&payer], msg, svm.latest_blockhash());
    let meta = svm.send_transaction(tx).expect("ping should succeed");
    assert!(meta
        .logs
        .iter()
        .any(|l| l.contains("sponsored-tasks 0.1.0")));
}
