#![cfg(unix)]

use chrono::Utc;
use keelocker_core::{CoreEntryEdit, CoreError, CoreVault};
use keepass::{config::KdfConfig, Database, DatabaseKey};
use sha2::{Digest, Sha256};
use std::{
    fs,
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
const DAY_MICROS: u64 = 86_400_000_000;

fn path(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn hash(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let mut value = String::new();
    for byte in Sha256::digest(bytes) {
        write!(&mut value, "{byte:02x}").unwrap();
    }
    value
}

fn edit(title: &str) -> CoreEntryEdit {
    CoreEntryEdit {
        title: title.into(),
        icon: None,
        username: "synthetic-user".into(),
        password: "synthetic-password".into(),
        url: String::new(),
        notes: String::new(),
        tags: vec![],
        custom_fields: vec![],
    }
}

fn encrypted(title: &str) -> Vec<u8> {
    let mut db = Database::new();
    db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
    db.root_mut().add_entry().set_unprotected("Title", title);
    let mut bytes = Vec::new();
    db.save(&mut bytes, DatabaseKey::new().with_password(PASSWORD))
        .unwrap();
    bytes
}

fn open(file: &Path) -> Arc<CoreVault> {
    CoreVault::open(path(file), PASSWORD.into(), None).unwrap()
}

struct Fixture {
    _directory: tempfile::TempDir,
    source: PathBuf,
    root: PathBuf,
    vault: Arc<CoreVault>,
}

impl Fixture {
    fn new() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("synthetic.kdbx");
        fs::write(&source, encrypted("Synthetic original")).unwrap();
        let vault = open(&source);
        let root = directory.path().join("private").join("backups");
        vault.configure_backup_directory(path(&root)).unwrap();
        assert!(!root.exists(), "configuration must not mutate disk");
        Self {
            _directory: directory,
            source,
            root,
            vault,
        }
    }

    fn namespace(&self) -> PathBuf {
        self.root.join(hash(
            self.source.canonicalize().unwrap().as_os_str().as_bytes(),
        ))
    }

    fn change(&self, title: &str) {
        let id = self.vault.snapshot().unwrap().entries[0].id.clone();
        self.vault.update_entry(id, edit(title)).unwrap();
    }

    fn save(&self, title: &str) {
        self.change(title);
        self.vault.save().unwrap();
    }
}

fn generations(namespace: &Path) -> Vec<PathBuf> {
    if !namespace.exists() {
        return vec![];
    }
    let mut files: Vec<_> = fs::read_dir(namespace)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|file| {
            file.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("snapshot-v1-")
        })
        .collect();
    files.sort();
    files
}

fn inventory(directory: &Path) -> Vec<(PathBuf, Vec<u8>)> {
    let mut result = Vec::new();
    if directory.exists() {
        for entry in fs::read_dir(directory).unwrap() {
            let file = entry.unwrap().path();
            if fs::symlink_metadata(&file).unwrap().is_dir() {
                result.extend(inventory(&file));
            } else {
                result.push((file.clone(), fs::read(&file).unwrap()));
            }
        }
    }
    result.sort();
    result
}

#[test]
fn original_and_generations_survive_deletions_saves_and_reopen() {
    let fixture = Fixture::new();
    let first = fixture.vault.snapshot().unwrap().entries[0].id.clone();
    let root_id = fixture.vault.snapshot().unwrap().info.root_id;
    let second = fixture
        .vault
        .create_entry(root_id.clone(), edit("Synthetic second"))
        .unwrap();
    let third = fixture
        .vault
        .create_entry(root_id, edit("Synthetic third"))
        .unwrap();
    fixture.vault.save().unwrap();
    let original = fs::read(fixture.namespace().join("original.kdbx")).unwrap();
    assert_eq!(
        original,
        fs::read(fixture.source.with_extension("kdbx.bak")).unwrap()
    );

    fixture.vault.delete_entry(first.clone()).unwrap();
    fixture.vault.delete_entry_permanently(first).unwrap();
    fixture.vault.save().unwrap();
    let before_second_deletion = fs::read(&fixture.source).unwrap();
    fixture.vault.delete_entry(second.clone()).unwrap();
    fixture.vault.delete_entry_permanently(second).unwrap();
    fixture.vault.save().unwrap();
    fixture.vault.lock();
    let reopened = open(&fixture.source);
    reopened
        .configure_backup_directory(path(&fixture.root))
        .unwrap();
    reopened
        .update_entry(third, edit("Synthetic final"))
        .unwrap();
    reopened.save().unwrap();

    assert_eq!(
        fs::read(fixture.namespace().join("original.kdbx")).unwrap(),
        original
    );
    assert!(generations(&fixture.namespace())
        .iter()
        .any(|p| fs::read(p).unwrap() == before_second_deletion));
    assert_eq!(
        open(&fixture.namespace().join("original.kdbx"))
            .snapshot()
            .unwrap()
            .entries[0]
            .title,
        "Synthetic original"
    );
    assert_eq!(
        open(&fixture.source).snapshot().unwrap().entries[0].title,
        "Synthetic final"
    );
}

