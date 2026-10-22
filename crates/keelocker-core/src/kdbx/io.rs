use crate::{kdbx::compatibility, CoreError};
use keepass::{config::DatabaseVersion, db::DatabaseOpenError, Database, DatabaseKey};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
};

#[cfg(test)]
#[path = "save_fault_tests.rs"]
pub(crate) mod save_faults;

pub fn digest(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

pub fn open_error(error: DatabaseOpenError) -> CoreError {
    use keepass::error::{DatabaseFormatError, Kdbx4OpenError, Kdbx4OuterHeaderError};
    match error {
        DatabaseOpenError::Key(_) => CoreError::WrongCredentials,
        DatabaseOpenError::UnsupportedVersion | DatabaseOpenError::VersionParse(_) => {
            CoreError::UnsupportedDatabase
        }
        DatabaseOpenError::Io(_) => CoreError::ReadFailed,
        DatabaseOpenError::Format(DatabaseFormatError::Kdbx4(Kdbx4OpenError::OuterHeader(
            Kdbx4OuterHeaderError::KdfConfig(_)
            | Kdbx4OuterHeaderError::OuterCipherConfig(_)
            | Kdbx4OuterHeaderError::InvalidEntry(_),
        ))) => CoreError::UnsupportedDatabase,
        _ => CoreError::CorruptedDatabase,
    }
}

pub fn load(path: &Path, key: &DatabaseKey) -> Result<(Database, [u8; 32]), CoreError> {
    let bytes = read_canonical(path)?;
    let hash = digest(&bytes);
    Ok((load_bytes(&bytes, key)?, hash))
}

pub(crate) fn read_canonical(path: &Path) -> Result<Vec<u8>, CoreError> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // Opening a FIFO must not block before its descriptor can be rejected.
        options.custom_flags(libc::O_NONBLOCK);
    }
    let file = options.open(path).map_err(|_| CoreError::ReadFailed)?;
    read_bound_file(path, file)
}

// Resolve the opened descriptor, not the pathname again: a symlink may have
// changed after canonicalization, including an ABA change before the callback.
fn read_bound_file(path: &Path, mut file: File) -> Result<Vec<u8>, CoreError> {
    let verify = |file: &File| {
        if descriptor_path(file)? == path {
            Ok(())
        } else {
            Err(std::io::Error::other("Opened vault identity changed"))
        }
    };
    verify(&file).map_err(|_| CoreError::ReadFailed)?;
    // Reject known oversized regular files before allocating their payload.
    // Keep the streaming bound too: file length can grow after this check.
    let metadata = file.metadata().map_err(|_| CoreError::ReadFailed)?;
    if !metadata.is_file() || metadata.len() > super::resource_limits::MAX_FILE_BYTES as u64 {
        return Err(CoreError::UnsupportedDatabase);
    }
    let mut bytes = Vec::new();
    (&mut file)
        .take(super::resource_limits::MAX_FILE_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| CoreError::ReadFailed)?;
    verify(&file).map_err(|_| CoreError::ReadFailed)?;
    if bytes.len() > super::resource_limits::MAX_FILE_BYTES {
        return Err(CoreError::UnsupportedDatabase);
    }
    Ok(bytes)
}

#[cfg(target_vendor = "apple")]
pub(super) fn descriptor_path(file: &File) -> std::io::Result<PathBuf> {
    use std::{ffi::OsString, os::fd::AsRawFd, os::unix::ffi::OsStringExt};

    let mut buffer = [0u8; libc::PATH_MAX as usize];
    // SAFETY: file owns a live fd and F_GETPATH writes at most PATH_MAX bytes
    // into the writable buffer, including its terminating NUL.
    if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETPATH, buffer.as_mut_ptr()) } == -1 {
        return Err(std::io::Error::last_os_error());
    }
    let end = buffer
        .iter()
        .position(|&byte| byte == 0)
        .ok_or_else(|| std::io::Error::other("Unterminated descriptor path"))?;
    Ok(PathBuf::from(OsString::from_vec(buffer[..end].to_vec())))
}

#[cfg(target_os = "linux")]
pub(super) fn descriptor_path(file: &File) -> std::io::Result<PathBuf> {
    use std::os::fd::AsRawFd;

    fs::read_link(format!("/proc/self/fd/{}", file.as_raw_fd()))
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux")))]
pub(super) fn descriptor_path(_file: &File) -> std::io::Result<PathBuf> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "Vault descriptor identity verification requires Apple or Linux support",
    ))
}

pub fn load_bytes(bytes: &[u8], key: &DatabaseKey) -> Result<Database, CoreError> {
    // A parser failure must not unwind through the live session's mutex.
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        load_bytes_checked(bytes, key)
    }))
    .unwrap_or(Err(CoreError::CorruptedDatabase))
}

