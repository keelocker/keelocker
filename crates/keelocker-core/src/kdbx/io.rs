use crate::{kdbx::compatibility, CoreError};
use keepass::{config::DatabaseVersion, db::DatabaseOpenError, Database, DatabaseKey};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
};

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
    let file = File::open(path).map_err(|_| CoreError::ReadFailed)?;
    read_bound_file(path, file).map_err(|_| CoreError::ReadFailed)
}

// Resolve the opened descriptor, not the pathname again: a symlink may have
// changed after canonicalization, including an ABA change before the callback.
fn read_bound_file(path: &Path, mut file: File) -> std::io::Result<Vec<u8>> {
    let verify = |file: &File| {
        if descriptor_path(file)? == path {
            Ok(())
        } else {
            Err(std::io::Error::other("Opened vault identity changed"))
        }
    };
    verify(&file)?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    verify(&file)?;
    Ok(bytes)
}

#[cfg(target_vendor = "apple")]
fn descriptor_path(file: &File) -> std::io::Result<PathBuf> {
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
fn descriptor_path(file: &File) -> std::io::Result<PathBuf> {
    use std::os::fd::AsRawFd;

    fs::read_link(format!("/proc/self/fd/{}", file.as_raw_fd()))
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux")))]
fn descriptor_path(_file: &File) -> std::io::Result<PathBuf> {
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
    let decrypted = Database::decrypt(bytes, key.clone()).map_err(|e| {
        if matches!(version, DatabaseVersion::KDB3(_))
            && matches!(
                e,
                DatabaseOpenError::Cryptography(keepass::error::CryptographyError::InvalidPadding(
                    _
                ))
            )
        {
            CoreError::WrongCredentials
        } else {
            open_error(e)
        }
    })?;
    compatibility::check_xml(decrypted.xml())?;
    decrypted.parse().map_err(open_error)
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
        Some(prepared) => prepared.save_and_reopen(db, &mut bytes),
        None => db.save_and_reopen(&mut bytes, key.clone()),
    }
    .map_err(|_| CoreError::WriteFailed)?;
    if !super::roundtrip::equivalent(db, &reopened) {
        return Err(CoreError::UnsupportedDatabase);
    }
    let parent = path.parent().ok_or(CoreError::WriteFailed)?;
    let mut temp = tempfile::NamedTempFile::new_in(parent).map_err(|_| CoreError::WriteFailed)?;
    temp.write_all(&bytes).map_err(|_| CoreError::WriteFailed)?;
    temp.as_file()
        .sync_all()
        .map_err(|_| CoreError::WriteFailed)?;
    if let Some(hash) = expected {
        let original = read_canonical(path).map_err(|_| CoreError::Conflict)?;
        if fs::symlink_metadata(path)
            .map_err(|_| CoreError::Conflict)?
            .file_type()
            .is_symlink()
            || digest(&original) != hash
        {
            return Err(CoreError::Conflict);
        }
        // Keep an encrypted recovery copy. No plaintext is written to disk.
        let backup = PathBuf::from(format!("{}.bak", path.to_string_lossy()));
        let mut backup_tmp =
            tempfile::NamedTempFile::new_in(parent).map_err(|_| CoreError::WriteFailed)?;
        backup_tmp
            .write_all(&original)
            .map_err(|_| CoreError::WriteFailed)?;
        backup_tmp
            .as_file()
            .sync_all()
            .map_err(|_| CoreError::WriteFailed)?;
        backup_tmp
            .persist(backup)
            .map_err(|_| CoreError::WriteFailed)?;
        // Check again immediately before the replace; external clients do not share our lock.
        if digest(&read_canonical(path).map_err(|_| CoreError::Conflict)?) != hash {
            return Err(CoreError::Conflict);
        }
        temp.persist(path).map_err(|_| CoreError::WriteFailed)?;
    } else {
        temp.persist_noclobber(path).map_err(|e| {
            if e.error.kind() == std::io::ErrorKind::AlreadyExists {
                CoreError::Conflict
            } else {
                CoreError::WriteFailed
            }
        })?;
    }
    Ok(SaveOutcome {
        path: path.to_path_buf(),
        hash: digest(&bytes),
        directory_synced: sync_directory(parent).is_ok(),
    })
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