#[test]
fn clean_save_is_byte_identical_and_leaves_useful_backups_unchanged() {
    let fixture = Fixture::new();
    let initial = fs::read(&fixture.source).unwrap();
    fixture.vault.save().unwrap();
    fixture.vault.save_as(path(&fixture.source)).unwrap();
    assert_eq!(fs::read(&fixture.source).unwrap(), initial);
    assert!(!fixture.root.exists());
    assert!(!fixture.source.with_extension("kdbx.bak").exists());

    fixture.save("Edited once");
    let saved = fs::read(&fixture.source).unwrap();
    let backups = inventory(&fixture.root);
    let legacy = fs::read(fixture.source.with_extension("kdbx.bak")).unwrap();
    fixture.vault.save().unwrap();
    fixture.vault.save().unwrap();
    assert_eq!(fs::read(&fixture.source).unwrap(), saved);
    assert_eq!(inventory(&fixture.root), backups);
    assert_eq!(
        fs::read(fixture.source.with_extension("kdbx.bak")).unwrap(),
        legacy
    );
    assert_eq!(legacy, initial);

    let copy = fixture.source.with_file_name("clean-copy.kdbx");
    fixture.vault.save_as(path(&copy)).unwrap();
    assert!(copy.exists(), "clean Save As to a new path still writes");
    assert_eq!(
        open(&copy).snapshot().unwrap().entries[0].title,
        "Edited once"
    );
}

#[test]
fn clean_save_still_rejects_changed_or_symlinked_source() {
    for symbolic in [false, true] {
        let fixture = Fixture::new();
        if symbolic {
            let parked = fixture.source.with_file_name("parked.kdbx");
            fs::rename(&fixture.source, &parked).unwrap();
            symlink(&parked, &fixture.source).unwrap();
        } else {
            fs::write(&fixture.source, encrypted("External change")).unwrap();
        }
        assert_eq!(fixture.vault.save(), Err(CoreError::Conflict));
        assert!(!fixture.root.exists());
    }
}

#[test]
fn failed_backups_keep_original_and_dirty_edit_and_allow_rescue_save_as() {
    for obstruction in [
        "root-file",
        "root-link",
        "namespace-link",
        "original-link",
        "original-directory",
        "legacy-link",
        "legacy-directory",
    ] {
        let fixture = Fixture::new();
        let original = fs::read(&fixture.source).unwrap();
        let namespace = fixture.namespace();
        let foreign = fixture.source.with_file_name("foreign.kdbx");
        fs::write(&foreign, encrypted("Foreign recovery data")).unwrap();
        let foreign_bytes = fs::read(&foreign).unwrap();
        fs::create_dir_all(fixture.root.parent().unwrap()).unwrap();
        match obstruction {
            "root-file" => fs::write(&fixture.root, b"foreign").unwrap(),
            "root-link" => symlink(fixture.root.parent().unwrap(), &fixture.root).unwrap(),
            "namespace-link" => {
                fs::create_dir(&fixture.root).unwrap();
                symlink(fixture.root.parent().unwrap(), &namespace).unwrap();
            }
            "original-link" | "original-directory" => {
                fs::create_dir_all(&namespace).unwrap();
                if obstruction == "original-link" {
                    symlink(&foreign, namespace.join("original.kdbx")).unwrap();
                } else {
                    fs::create_dir(namespace.join("original.kdbx")).unwrap();
                }
            }
            "legacy-link" => symlink(&foreign, fixture.source.with_extension("kdbx.bak")).unwrap(),
            "legacy-directory" => {
                fs::create_dir(fixture.source.with_extension("kdbx.bak")).unwrap()
            }
            _ => unreachable!(),
        }
        fixture.change("Unsaved rescue");
        assert_eq!(
            fixture.vault.save(),
            Err(CoreError::WriteFailed),
            "{obstruction}"
        );
        assert_eq!(fs::read(&fixture.source).unwrap(), original);
        let snapshot = fixture.vault.snapshot().unwrap();
        assert!(snapshot.info.dirty);
        assert_eq!(
            snapshot.info.path,
            path(&fixture.source.canonicalize().unwrap())
        );
        assert_eq!(snapshot.entries[0].title, "Unsaved rescue");
        assert_eq!(fs::read(&foreign).unwrap(), foreign_bytes);
        let rescue = fixture.source.with_file_name("rescue.kdbx");
        fixture.vault.save_as(path(&rescue)).unwrap();
        assert_eq!(
            open(&rescue).snapshot().unwrap().entries[0].title,
            "Unsaved rescue"
        );
        assert_eq!(fs::read(&fixture.source).unwrap(), original);
    }
}

