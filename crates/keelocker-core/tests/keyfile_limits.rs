use keelocker_core::{CoreError, CoreVault};
use keepass::{config::KdfConfig, Database, DatabaseKey};
use std::fs::{self, File};

const MAX_KEY_FILE_BYTES: u64 = 16 * 1024 * 1024;

#[cfg(unix)]
#[test]
fn named_pipe_keyfile_is_rejected_without_waiting_for_a_writer() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("synthetic.kdbx");
    let keyfile = dir.path().join("pipe.key");
    let original = include_bytes!("../../../KeeLockerTests/Fixtures/interop.kdbx");
    fs::write(&source, original).unwrap();
    assert!(std::process::Command::new("mkfifo")
        .arg(&keyfile)
        .status()
        .unwrap()
        .success());
    let source_path = source.to_string_lossy().into_owned();
    let key_path = keyfile.to_string_lossy().into_owned();
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let result = CoreVault::open(source_path, "fixture-password".into(), Some(key_path));
        sender
            .send(matches!(result, Err(CoreError::ReadFailed)))
            .unwrap();
    });
    assert_eq!(
        receiver.recv_timeout(std::time::Duration::from_secs(2)),
        Ok(true)
    );
    assert_eq!(fs::read(source).unwrap(), original);
}

#[test]
fn oversized_keyfile_is_rejected_before_unlock_without_changing_the_vault() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("synthetic.kdbx");
    let keyfile = dir.path().join("oversized.key");
    let original = include_bytes!("../../../KeeLockerTests/Fixtures/interop.kdbx");
    fs::write(&source, original).unwrap();
    File::create(&keyfile)
        .unwrap()
        .set_len(MAX_KEY_FILE_BYTES + 1)
        .unwrap();
    let opened = CoreVault::open(
        source.to_string_lossy().into(),
        "fixture-password".into(),
        Some(keyfile.to_string_lossy().into()),
    );
    assert!(matches!(opened, Err(CoreError::UnsupportedDatabase)));
    assert_eq!(fs::read(source).unwrap(), original);
}

#[test]
fn keyfile_at_the_supported_limit_keeps_its_original_key_composition() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("synthetic.kdbx");
    let keyfile = dir.path().join("supported.key");
    File::create(&keyfile)
        .unwrap()
        .set_len(MAX_KEY_FILE_BYTES)
        .unwrap();
    let key = DatabaseKey::new()
        .with_password("synthetic-password")
        .with_keyfile(&mut File::open(&keyfile).unwrap())
        .unwrap();
    let mut db = Database::new();
    db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
    db.root_mut()
        .add_entry()
        .set_unprotected("Title", "Synthetic key-file boundary");
    db.save(&mut File::create(&source).unwrap(), key).unwrap();
    let original = fs::read(&source).unwrap();
    let vault = CoreVault::open(
        source.to_string_lossy().into(),
        "synthetic-password".into(),
        Some(keyfile.to_string_lossy().into()),
    )
    .unwrap();
    assert_eq!(vault.snapshot().unwrap().entries.len(), 1);
    vault.lock();
    assert_eq!(fs::read(source).unwrap(), original);
}
