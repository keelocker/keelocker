use crate::{kdbx::compatibility, CoreError};
use keepass::{config::DatabaseVersion, db::DatabaseOpenError, Database, DatabaseKey};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::Write,
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
    let bytes = fs::read(path).map_err(|_| CoreError::ReadFailed)?;
    let hash = digest(&bytes);
    Ok((load_bytes(&bytes, key)?, hash))
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

// All serialization and validation finish before touching the destination.
pub fn save(
    db: &Database,
    key: &DatabaseKey,
    path: &Path,
    expected: Option<[u8; 32]>,
    prepared: Option<keepass::db::PreparedKdbx4Save>,
) -> Result<[u8; 32], CoreError> {
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
        let original = fs::read(path).map_err(|_| CoreError::Conflict)?;
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
        if digest(&fs::read(path).map_err(|_| CoreError::Conflict)?) != hash {
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
    File::open(parent)
        .and_then(|f| f.sync_all())
        .map_err(|_| CoreError::WriteFailed)?;
    Ok(digest(&bytes))
}