#[test]
fn filesystem_permission_denials_preserve_source_dirty_edit_and_allow_retry() {
    // Root can bypass these mode bits, so it cannot exercise this OS boundary.
    // SAFETY: geteuid has no preconditions and changes no state.
    if unsafe { libc::geteuid() } == 0 {
        return;
    }
    struct RestorePermissions(PathBuf, fs::Permissions);
    impl Drop for RestorePermissions {
        fn drop(&mut self) {
            fs::set_permissions(&self.0, self.1.clone()).unwrap();
        }
    }
    for obstruction in ["source-read", "destination-write", "backup-parent-write"] {
        let fixture = Fixture::new();
        let original = fs::read(&fixture.source).unwrap();
        fixture.change("Retained permission-denied edit");
        let target = match obstruction {
            "source-read" => fixture.source.clone(),
            "destination-write" => fixture.source.parent().unwrap().to_path_buf(),
            "backup-parent-write" => {
                let parent = fixture.root.parent().unwrap();
                fs::create_dir(parent).unwrap();
                parent.to_path_buf()
            }
            _ => unreachable!(),
        };
        let restore =
            RestorePermissions(target.clone(), fs::metadata(&target).unwrap().permissions());
        let mode = if obstruction == "source-read" {
            0o000
        } else {
            0o500
        };
        fs::set_permissions(&target, fs::Permissions::from_mode(mode)).unwrap();
        let result = fixture.vault.save();
        drop(restore);
        assert_eq!(
            result,
            Err(if obstruction == "source-read" {
                CoreError::Conflict
            } else {
                CoreError::WriteFailed
            }),
            "{obstruction}"
        );
        assert_eq!(
            fs::read(&fixture.source).unwrap(),
            original,
            "{obstruction}"
        );
        let snapshot = fixture.vault.snapshot().unwrap();
        assert!(snapshot.info.dirty);
        assert_eq!(snapshot.entries[0].title, "Retained permission-denied edit");
        assert_eq!(
            open(&fixture.source).snapshot().unwrap().entries[0].title,
            "Synthetic original"
        );
        fixture.vault.save().unwrap();
        assert!(!fixture.vault.snapshot().unwrap().info.dirty);
        assert_eq!(
            open(&fixture.source).snapshot().unwrap().entries[0].title,
            "Retained permission-denied edit"
        );
        assert_eq!(
            fs::read(fixture.namespace().join("original.kdbx")).unwrap(),
            original
        );
    }
}

#[test]
fn retry_deduplicates_source_and_preserves_existing_regular_original() {
    let fixture = Fixture::new();
    let namespace = fixture.namespace();
    fs::create_dir_all(&namespace).unwrap();
    let pinned = encrypted("An earlier pinned source");
    fs::write(namespace.join("original.kdbx"), &pinned).unwrap();
    let legacy = fixture.source.with_extension("kdbx.bak");
    fs::create_dir(&legacy).unwrap();
    fixture.change("Retried edit");
    for _ in 0..3 {
        assert_eq!(fixture.vault.save(), Err(CoreError::WriteFailed));
        assert_eq!(generations(&namespace).len(), 1);
        assert_eq!(fs::read(namespace.join("original.kdbx")).unwrap(), pinned);
    }
    fs::remove_dir(&legacy).unwrap();
    fixture.vault.save().unwrap();
    assert_eq!(generations(&namespace).len(), 1);
    assert_eq!(fs::read(namespace.join("original.kdbx")).unwrap(), pinned);
}

