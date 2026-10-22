#![cfg(unix)]

use keelocker_core::{CoreBackup, CoreEntryEdit, CoreError, CoreRecovery, CoreVault};
use keepass::{config::KdfConfig, Database, DatabaseKey};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::Write,
    os::unix::{
        ffi::OsStrExt,
        fs::{symlink, PermissionsExt},
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::Arc,
};

const PASSWORD: &str = "fixture-password";

fn path(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}
fn hash(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let mut result = String::new();
    for byte in Sha256::digest(bytes) {
        write!(&mut result, "{byte:02x}").unwrap();
    }
    result
}
fn edit(title: &str) -> CoreEntryEdit {
    CoreEntryEdit {
        title: title.into(),
        icon: None,
        username: "synthetic-user".into(),
        password: "synthetic-secret".into(),
        url: String::new(),
        notes: String::new(),
        tags: vec![],
        custom_fields: vec![],
    }
}
fn encrypted(title: &str, key: DatabaseKey) -> Vec<u8> {
    let mut db = Database::new();
    db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
    db.root_mut().add_entry().set_unprotected("Title", title);
    let mut bytes = Vec::new();
    db.save(&mut bytes, key).unwrap();
    bytes
}
fn encrypted_password(title: &str) -> Vec<u8> {
    encrypted(title, DatabaseKey::new().with_password(PASSWORD))
}

struct Fixture {
    _directory: tempfile::TempDir,
    base: PathBuf,
    source: PathBuf,
    root: PathBuf,
    original: Vec<u8>,
    vault: Arc<CoreVault>,
}
impl Fixture {
    fn new() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let base = directory.path().canonicalize().unwrap();
        let source_directory = base.join("source");
        fs::create_dir(&source_directory).unwrap();
        let source = source_directory.join("synthetic.kdbx");
        let original = encrypted_password("Synthetic original");
        fs::write(&source, &original).unwrap();
        let vault = CoreVault::open(path(&source), PASSWORD.into(), None).unwrap();
        let root = base.join("recovery");
        vault.configure_backup_directory(path(&root)).unwrap();
        Self {
            _directory: directory,
            base,
            source,
            root,
            original,
            vault,
        }
    }
    fn recovery(&self) -> Arc<CoreRecovery> {
        CoreRecovery::new(path(&self.source), Some(path(&self.root))).unwrap()
    }
    fn namespace(&self) -> PathBuf {
        self.root.join(hash(self.source.as_os_str().as_bytes()))
    }
    fn change(&self, title: &str) {
        let id = self.vault.snapshot().unwrap().entries[0].id.clone();
        self.vault.update_entry(id, edit(title)).unwrap();
    }
    fn save(&self, title: &str) {
        self.change(title);
        self.vault.save().unwrap();
    }
    fn original_record(&self) -> CoreBackup {
        self.recovery()
            .backups()
            .unwrap()
            .into_iter()
            .find(|b| b.is_original)
            .unwrap()
    }
    fn restore(
        &self,
        id: &str,
        name: &str,
        password: &str,
    ) -> Result<keelocker_core::CoreRecoveryResult, CoreError> {
        self.recovery().restore_backup(
            id.into(),
            path(&self.base.join(name)),
            password.into(),
            None,
        )
    }
}

fn inventory(directory: &Path) -> Vec<(PathBuf, u32, Vec<u8>)> {
    let mut result = Vec::new();
    if !directory.exists() {
        return result;
    }
    for entry in fs::read_dir(directory).unwrap() {
        let file = entry.unwrap().path();
        let metadata = fs::symlink_metadata(&file).unwrap();
        let bytes = if metadata.is_dir() {
            result.extend(inventory(&file));
            vec![]
        } else if metadata.file_type().is_symlink() {
            fs::read_link(&file)
                .unwrap()
                .as_os_str()
                .as_bytes()
                .to_vec()
        } else {
            fs::read(&file).unwrap()
        };
        result.push((file, metadata.permissions().mode(), bytes));
    }
    result.sort();
    result
}