fn load_bytes_checked(bytes: &[u8], key: &DatabaseKey) -> Result<Database, CoreError> {
    let version = Database::get_version(&mut &*bytes).map_err(open_error)?;
    if !matches!(
        version,
        DatabaseVersion::KDB4(0 | 1) | DatabaseVersion::KDB3(1)
    ) {
        return Err(CoreError::UnsupportedDatabase);
    }
    let decrypted = super::resource_limits::decrypt(bytes, key.clone())?;
    compatibility::check_xml(decrypted.xml())?;
    decrypted
        .parse()
        .map_err(super::resource_limits::open_error)
}

pub fn canonical_destination(path: &Path) -> Result<PathBuf, CoreError> {
    let parent = path
        .parent()
        .ok_or(CoreError::WriteFailed)?
        .canonicalize()
        .map_err(|_| CoreError::WriteFailed)?;
    Ok(parent.join(path.file_name().ok_or(CoreError::WriteFailed)?))
}

// An error means no destination was committed. A failed directory sync is a
// committed write with uncertain durability; callers must adopt its path/hash
// before reporting the warning, or a retry will conflict with our own bytes.
pub(crate) struct SaveOutcome {
    pub path: PathBuf,
    pub hash: [u8; 32],
    pub directory_synced: bool,
}

// All serialization and validation finish before touching the destination.
pub fn save(
    db: &Database,
    key: &DatabaseKey,
    path: &Path,
    expected: Option<[u8; 32]>,
    prepared: Option<keepass::db::PreparedKdbx4Save>,
    backup_root: Option<&Path>,
) -> Result<SaveOutcome, CoreError> {
    // The upstream writer emits 4.1; retain cipher/KDF settings when upgrading older files.
    let mut normalized;
    let db = if db.config.version != DatabaseVersion::KDB4(1) {
        normalized = db.clone();
        normalized.config.version = DatabaseVersion::KDB4(1);
        &normalized
    } else {
        db
    };
    let mut bytes = Vec::new();
    let reopened = match prepared {
        Some(prepared) => {
            prepared.save_and_reopen_with_limits(db, &mut bytes, &super::resource_limits::LIMITS)
        }
        None => {
            db.save_and_reopen_with_limits(&mut bytes, key.clone(), &super::resource_limits::LIMITS)
        }
    }
    .map_err(|error| {
        if super::resource_limits::is_resource_limit(&error) {
            CoreError::UnsupportedDatabase
        } else {
            CoreError::WriteFailed
        }
    })?;
    if !super::roundtrip::equivalent(db, &reopened) {
        return Err(CoreError::UnsupportedDatabase);
    }
    let parent = path.parent().ok_or(CoreError::WriteFailed)?;
    let mut temp = tempfile::NamedTempFile::new_in(parent).map_err(|_| CoreError::WriteFailed)?;
    #[cfg(test)]
    save_faults::checkpoint(save_faults::Stage::TempWrite, temp.path())
        .map_err(|_| CoreError::WriteFailed)?;
    temp.write_all(&bytes).map_err(|_| CoreError::WriteFailed)?;
    #[cfg(test)]
    save_faults::checkpoint(save_faults::Stage::TempSync, temp.path())
        .map_err(|_| CoreError::WriteFailed)?;
    temp.as_file()
        .sync_all()
        .map_err(|_| CoreError::WriteFailed)?;
    let backups = if let Some(hash) = expected {
        // Pin only source bytes accepted by the session's identity/hash check.
        let original = verify_source(path, hash)?;
        let backups = super::backups::BackupSet::preserve(path, backup_root, &original)?;
        preserve_legacy_backup(path, parent, &original)?;
        // External clients do not share our lock. Recheck identity as well as
        // digest after all mandatory backup writes, immediately before replacing.
        #[cfg(test)]
        save_faults::checkpoint(save_faults::Stage::BeforeFinalCheck, path)
            .map_err(|_| CoreError::WriteFailed)?;
        verify_source(path, hash)?;
        #[cfg(test)]
        save_faults::checkpoint(save_faults::Stage::BeforeReplace, path)
            .map_err(|_| CoreError::WriteFailed)?;
        temp.persist(path).map_err(|_| CoreError::WriteFailed)?;
        Some(backups)
    } else {
        #[cfg(test)]
        save_faults::checkpoint(save_faults::Stage::BeforeReplace, path)
            .map_err(|_| CoreError::WriteFailed)?;
        temp.persist_noclobber(path).map_err(|e| {
            if e.error.kind() == std::io::ErrorKind::AlreadyExists {
                CoreError::Conflict
            } else {
                CoreError::WriteFailed
            }
        })?;
        None
    };
    #[cfg(test)]
    let postcommit_ok = save_faults::checkpoint(save_faults::Stage::AfterReplace, path).is_ok();
    let directory_synced = sync_directory(parent).is_ok();
    #[cfg(test)]
    let directory_synced = postcommit_ok && directory_synced;
    if directory_synced {
        if let Some(backups) = backups {
            backups.prune();
        }
    }
    Ok(SaveOutcome {
        path: path.to_path_buf(),
        hash: digest(&bytes),
        directory_synced,
    })
}