#[test]
fn backup_root_configuration_is_session_only_and_uses_current_canonical_path() {
    let fixture = Fixture::new();
    fixture.save("Configured root");
    assert!(fixture.namespace().join("original.kdbx").is_file());
    fixture.vault.lock();
    let reopened = open(&fixture.source);
    let id = reopened.snapshot().unwrap().entries[0].id.clone();
    reopened.update_entry(id, edit("Fallback root")).unwrap();
    reopened.save().unwrap();
    let fallback = fixture.source.parent().unwrap().join(".keelocker-backups");
    let first_namespace = fallback.join(fixture.namespace().file_name().unwrap());
    assert!(first_namespace.join("original.kdbx").is_file());
    let copy = fixture.source.with_file_name("new-path.kdbx");
    reopened
        .configure_backup_directory(path(&fixture.root))
        .unwrap();
    reopened.save_as(path(&copy)).unwrap();
    let id = reopened.snapshot().unwrap().entries[0].id.clone();
    reopened.update_entry(id, edit("Copy changed")).unwrap();
    reopened.save().unwrap();
    let copy_namespace = fixture
        .root
        .join(hash(copy.canonicalize().unwrap().as_os_str().as_bytes()));
    assert!(copy_namespace.join("original.kdbx").is_file());
    assert_ne!(copy_namespace, fixture.namespace());
}