#[test]
fn listing_never_creates_missing_namespaces_or_changes_bytes_and_permissions() {
    let fixture = Fixture::new();
    let before = inventory(&fixture.base);
    assert!(fixture.recovery().backups().unwrap().is_empty());
    assert_eq!(inventory(&fixture.base), before);
    assert!(!fixture.root.exists());
    fixture.save("First save");
    let before = inventory(&fixture.base);
    let copies = fixture.recovery().backups().unwrap();
    assert_eq!(copies.len(), 2);
    let original = copies.iter().find(|b| b.is_original).unwrap();
    assert_eq!(original.id, format!("original:{}", hash(&fixture.original)));
    assert_eq!(original.size, fixture.original.len() as u64);
    assert!(copies.iter().all(|b| b
        .created_at
        .is_some_and(|seconds| seconds > 0 && seconds < 10_000_000_000)));
    assert_eq!(inventory(&fixture.base), before);
    let unknown = CoreRecovery::new(
        path(&fixture.base.join("unknown.kdbx")),
        Some(path(&fixture.root)),
    )
    .unwrap();
    assert!(unknown.backups().unwrap().is_empty());
    assert_eq!(inventory(&fixture.base), before);
}

#[test]
fn restores_byte_exact_original_and_generation_without_touching_dirty_session_or_source() {
    let fixture = Fixture::new();
    fixture.save("First committed edit");
    let generation = fs::read(&fixture.source).unwrap();
    fixture.save("Second committed edit");
    fixture.change("Unsaved local edit");
    let source = fs::read(&fixture.source).unwrap();
    let copies_before = inventory(&fixture.root);
    let recovery = fixture.recovery();
    let copies = recovery.backups().unwrap();
    let original = copies.iter().find(|b| b.is_original).unwrap();
    let generation_record = copies
        .iter()
        .find(|b| b.id.ends_with(&format!("-{}.kdbx", hash(&generation))))
        .unwrap();
    for (name, backup, expected) in [
        ("original-copy.kdbx", original, &fixture.original),
        ("generation-copy.kdbx", generation_record, &generation),
    ] {
        let destination = fixture.base.join(name);
        let result = recovery
            .restore_backup(backup.id.clone(), path(&destination), PASSWORD.into(), None)
            .unwrap();
        assert_eq!(result.path, path(&destination));
        assert!(result.directory_synced);
        assert_eq!(fs::read(&destination).unwrap(), *expected);
        assert_eq!(
            fs::metadata(&destination).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let reopened = CoreVault::open(path(&destination), PASSWORD.into(), None).unwrap();
        assert_eq!(reopened.snapshot().unwrap().entries.len(), 1);
    }
    let snapshot = fixture.vault.snapshot().unwrap();
    assert!(snapshot.info.dirty);
    assert_eq!(snapshot.info.path, path(&fixture.source));
    assert_eq!(snapshot.entries[0].title, "Unsaved local edit");
    assert_eq!(fs::read(&fixture.source).unwrap(), source);
    assert_eq!(inventory(&fixture.root), copies_before);
    // Recovery must not adopt a different session hash: the outstanding edit
    // still saves through the ordinary conflict check at the original source.
    fixture.vault.save().unwrap();
}

#[test]
fn recovery_works_after_lock_corruption_missing_source_and_missing_parent() {
    for state in ["locked", "corrupt", "missing", "missing-parent"] {
        let fixture = Fixture::new();
        fixture.save("Committed edit");
        fixture.vault.lock();
        match state {
            "corrupt" => fs::write(&fixture.source, b"synthetic corrupted source").unwrap(),
            "missing" => fs::remove_file(&fixture.source).unwrap(),
            "missing-parent" => fs::remove_dir_all(fixture.source.parent().unwrap()).unwrap(),
            _ => {}
        }
        assert!(matches!(
            fixture.vault.snapshot(),
            Err(CoreError::InvalidOperation)
        ));
        let before = inventory(&fixture.base);
        let recovery = fixture.recovery();
        let original = recovery
            .backups()
            .unwrap()
            .into_iter()
            .find(|b| b.is_original)
            .unwrap();
        assert_eq!(inventory(&fixture.base), before);
        let destination = fixture.base.join("restored.kdbx");
        recovery
            .restore_backup(original.id, path(&destination), PASSWORD.into(), None)
            .unwrap();
        assert_eq!(fs::read(destination).unwrap(), fixture.original);
        assert!(matches!(
            fixture.vault.snapshot(),
            Err(CoreError::InvalidOperation)
        ));
        if state == "missing-parent" {
            assert!(!fixture.source.parent().unwrap().exists());
        }
    }
}

#[test]
fn missing_source_cannot_be_restored_over_its_remembered_identity() {
    let fixture = Fixture::new();
    fixture.save("Committed edit");
    let original = fixture.original_record();
    fs::remove_file(&fixture.source).unwrap();
    let before = inventory(&fixture.base);
    assert_eq!(
        fixture.recovery().restore_backup(
            original.id,
            path(&fixture.source),
            PASSWORD.into(),
            None
        ),
        Err(CoreError::Conflict)
    );
    assert_eq!(inventory(&fixture.base), before);
}

#[test]
fn rejects_traversal_raw_original_foreign_and_other_vault_tokens() {
    let fixture = Fixture::new();
    fixture.save("Saved edit");
    let foreign = fixture.namespace().join("foreign.kdbx");
    fs::write(&foreign, &fixture.original).unwrap();
    let other = fixture.base.join("other.kdbx");
    fs::write(&other, encrypted_password("Other vault")).unwrap();
    let other_vault = CoreVault::open(path(&other), PASSWORD.into(), None).unwrap();
    other_vault
        .configure_backup_directory(path(&fixture.root))
        .unwrap();
    let id = other_vault.snapshot().unwrap().entries[0].id.clone();
    other_vault
        .update_entry(id, edit("Other saved edit"))
        .unwrap();
    other_vault.save().unwrap();
    let other_recovery = CoreRecovery::new(path(&other), Some(path(&fixture.root))).unwrap();
    let other_token = other_recovery
        .backups()
        .unwrap()
        .into_iter()
        .find(|b| !b.is_original)
        .unwrap()
        .id;
    let before = inventory(&fixture.base);
    for id in [
        "../original.kdbx".into(),
        "original.kdbx".into(),
        path(&foreign),
        "foreign.kdbx".into(),
        "../foreign.kdbx".into(),
        "original:../x".into(),
        "original:".into(),
        "original:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".into(),
        "original:\0".into(),
        "snapshot-v1-unrecognized.kdbx".into(),
        other_token,
    ] {
        assert!(
            fixture.restore(&id, "rejected.kdbx", PASSWORD).is_err(),
            "accepted invalid token"
        );
    }
    assert_eq!(fixture.recovery().backups().unwrap().len(), 2);
    assert_eq!(inventory(&fixture.base), before);
}

#[test]
fn rejects_symlink_hardlink_nonregular_and_corrupt_generations() {
    for kind in ["symlink", "hardlink", "directory", "corrupt", "oversized"] {
        let fixture = Fixture::new();
        fixture.save("Saved edit");
        let generation = fixture
            .recovery()
            .backups()
            .unwrap()
            .into_iter()
            .find(|b| !b.is_original)
            .unwrap();
        let file = fixture.namespace().join(&generation.id);
        fs::remove_file(&file).unwrap();
        let foreign = fixture.base.join("foreign.kdbx");
        fs::write(&foreign, &fixture.original).unwrap();
        match kind {
            "symlink" => symlink(&foreign, &file).unwrap(),
            "hardlink" => fs::hard_link(&foreign, &file).unwrap(),
            "directory" => fs::create_dir(&file).unwrap(),
            "corrupt" => fs::write(&file, b"not the expected encrypted generation").unwrap(),
            "oversized" => {
                File::create(&file)
                    .unwrap()
                    .set_len(256 * 1024 * 1024 + 1)
                    .unwrap();
            }
            _ => unreachable!(),
        }
        if kind == "corrupt" || kind == "oversized" {
            fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
        }
        assert!(
            !fixture
                .recovery()
                .backups()
                .unwrap()
                .iter()
                .any(|b| b.id == generation.id),
            "listed {kind}"
        );
        assert!(
            fixture
                .restore(&generation.id, "rejected.kdbx", PASSWORD)
                .is_err(),
            "restored {kind}"
        );
        assert!(!fixture.base.join("rejected.kdbx").exists());
        assert_eq!(fs::read(&foreign).unwrap(), fixture.original);
    }
}

#[test]
fn rejects_unsafe_original_and_stale_original_token_without_writes() {
    for kind in ["symlink", "hardlink", "directory", "swapped", "corrupt"] {
        let fixture = Fixture::new();
        fixture.save("Saved edit");
        let original = fixture.original_record();
        let file = fixture.namespace().join("original.kdbx");
        fs::remove_file(&file).unwrap();
        let foreign = fixture.base.join("foreign.kdbx");
        fs::write(&foreign, &fixture.original).unwrap();
        match kind {
            "symlink" => symlink(&foreign, &file).unwrap(),
            "hardlink" => fs::hard_link(&foreign, &file).unwrap(),
            "directory" => fs::create_dir(&file).unwrap(),
            "swapped" => fs::write(&file, encrypted_password("Other original")).unwrap(),
            "corrupt" => fs::write(&file, b"corrupted original").unwrap(),
            _ => unreachable!(),
        }
        fs::set_permissions(&foreign, fs::Permissions::from_mode(0o600)).unwrap();
        if kind == "swapped" || kind == "corrupt" {
            fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
        }
        let before = inventory(&fixture.base);
        assert!(fixture
            .restore(&original.id, "rejected.kdbx", PASSWORD)
            .is_err());
        if kind == "corrupt" {
            let current = fixture.original_record();
            assert!(
                fixture
                    .restore(&current.id, "rejected.kdbx", PASSWORD)
                    .is_err(),
                "corrupt original passed validation"
            );
        }
        assert_eq!(inventory(&fixture.base), before);
    }
}

#[test]
fn wrong_credentials_and_no_clobber_failures_preserve_every_copy_and_local_edit() {
    let fixture = Fixture::new();
    fixture.save("Committed edit");
    fixture.change("Unsaved edit");
    let original = fixture.original_record();
    let existing = fixture.base.join("existing.kdbx");
    fs::write(&existing, b"existing destination").unwrap();
    let symbolic = fixture.base.join("symbolic.kdbx");
    symlink(&existing, &symbolic).unwrap();
    let hardlink = fixture.base.join("hardlink.kdbx");
    fs::hard_link(&existing, &hardlink).unwrap();
    let directory = fixture.base.join("directory.kdbx");
    fs::create_dir(&directory).unwrap();
    let before = inventory(&fixture.base);
    assert!(fixture
        .restore(
            &original.id,
            "wrong-credentials.kdbx",
            "wrong-fixture-password"
        )
        .is_err());
    for destination in [&existing, &symbolic, &hardlink, &directory, &fixture.source] {
        assert!(fixture
            .recovery()
            .restore_backup(
                original.id.clone(),
                path(destination),
                PASSWORD.into(),
                None
            )
            .is_err());
    }
    assert_eq!(
        inventory(&fixture.base),
        before,
        "a failed restore left a temporary file or replaced data"
    );
    assert!(fixture.vault.snapshot().unwrap().info.dirty);
    assert_eq!(
        fixture.vault.snapshot().unwrap().entries[0].title,
        "Unsaved edit"
    );
    fixture.vault.save().unwrap();
}

#[test]
fn namespace_and_file_permission_checks_are_read_only() {
    for target in ["root", "namespace", "original"] {
        let fixture = Fixture::new();
        fixture.save("Saved edit");
        let original = fixture.original_record();
        let changed = match target {
            "root" => fixture.root.clone(),
            "namespace" => fixture.namespace(),
            _ => fixture.namespace().join("original.kdbx"),
        };
        fs::set_permissions(&changed, fs::Permissions::from_mode(0o777)).unwrap();
        let before = inventory(&fixture.base);
        let listed = fixture.recovery().backups();
        if target == "original" {
            assert!(!listed.unwrap().iter().any(|b| b.is_original));
        } else {
            assert!(listed.is_err());
        }
        assert!(fixture
            .restore(&original.id, "rejected.kdbx", PASSWORD)
            .is_err());
        assert_eq!(inventory(&fixture.base), before);
    }
}

#[test]
fn namespace_symlinks_and_retargeted_source_aliases_are_never_followed() {
    let fixture = Fixture::new();
    fixture.save("Saved edit");
    let recovery = fixture.recovery();
    let original = fixture.original_record();
    let parked = fixture.source.with_file_name("parked.kdbx");
    fs::rename(&fixture.source, &parked).unwrap();
    symlink(&parked, &fixture.source).unwrap();
    assert!(CoreRecovery::new(path(&fixture.source), Some(path(&fixture.root))).is_err());
    // An object captured before retargeting never re-resolves the source alias.
    let destination = fixture.base.join("captured-copy.kdbx");
    recovery
        .restore_backup(
            original.id.clone(),
            path(&destination),
            PASSWORD.into(),
            None,
        )
        .unwrap();
    assert_eq!(fs::read(destination).unwrap(), fixture.original);
    let moved = fixture.root.with_extension("parked");
    fs::rename(&fixture.root, &moved).unwrap();
    symlink(&moved, &fixture.root).unwrap();
    assert!(recovery.backups().is_err());
    assert!(recovery
        .restore_backup(
            original.id,
            path(&fixture.base.join("rejected.kdbx")),
            PASSWORD.into(),
            None
        )
        .is_err());
    fs::remove_file(&fixture.root).unwrap();
    fs::rename(&moved, &fixture.root).unwrap();
    let namespace = fixture.namespace();
    let parked_namespace = namespace.with_extension("parked");
    fs::rename(&namespace, &parked_namespace).unwrap();
    symlink(&parked_namespace, &namespace).unwrap();
    assert!(recovery.backups().is_err());
}

#[test]
fn supports_backup_specific_password_and_key_file_including_key_file_only() {
    for password in ["historical-fixture-password", ""] {
        let fixture = Fixture::new();
        fixture.save("Current credentials");
        let keyfile = fixture.base.join("historical.key");
        fs::write(
            &keyfile,
            b"synthetic historical key file with no real secrets",
        )
        .unwrap();
        let mut key = if password.is_empty() {
            DatabaseKey::new()
        } else {
            DatabaseKey::new().with_password(password)
        };
        key = key
            .with_keyfile(&mut File::open(&keyfile).unwrap())
            .unwrap();
        let old = encrypted("Historical credentials", key);
        fs::write(fixture.namespace().join("original.kdbx"), &old).unwrap();
        let original = fixture.original_record();
        assert!(fixture
            .restore(&original.id, "wrong.kdbx", PASSWORD)
            .is_err());
        let destination = fixture.base.join("historical-copy.kdbx");
        fixture
            .recovery()
            .restore_backup(
                original.id,
                path(&destination),
                password.into(),
                Some(path(&keyfile)),
            )
            .unwrap();
        assert_eq!(fs::read(&destination).unwrap(), old);
        let reopened =
            CoreVault::open(path(&destination), password.into(), Some(path(&keyfile))).unwrap();
        assert_eq!(
            reopened.snapshot().unwrap().entries[0].title,
            "Historical credentials"
        );
    }
}

#[test]
fn recovery_applies_bounded_key_file_and_kdf_validation_before_creating_copy() {
    let fixture = Fixture::new();
    fixture.save("Saved edit");
    let original = fixture.original_record();
    let keyfile = fixture.base.join("oversized.key");
    File::create(&keyfile)
        .unwrap()
        .set_len(16 * 1024 * 1024 + 1)
        .unwrap();
    assert_eq!(
        fixture.recovery().restore_backup(
            original.id,
            path(&fixture.base.join("rejected.kdbx")),
            PASSWORD.into(),
            Some(path(&keyfile))
        ),
        Err(CoreError::UnsupportedDatabase)
    );
    let mut db = Database::new();
    db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
    let mut bytes = Vec::new();
    db.save(&mut bytes, DatabaseKey::new().with_password(PASSWORD))
        .unwrap();
    // Patch the outer AES round count without deriving its expensive key.
    let needle = 10u64.to_le_bytes();
    let position = bytes
        .windows(8)
        .position(|window| window == needle)
        .unwrap();
    bytes[position..position + 8].copy_from_slice(&100_000_001u64.to_le_bytes());
    fs::write(fixture.namespace().join("original.kdbx"), bytes).unwrap();
    let hostile = fixture.original_record();
    assert_eq!(
        fixture.restore(&hostile.id, "hostile.kdbx", PASSWORD),
        Err(CoreError::UnsupportedDatabase)
    );
    assert!(!fixture.base.join("rejected.kdbx").exists());
    assert!(!fixture.base.join("hostile.kdbx").exists());
}

#[test]
fn oversized_original_and_pipe_key_file_fail_without_creating_output() {
    let fixture = Fixture::new();
    fixture.save("Saved edit");
    let original = fixture.original_record();
    let keyfile = fixture.base.join("pipe.key");
    let name = std::ffi::CString::new(keyfile.as_os_str().as_bytes()).unwrap();
    // SAFETY: name is a live NUL-terminated path to a synthetic temporary FIFO.
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    let recovery = fixture.recovery();
    let destination = path(&fixture.base.join("rejected.kdbx"));
    let (sender, receiver) = std::sync::mpsc::channel();
    let task = std::thread::spawn(move || {
        sender
            .send(recovery.restore_backup(
                original.id,
                destination,
                PASSWORD.into(),
                Some(path(&keyfile)),
            ))
            .unwrap();
    });
    assert_eq!(
        receiver
            .recv_timeout(std::time::Duration::from_secs(2))
            .unwrap(),
        Err(CoreError::ReadFailed)
    );
    task.join().unwrap();
    let file = fixture.namespace().join("original.kdbx");
    File::options()
        .write(true)
        .open(&file)
        .unwrap()
        .set_len(256 * 1024 * 1024 + 1)
        .unwrap();
    assert!(!fixture
        .recovery()
        .backups()
        .unwrap()
        .iter()
        .any(|b| b.is_original));
    assert_eq!(
        fixture.restore(
            &format!("original:{}", "0".repeat(64)),
            "oversized-copy.kdbx",
            PASSWORD
        ),
        Err(CoreError::UnsupportedDatabase)
    );
    assert!(!fixture.base.join("rejected.kdbx").exists());
    assert!(!fixture.base.join("oversized-copy.kdbx").exists());
}

#[test]
fn fallback_namespace_is_available_without_a_configured_backup_root() {
    let fixture = Fixture::new();
    let vault = CoreVault::open(path(&fixture.source), PASSWORD.into(), None).unwrap();
    let id = vault.snapshot().unwrap().entries[0].id.clone();
    vault.update_entry(id, edit("Fallback save")).unwrap();
    vault.save().unwrap();
    vault.lock();
    let recovery = CoreRecovery::new(path(&fixture.source), None).unwrap();
    let original = recovery
        .backups()
        .unwrap()
        .into_iter()
        .find(|b| b.is_original)
        .unwrap();
    let destination = fixture.base.join("fallback-copy.kdbx");
    recovery
        .restore_backup(original.id, path(&destination), PASSWORD.into(), None)
        .unwrap();
    assert_eq!(fs::read(destination).unwrap(), fixture.original);
    assert!(!fixture.root.exists());
}

#[test]
#[ignore = "requires KeePassXC CLI; run cargo test -- --include-ignored"]
fn keepassxc_independently_opens_restored_original_and_generation() {
    let fixture = Fixture::new();
    fixture.save("Synthetic generation");
    fixture.save("Current source");
    fixture.vault.lock();
    let recovery = fixture.recovery();
    for (index, copy) in recovery.backups().unwrap().into_iter().enumerate() {
        let destination = fixture.base.join(format!("recovered-{index}.kdbx"));
        recovery
            .restore_backup(copy.id, path(&destination), PASSWORD.into(), None)
            .unwrap();
        let cli = std::env::var("KEEPASSXC_CLI")
            .unwrap_or_else(|_| "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli".into());
        let mut child = Command::new(cli)
            .args(["export", "-q", &path(&destination)])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("KeePassXC CLI required");
        child
            .stdin
            .take()
            .unwrap()
            .write_all(format!("{PASSWORD}\n").as_bytes())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "KeePassXC rejected restored copy (output intentionally withheld)"
        );
        let xml = String::from_utf8(output.stdout).unwrap();
        assert!(xml.contains("Synthetic original") || xml.contains("Synthetic generation"));
    }
}