/// Also used for a clean Save: preserve external-conflict semantics without
/// serializing, replacing bytes, rotating .bak or creating any backup namespace.
pub(crate) fn verify_source(path: &Path, expected: [u8; 32]) -> Result<Vec<u8>, CoreError> {
    let regular = || {
        fs::symlink_metadata(path)
            .map(|metadata| metadata.file_type().is_file())
            .unwrap_or(false)
    };
    if !regular() {
        return Err(CoreError::Conflict);
    }
    let bytes = read_canonical(path).map_err(|_| CoreError::Conflict)?;
    if !regular() || digest(&bytes) != expected {
        return Err(CoreError::Conflict);
    }
    Ok(bytes)
}

fn preserve_legacy_backup(path: &Path, parent: &Path, source: &[u8]) -> Result<(), CoreError> {
    // Keep compatibility with the adjacent .bak without letting a symlink
    // redirect an encrypted backup write or treating a directory as a file.
    let mut name = path.as_os_str().to_os_string();
    name.push(".bak");
    let backup = PathBuf::from(name);
    let check = || match fs::symlink_metadata(&backup) {
        Ok(metadata) if metadata.file_type().is_file() => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        _ => Err(CoreError::WriteFailed),
    };
    check()?;
    let mut temp = tempfile::NamedTempFile::new_in(parent).map_err(|_| CoreError::WriteFailed)?;
    temp.write_all(source).map_err(|_| CoreError::WriteFailed)?;
    temp.as_file()
        .sync_all()
        .map_err(|_| CoreError::WriteFailed)?;
    check()?;
    temp.persist(&backup).map_err(|_| CoreError::WriteFailed)?;
    // The backup's directory entry must be durable before the vault replace.
    File::open(parent)
        .and_then(|file| file.sync_all())
        .map_err(|_| CoreError::WriteFailed)
}

fn sync_directory(parent: &Path) -> std::io::Result<()> {
    #[cfg(test)]
    if FAIL_DIRECTORY_SYNC.with(|fail| fail.get()) {
        return Err(std::io::Error::other("injected directory sync failure"));
    }
    File::open(parent).and_then(|file| file.sync_all())
}

#[cfg(test)]
thread_local! {
    static FAIL_DIRECTORY_SYNC: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

#[cfg(test)]
pub(crate) fn with_directory_sync_failure<T>(action: impl FnOnce() -> T) -> T {
    struct Reset(bool);
    impl Drop for Reset {
        fn drop(&mut self) {
            FAIL_DIRECTORY_SYNC.with(|fail| fail.set(self.0));
        }
    }
    let _reset = Reset(FAIL_DIRECTORY_SYNC.with(|fail| fail.replace(true)));
    action()
}

#[cfg(all(test, unix))]
mod identity_tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn restored_path_cannot_relabel_a_descriptor_opened_through_a_symlink() {
        let dir = tempfile::tempdir().unwrap();
        let first = dir.path().join("first.kdbx");
        let second = dir.path().join("second.kdbx");
        let parked = dir.path().join("parked.kdbx");
        fs::write(&first, b"synthetic first vault").unwrap();
        fs::write(&second, b"synthetic second vault").unwrap();
        let canonical = first.canonicalize().unwrap();
        fs::rename(&first, &parked).unwrap();
        symlink(&second, &first).unwrap();
        let opened = File::open(&canonical).unwrap();
        fs::remove_file(&first).unwrap();
        fs::rename(&parked, &first).unwrap();
        assert_eq!(first.canonicalize().unwrap(), canonical);
        assert!(read_bound_file(&canonical, opened).is_err());
    }

    #[test]
    fn retargeted_parent_directory_cannot_publish_another_file() {
        let dir = tempfile::tempdir().unwrap();
        let first = dir.path().join("first");
        let second = dir.path().join("second");
        let parked = dir.path().join("parked");
        fs::create_dir(&first).unwrap();
        fs::create_dir(&second).unwrap();
        fs::write(first.join("vault.kdbx"), b"synthetic first vault").unwrap();
        fs::write(second.join("vault.kdbx"), b"synthetic second vault").unwrap();
        let canonical = first.join("vault.kdbx").canonicalize().unwrap();
        fs::rename(&first, &parked).unwrap();
        symlink(&second, &first).unwrap();
        assert!(read_bound_file(&canonical, File::open(&canonical).unwrap()).is_err());
    }
}