#[test]
fn symlinked_configuration_ancestor_resolves_once_and_owned_paths_are_private() {
    let fixture = Fixture::new();
    let alias = fixture.source.with_file_name("alias");
    symlink(fixture.source.parent().unwrap(), &alias).unwrap();
    let configured = alias.join("private").join("backups");
    fixture
        .vault
        .configure_backup_directory(path(&configured))
        .unwrap();
    fs::remove_file(&alias).unwrap();
    fs::create_dir(&alias).unwrap();
    fixture.save("Private backup");
    assert!(!alias.join("private").exists());
    for directory in [
        fixture.root.parent().unwrap(),
        fixture.root.as_path(),
        &fixture.namespace(),
    ] {
        assert_eq!(
            fs::metadata(directory).unwrap().permissions().mode() & 0o777,
            0o700
        );
    }
    for file in fs::read_dir(fixture.namespace()).unwrap() {
        assert_eq!(
            file.unwrap().metadata().unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    assert_eq!(
        fs::metadata(fixture.source.with_extension("kdbx.bak"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
}

fn install_snapshot(namespace: &Path, micros: u64, bytes: &[u8]) -> PathBuf {
    let file = namespace.join(format!("snapshot-v1-{micros:020}-{}.kdbx", hash(bytes)));
    fs::write(&file, bytes).unwrap();
    file
}

#[test]
fn retention_keeps_latest_twenty_and_daily_thirty_without_pruning_foreign_or_symlinks() {
    let fixture = Fixture::new();
    fixture.save("Start rotation");
    let namespace = fixture.namespace();
    let original = fs::read(namespace.join("original.kdbx")).unwrap();
    let now = Utc::now().timestamp_micros() as u64;
    let today = now / DAY_MICROS;
    for ago in 1..=40 {
        install_snapshot(
            &namespace,
            (today - ago) * DAY_MICROS + 1,
            &encrypted(&format!("Day {ago}")),
        );
    }
    for n in 0..25 {
        install_snapshot(
            &namespace,
            now - 1_000_000 + n * 1_000,
            &encrypted(&format!("Recent {n}")),
        );
    }
    let foreign = namespace.join("foreign.kdbx");
    fs::write(&foreign, b"foreign file").unwrap();
    let malformed = namespace.join("snapshot-v1-unrecognized.kdbx");
    fs::write(&malformed, b"foreign name").unwrap();
    let linked = namespace.join(format!(
        "snapshot-v1-{:020}-{}.kdbx",
        (today - 60) * DAY_MICROS,
        "a".repeat(64)
    ));
    symlink(&foreign, &linked).unwrap();
    // A correctly shaped filename is insufficient ownership if its digest is wrong.
    let corrupt = namespace.join(format!(
        "snapshot-v1-{:020}-{}.kdbx",
        (today - 61) * DAY_MICROS,
        "b".repeat(64)
    ));
    fs::write(&corrupt, b"foreign bytes").unwrap();

    fixture.save("Rotate after commit");
    assert_eq!(fs::read(namespace.join("original.kdbx")).unwrap(), original);
    assert_eq!(fs::read(&foreign).unwrap(), b"foreign file");
    assert_eq!(fs::read(&malformed).unwrap(), b"foreign name");
    assert!(fs::symlink_metadata(&linked)
        .unwrap()
        .file_type()
        .is_symlink());
    assert_eq!(fs::read(&corrupt).unwrap(), b"foreign bytes");
    let snapshots: Vec<_> = generations(&namespace)
        .into_iter()
        .filter(|p| p != &linked && p != &corrupt && p != &malformed)
        .collect();
    assert_eq!(
        snapshots.len(),
        49,
        "20 recent plus 29 older daily generations"
    );
    for ago in 1..30 {
        let prefix = format!("snapshot-v1-{:020}", (today - ago) * DAY_MICROS + 1);
        assert!(
            snapshots.iter().any(|p| p
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with(&prefix)),
            "missing day {ago}"
        );
    }
    assert!(!snapshots.iter().any(|p| {
        let name = p.file_name().unwrap().to_string_lossy();
        let micros: u64 = name["snapshot-v1-".len().."snapshot-v1-".len() + 20]
            .parse()
            .unwrap();
        micros / DAY_MICROS < today - 29
    }));
}

#[test]
fn reaccepted_old_ciphertext_gets_a_current_recovery_generation_before_rotation() {
    let fixture = Fixture::new();
    fixture.save("Create pinned original");
    let namespace = fixture.namespace();
    let original = fs::read(namespace.join("original.kdbx")).unwrap();
    let old = encrypted("Reaccepted old version");
    let now = Utc::now().timestamp_micros() as u64;
    install_snapshot(&namespace, now.saturating_sub(2_000_000), &old);
    for index in 0..25 {
        install_snapshot(
            &namespace,
            now - 1_000_000 + index * 1_000,
            &encrypted(&format!("Newer generation {index}")),
        );
    }
    fixture.vault.lock();
    fs::write(&fixture.source, &old).unwrap();
    let reopened = open(&fixture.source);
    reopened
        .configure_backup_directory(path(&fixture.root))
        .unwrap();
    let id = reopened.snapshot().unwrap().entries[0].id.clone();
    reopened
        .update_entry(id.clone(), edit("Edit after reopening old ciphertext"))
        .unwrap();
    reopened.save().unwrap();
    assert!(
        generations(&namespace)
            .iter()
            .any(|file| fs::read(file).unwrap() == old),
        "The source accepted by this save must survive immutable-backup rotation"
    );
    reopened
        .update_entry(id, edit("Next saved edit replaces adjacent bak"))
        .unwrap();
    reopened.save().unwrap();
    assert_ne!(
        fs::read(fixture.source.with_extension("kdbx.bak")).unwrap(),
        old
    );
    assert!(generations(&namespace)
        .iter()
        .any(|file| fs::read(file).unwrap() == old));
    assert_eq!(fs::read(namespace.join("original.kdbx")).unwrap(), original);
}

#[test]
fn conflict_does_not_pin_unaccepted_source_or_rotate_existing_history() {
    let fixture = Fixture::new();
    fixture.save("Accepted first save");
    let namespace = fixture.namespace();
    let old = install_snapshot(&namespace, 1, &encrypted("Old generation"));
    let before = inventory(&fixture.root);
    fixture.change("Conflicting local edit");
    let external = encrypted("External change");
    fs::write(&fixture.source, &external).unwrap();
    assert_eq!(fixture.vault.save(), Err(CoreError::Conflict));
    assert_eq!(inventory(&fixture.root), before);
    assert!(old.exists());
    assert_eq!(fs::read(&fixture.source).unwrap(), external);

    let fixture = Fixture::new();
    fixture.change("First uncommitted edit");
    fs::write(&fixture.source, encrypted("Unaccepted source")).unwrap();
    assert_eq!(fixture.vault.save(), Err(CoreError::Conflict));
    assert!(!fixture.root.exists());
}

fn xc_export(file: &Path) -> String {
    let cli = std::env::var("KEEPASSXC_CLI")
        .unwrap_or_else(|_| "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli".into());
    let mut child = Command::new(cli)
        .args(["export", "-q", &path(file)])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("KeePassXC CLI required for interoperability tests");
    child
        .stdin
        .take()
        .unwrap()
        .write_all(format!("{PASSWORD}\n").as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "KeePassXC export failed (output intentionally withheld)"
    );
    String::from_utf8(output.stdout).unwrap()
}

#[test]
#[ignore = "requires KeePassXC CLI; run cargo test -- --include-ignored"]
fn keepassxc_reopens_original_and_generation_as_editable_recovery_copies() {
    let fixture = Fixture::new();
    let original = fs::read(&fixture.source).unwrap();
    fixture.save("Generation one");
    let generation = fs::read(&fixture.source).unwrap();
    fixture.save("Generation two");
    let id = fixture.vault.snapshot().unwrap().entries[0].id.clone();
    fixture.vault.delete_entry(id).unwrap();
    fixture.vault.save().unwrap();
    fixture.vault.lock();
    let generation_file = generations(&fixture.namespace())
        .into_iter()
        .find(|p| fs::read(p).unwrap() == generation)
        .unwrap();
    assert_eq!(
        fs::read(fixture.namespace().join("original.kdbx")).unwrap(),
        original
    );
    for (label, backup, expected) in [
        (
            "original",
            fixture.namespace().join("original.kdbx"),
            "Synthetic original",
        ),
        ("generation", generation_file, "Generation one"),
    ] {
        let rescue = fixture
            .source
            .with_file_name(format!("{label}-recovery.kdbx"));
        fs::copy(backup, &rescue).unwrap();
        assert!(xc_export(&rescue).contains(expected));
        let recovered = open(&rescue);
        let id = recovered.snapshot().unwrap().entries[0].id.clone();
        recovered
            .update_entry(id, edit(&format!("{label} recovered edit")))
            .unwrap();
        recovered.save().unwrap();
        let xml = xc_export(&rescue);
        assert!(xml.contains(&format!("{label} recovered edit")));
        assert!(xml.contains("synthetic-password"));
    }
}

#[test]
fn hard_linked_original_is_rejected_without_changing_foreign_permissions() {
    let fixture = Fixture::new();
    let namespace = fixture.namespace();
    fs::create_dir_all(&namespace).unwrap();
    let foreign = fixture.source.with_file_name("foreign.kdbx");
    fs::write(&foreign, encrypted("Foreign hard link")).unwrap();
    fs::set_permissions(&foreign, fs::Permissions::from_mode(0o640)).unwrap();
    fs::hard_link(&foreign, namespace.join("original.kdbx")).unwrap();
    let before = fs::read(&fixture.source).unwrap();
    fixture.change("Hard link blocked");
    assert_eq!(fixture.vault.save(), Err(CoreError::WriteFailed));
    assert_eq!(fs::read(&fixture.source).unwrap(), before);
    assert_eq!(
        fs::metadata(&foreign).unwrap().permissions().mode() & 0o777,
        0o640
    );
    assert!(fixture.vault.snapshot().unwrap().info.dirty);
}

#[test]
fn backup_failure_does_not_rotate_old_generations() {
    let fixture = Fixture::new();
    fixture.save("Initial saved edit");
    let namespace = fixture.namespace();
    for n in 1..=25 {
        install_snapshot(&namespace, n, &encrypted(&format!("Old {n}")));
    }
    let before = inventory(&fixture.root);
    let source = fs::read(&fixture.source).unwrap();
    let legacy = fixture.source.with_extension("kdbx.bak");
    fs::remove_file(&legacy).unwrap();
    fs::create_dir(&legacy).unwrap();
    fixture.change("Must not rotate");
    assert_eq!(fixture.vault.save(), Err(CoreError::WriteFailed));
    assert_eq!(fs::read(&fixture.source).unwrap(), source);
    for (file, bytes) in before {
        assert_eq!(fs::read(file).unwrap(), bytes);
    }
    assert!(generations(&namespace).len() >= 26);
}

#[test]
fn configuration_rejects_owned_root_symlinks_without_creating_directories() {
    let fixture = Fixture::new();
    let alias = fixture.source.with_file_name("root-link");
    symlink(fixture.source.parent().unwrap(), &alias).unwrap();
    assert_eq!(
        fixture.vault.configure_backup_directory(path(&alias)),
        Err(CoreError::WriteFailed)
    );
    assert!(!fixture.root.exists());
}
