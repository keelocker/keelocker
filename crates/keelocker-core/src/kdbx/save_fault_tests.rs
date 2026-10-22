//! Test-only save checkpoints. This module must be declared behind `cfg(test)`.
//! There are no environment-variable controls in the production save path.

use std::{cell::RefCell, io, path::Path};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Stage {
    TempWrite,
    TempSync,
    BackupWrite,
    BackupSync,
    BackupPublish,
    BackupPublished,
    BackupDirectorySync,
    BeforeFinalCheck,
    BeforeReplace,
    AfterReplace,
}

type Hook = Box<dyn FnMut(Stage, &Path) -> io::Result<()>>;

thread_local! {
    static HOOK: RefCell<Option<Hook>> = const { RefCell::new(None) };
}

/// The path identifies the temporary file for write/sync/publish checkpoints,
/// the backup directory for its sync, and the destination for final checkpoints.
pub(crate) fn checkpoint(stage: Stage, path: &Path) -> io::Result<()> {
    HOOK.with(|slot| match slot.borrow_mut().as_mut() {
        Some(hook) => hook(stage, path),
        None => Ok(()),
    })
}

pub(crate) fn with_hook<T>(
    hook: impl FnMut(Stage, &Path) -> io::Result<()> + 'static,
    operation: impl FnOnce() -> T,
) -> T {
    struct Reset(Option<Hook>);
    impl Drop for Reset {
        fn drop(&mut self) {
            HOOK.with(|slot| *slot.borrow_mut() = self.0.take());
        }
    }
    let _reset = Reset(HOOK.with(|slot| slot.replace(Some(Box::new(hook)))));
    operation()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CoreEntryEdit, CoreError, CoreVault};
    use keepass::{config::KdfConfig, db::Value, Database, DatabaseKey};
    use std::{
        cell::Cell,
        fs::{self, File},
        path::PathBuf,
        process::{Command, Output, Stdio},
        rc::Rc,
        sync::Arc,
    };

    const PASSWORD: &str = "synthetic-save-fault-password";
    const SECRET: &str = "synthetic protected password";
    const ATTACHMENT: &[u8] = b"synthetic binary\0attachment\xff";
    const EDITED: &str = "retained local edit";
    const EXTERNAL: &str = "other client's edit";
    const CRASH_EXIT: i32 = 86;
    const CHILD_TEST: &str = "kdbx::io::save_faults::tests::save_fault_subprocess";
    const CHILD_MODE: &str = "KEELOCKER_SAVE_FAULT_TEST_MODE";
    const CHILD_PATH: &str = "KEELOCKER_SAVE_FAULT_TEST_PATH";
    const CHILD_ROOT: &str = "KEELOCKER_SAVE_FAULT_TEST_ROOT";
    const CHILD_TITLE: &str = "KEELOCKER_SAVE_FAULT_TEST_TITLE";
    const REOPEN_VERIFIED: &str = "synthetic save-fault reopen verified";

    fn path(value: &Path) -> String {
        value.to_str().unwrap().to_owned()
    }

    fn create_source(destination: &Path, title: &str) {
        let mut db = Database::new();
        db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
        {
            let mut root = db.root_mut();
            let mut entry = root.add_entry();
            entry.set_unprotected("Title", title);
            entry.set_protected("Password", SECRET);
            entry.set_unprotected("Notes", "  preserved whitespace\n");
            entry.add_attachment("synthetic.bin", Value::protected(ATTACHMENT.to_vec()));
        }
        let mut file = File::create(destination).unwrap();
        db.save(&mut file, DatabaseKey::new().with_password(PASSWORD))
            .unwrap();
        file.sync_all().unwrap();
    }

    fn open(source: &Path, backup_root: &Path) -> Arc<CoreVault> {
        let vault = CoreVault::open(path(source), PASSWORD.into(), None).unwrap();
        let backup_root = backup_root.join("backups");
        fs::create_dir_all(&backup_root).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&backup_root, fs::Permissions::from_mode(0o700)).unwrap();
        }
        vault
            .configure_backup_directory(path(&backup_root))
            .unwrap();
        vault
    }

    fn edit(vault: &CoreVault) {
        let id = vault.snapshot().unwrap().entries[0].id.clone();
        vault
            .update_entry(
                id,
                CoreEntryEdit {
                    title: EDITED.into(),
                    username: String::new(),
                    password: SECRET.into(),
                    url: String::new(),
                    notes: "  preserved whitespace\n".into(),
                    tags: vec![],
                    custom_fields: vec![],
                    icon: None,
                },
            )
            .unwrap();
    }

    fn assert_dirty(vault: &CoreVault, source: &Path) {
        let snapshot = vault.snapshot().unwrap();
        assert!(snapshot.info.dirty);
        assert_eq!(snapshot.info.path, path(&source.canonicalize().unwrap()));
        let entry = vault.entry(snapshot.entries[0].id.clone()).unwrap();
        assert_eq!(entry.title, EDITED);
        assert_eq!(entry.password, SECRET);
        assert_eq!(
            vault
                .attachment(entry.id.clone(), "synthetic.bin".into())
                .unwrap(),
            ATTACHMENT
        );
        assert!(vault
            .history(entry.id)
            .unwrap()
            .iter()
            .any(|entry| entry.title == "original"));
    }

    fn assert_database(source: &Path, title: &str) {
        // Deliberately use a fresh password/KDF and the library parser, bypassing
        // CoreVault's session/hash and prepared-save state.
        let db = Database::open(
            &mut File::open(source).unwrap(),
            DatabaseKey::new().with_password(PASSWORD),
        )
        .unwrap();
        assert_eq!(db.iter_all_entries().count(), 1);
        let entry = db.iter_all_entries().next().unwrap();
        assert_eq!(entry.get_title(), Some(title));
        assert_eq!(entry.get_password(), Some(SECRET));
        assert_eq!(entry.get("Notes"), Some("  preserved whitespace\n"));
        assert_eq!(
            entry
                .attachment_by_name("synthetic.bin")
                .unwrap()
                .data
                .get(),
            ATTACHMENT
        );
        if title == EDITED {
            let original = entry.historical(0).unwrap();
            assert_eq!(original.get_title(), Some("original"));
            assert_eq!(original.get_password(), Some(SECRET));
            assert_eq!(
                original
                    .attachment_by_name("synthetic.bin")
                    .unwrap()
                    .data
                    .get(),
                ATTACHMENT
            );
        }
    }

    fn child(mode: &str, source: &Path, backup_root: &Path, title: &str) -> Output {
        Command::new(std::env::current_exe().unwrap())
            .args(["--exact", CHILD_TEST, "--ignored", "--nocapture"])
            .env(CHILD_MODE, mode)
            .env(CHILD_PATH, source)
            .env(CHILD_ROOT, backup_root)
            .env(CHILD_TITLE, title)
            .stdin(Stdio::null())
            .output()
            .unwrap()
    }

    fn independently_open(source: &Path, backup_root: &Path, title: &str) {
        let output = child("open", source, backup_root, title);
        assert!(
            output.status.success()
                && String::from_utf8_lossy(&output.stdout).contains(REOPEN_VERIFIED),
            "fresh-process password reopen failed: {}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn files_under(root: &Path) -> Vec<PathBuf> {
        let mut files = Vec::new();
        for entry in fs::read_dir(root).unwrap() {
            let entry = entry.unwrap();
            let kind = entry.file_type().unwrap();
            if kind.is_dir() {
                files.extend(files_under(&entry.path()));
            } else if kind.is_file() {
                files.push(entry.path());
            }
        }
        files
    }

    fn recovery_copy(root: &Path, source: &Path, original: &[u8]) -> PathBuf {
        let source = source.canonicalize().unwrap();
        files_under(root)
            .into_iter()
            .find(|file| {
                file.canonicalize().unwrap() != source && fs::read(file).unwrap() == original
            })
            .expect("a byte-identical encrypted recovery copy must survive")
    }

    fn simulated_enospc() -> io::Error {
        // ENOSPC on the supported Apple/Linux hosts. No real disk is filled.
        io::Error::from_raw_os_error(28)
    }

    #[test]
    fn precommit_io_errors_preserve_source_dirty_edit_and_save_retry() {
        for failed_stage in [
            Stage::TempWrite,
            Stage::TempSync,
            Stage::BackupWrite,
            Stage::BackupSync,
            Stage::BackupPublish,
            Stage::BackupDirectorySync,
            Stage::BeforeFinalCheck,
            Stage::BeforeReplace,
        ] {
            let dir = tempfile::tempdir().unwrap();
            let source = dir.path().join("source.kdbx");
            create_source(&source, "original");
            let original = fs::read(&source).unwrap();
            let vault = open(&source, dir.path());
            edit(&vault);
            let reached = Rc::new(Cell::new(false));
            let observed = Rc::clone(&reached);
            let result = with_hook(
                move |stage, _| {
                    if stage == failed_stage {
                        observed.set(true);
                        Err(simulated_enospc())
                    } else {
                        Ok(())
                    }
                },
                || vault.save(),
            );
            assert!(reached.get(), "missing checkpoint: {failed_stage:?}");
            assert_eq!(result, Err(CoreError::WriteFailed), "{failed_stage:?}");
            assert_eq!(fs::read(&source).unwrap(), original, "{failed_stage:?}");
            assert_dirty(&vault, &source);
            independently_open(&source, dir.path(), "original");

            vault.save().unwrap();
            assert!(!vault.snapshot().unwrap().info.dirty);
            independently_open(&source, dir.path(), EDITED);
            let backup = recovery_copy(dir.path(), &source, &original);
            independently_open(&backup, dir.path(), "original");
        }
    }

    #[test]
    fn partial_temp_and_backup_writes_allow_save_copy_rescue() {
        for failed_stage in [Stage::TempWrite, Stage::BackupWrite] {
            let dir = tempfile::tempdir().unwrap();
            let source = dir.path().join("source.kdbx");
            let copy = dir.path().join("rescued.kdbx");
            create_source(&source, "original");
            let original = fs::read(&source).unwrap();
            let prefix = original[..original.len() / 2].to_vec();
            let vault = open(&source, dir.path());
            edit(&vault);
            let reached = Rc::new(Cell::new(false));
            let observed = Rc::clone(&reached);
            let result = with_hook(
                move |stage, temporary| {
                    if stage == failed_stage {
                        fs::write(temporary, &prefix)?;
                        assert_eq!(fs::metadata(temporary)?.len(), prefix.len() as u64);
                        observed.set(true);
                        Err(simulated_enospc())
                    } else {
                        Ok(())
                    }
                },
                || vault.save(),
            );
            assert!(
                reached.get(),
                "missing partial-write checkpoint: {failed_stage:?}"
            );
            assert_eq!(result, Err(CoreError::WriteFailed));
            assert_eq!(fs::read(&source).unwrap(), original);
            assert_dirty(&vault, &source);
            independently_open(&source, dir.path(), "original");

            vault.save_as(path(&copy)).unwrap();
            let snapshot = vault.snapshot().unwrap();
            assert!(!snapshot.info.dirty);
            assert_eq!(snapshot.info.path, path(&copy.canonicalize().unwrap()));
            assert_eq!(fs::read(&source).unwrap(), original);
            independently_open(&copy, dir.path(), EDITED);
        }
    }

    #[test]
    fn failed_new_destination_save_does_not_publish_or_change_session_path() {
        for failed_stage in [Stage::TempWrite, Stage::TempSync, Stage::BeforeReplace] {
            let dir = tempfile::tempdir().unwrap();
            let source = dir.path().join("source.kdbx");
            let copy = dir.path().join("copy.kdbx");
            create_source(&source, "original");
            let original = fs::read(&source).unwrap();
            let vault = open(&source, dir.path());
            edit(&vault);
            let reached = Rc::new(Cell::new(false));
            let observed = Rc::clone(&reached);
            let result = with_hook(
                move |stage, _| {
                    if stage == failed_stage {
                        observed.set(true);
                        Err(simulated_enospc())
                    } else {
                        Ok(())
                    }
                },
                || vault.save_as(path(&copy)),
            );
            assert!(
                reached.get(),
                "missing Save As checkpoint: {failed_stage:?}"
            );
            assert_eq!(result, Err(CoreError::WriteFailed));
            assert!(!copy.exists());
            assert_eq!(fs::read(&source).unwrap(), original);
            assert_dirty(&vault, &source);
            independently_open(&source, dir.path(), "original");
            vault.save_as(path(&copy)).unwrap();
            independently_open(&copy, dir.path(), EDITED);
        }
    }

    #[test]
    fn external_replace_at_final_check_preserves_other_client_and_allows_save_copy() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("source.kdbx");
        let external = dir.path().join("external.kdbx");
        let rescue = dir.path().join("rescue.kdbx");
        create_source(&source, "original");
        create_source(&external, EXTERNAL);
        let original = fs::read(&source).unwrap();
        let external_bytes = fs::read(&external).unwrap();
        let vault = open(&source, dir.path());
        edit(&vault);
        let reached = Rc::new(Cell::new(false));
        let observed = Rc::clone(&reached);
        let result = with_hook(
            move |stage, destination| {
                if stage == Stage::BeforeFinalCheck {
                    fs::rename(&external, destination)?;
                    observed.set(true);
                }
                Ok(())
            },
            || vault.save(),
        );
        assert!(reached.get());
        assert_eq!(result, Err(CoreError::Conflict));
        assert_eq!(fs::read(&source).unwrap(), external_bytes);
        assert_dirty(&vault, &source);
        independently_open(&source, dir.path(), EXTERNAL);
        let backup = recovery_copy(dir.path(), &source, &original);
        independently_open(&backup, dir.path(), "original");
        assert_eq!(vault.save(), Err(CoreError::Conflict));
        assert_eq!(vault.reload_if_changed(), Err(CoreError::Conflict));
        assert_eq!(fs::read(&source).unwrap(), external_bytes);
        vault.save_as(path(&rescue)).unwrap();
        independently_open(&rescue, dir.path(), EDITED);
        assert_eq!(fs::read(&source).unwrap(), external_bytes);
    }

    #[test]
    fn save_as_refuses_existing_destination_even_if_created_at_publish_boundary() {
        for race in [false, true] {
            let dir = tempfile::tempdir().unwrap();
            let source = dir.path().join("source.kdbx");
            let destination = dir.path().join("existing.kdbx");
            let contender = dir.path().join("contender.kdbx");
            let rescue = dir.path().join("rescue.kdbx");
            create_source(&source, "original");
            create_source(&contender, EXTERNAL);
            let original = fs::read(&source).unwrap();
            let external_bytes = fs::read(&contender).unwrap();
            if !race {
                fs::rename(&contender, &destination).unwrap();
            }
            let vault = open(&source, dir.path());
            edit(&vault);
            let reached = Rc::new(Cell::new(false));
            let observed = Rc::clone(&reached);
            let result = with_hook(
                move |stage, target| {
                    if race && stage == Stage::BeforeReplace {
                        assert!(!target.exists());
                        fs::rename(&contender, target)?;
                        observed.set(true);
                    }
                    Ok(())
                },
                || vault.save_as(path(&destination)),
            );
            assert!(!race || reached.get());
            assert_eq!(result, Err(CoreError::Conflict));
            assert_eq!(fs::read(&destination).unwrap(), external_bytes);
            assert_eq!(fs::read(&source).unwrap(), original);
            assert_dirty(&vault, &source);
            independently_open(&source, dir.path(), "original");
            independently_open(&destination, dir.path(), EXTERNAL);
            vault.save_as(path(&rescue)).unwrap();
            independently_open(&rescue, dir.path(), EDITED);
            assert_eq!(fs::read(&destination).unwrap(), external_bytes);
        }
    }

    #[test]
    fn interrupted_temp_backup_and_pre_replace_leave_original_reopenable() {
        for stage in [
            Stage::TempWrite,
            Stage::BackupWrite,
            Stage::BackupPublished,
            Stage::BeforeReplace,
        ] {
            let dir = tempfile::tempdir().unwrap();
            let source = dir.path().join("source.kdbx");
            create_source(&source, "original");
            let original = fs::read(&source).unwrap();
            let output = child(&format!("{stage:?}"), &source, dir.path(), "");
            assert_eq!(output.status.code(), Some(CRASH_EXIT), "{stage:?}");
            assert_eq!(fs::read(&source).unwrap(), original);
            independently_open(&source, dir.path(), "original");
            if matches!(stage, Stage::TempWrite | Stage::BackupWrite) {
                assert!(
                    files_under(dir.path())
                        .iter()
                        .any(|file| { fs::read(file).unwrap() == original[..original.len() / 2] }),
                    "child must leave the interrupted ciphertext write on disk"
                );
            }
            let vault = open(&source, dir.path());
            edit(&vault);
            vault.save().unwrap();
            independently_open(&source, dir.path(), EDITED);
            let backup = recovery_copy(dir.path(), &source, &original);
            independently_open(&backup, dir.path(), "original");
        }
    }

    #[test]
    fn death_after_atomic_replace_leaves_valid_new_vault_and_recoverable_original() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("source.kdbx");
        create_source(&source, "original");
        let original = fs::read(&source).unwrap();
        let output = child("AfterReplace", &source, dir.path(), "");
        assert_eq!(output.status.code(), Some(CRASH_EXIT));
        assert_ne!(fs::read(&source).unwrap(), original);
        independently_open(&source, dir.path(), EDITED);
        let backup = recovery_copy(dir.path(), &source, &original);
        independently_open(&backup, dir.path(), "original");
    }

    #[test]
    #[ignore = "invoked only as an exact subprocess by save-fault tests"]
    fn save_fault_subprocess() {
        // Including ignored tests in the interop suite must not start a child
        // scenario unless the parent supplied the private test-only context.
        let Ok(mode) = std::env::var(CHILD_MODE) else {
            return;
        };
        let source = PathBuf::from(std::env::var_os(CHILD_PATH).unwrap());
        let backup_root = PathBuf::from(std::env::var_os(CHILD_ROOT).unwrap());
        if mode == "open" {
            assert_database(&source, &std::env::var(CHILD_TITLE).unwrap());
            println!("{REOPEN_VERIFIED}");
            return;
        }
        let crash_stage = match mode.as_str() {
            "TempWrite" => Stage::TempWrite,
            "BackupWrite" => Stage::BackupWrite,
            "BackupPublished" => Stage::BackupPublished,
            "BeforeReplace" => Stage::BeforeReplace,
            "AfterReplace" => Stage::AfterReplace,
            _ => panic!("unknown synthetic save interruption stage"),
        };
        let original = fs::read(&source).unwrap();
        let vault = open(&source, &backup_root);
        edit(&vault);
        with_hook(
            move |stage, temporary| {
                if stage == crash_stage {
                    if matches!(stage, Stage::TempWrite | Stage::BackupWrite) {
                        fs::write(temporary, &original[..original.len() / 2])?;
                    }
                    // Intentionally bypass destructors: the parent owns TempDir
                    // and verifies the actual disk state from a new process.
                    std::process::exit(CRASH_EXIT);
                }
                Ok(())
            },
            || {
                vault
                    .save()
                    .expect("child must reach its configured checkpoint")
            },
        );
        panic!("child save did not encounter its configured checkpoint");
    }
}
