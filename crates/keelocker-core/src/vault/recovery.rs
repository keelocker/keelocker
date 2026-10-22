//! Recovery reads encrypted copies independently of an unlocked vault session.
use crate::{
    kdbx::{backups, io, resource_limits},
    CoreError,
};
use keepass::DatabaseKey;
use std::{
    fs::File,
    io::Read,
    path::{Path, PathBuf},
    sync::Arc,
};
use zeroize::Zeroizing;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreBackup {
    /// A recognized generation filename or digest-pinned original token, never a path.
    pub id: String,
    pub created_at: Option<i64>,
    pub size: u64,
    pub is_original: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreRecoveryResult {
    pub path: String,
    /// False means the copy committed but its directory durability is uncertain.
    pub directory_synced: bool,
}

#[derive(uniffi::Object)]
pub struct CoreRecovery {
    path: PathBuf,
    backup_root: Option<PathBuf>,
}

#[uniffi::export]
impl CoreRecovery {
    /// Capture the namespace identity once. Neither opening nor listing creates
    /// directories, reads the source payload, or requires its current credentials.
    #[uniffi::constructor]
    pub fn new(path: String, backup_directory: Option<String>) -> Result<Arc<Self>, CoreError> {
        let path = backups::recovery_identity(Path::new(&path))?;
        let backup_root = backup_directory
            .map(|root| backups::configured_root(Path::new(&root)))
            .transpose()?;
        Ok(Arc::new(Self { path, backup_root }))
    }

    pub fn backups(&self) -> Result<Vec<CoreBackup>, CoreError> {
        backups::list(&self.path, self.backup_root.as_deref())
    }

    /// Validate with the backup's own supplied credentials, then publish the
    /// exact encrypted bytes at a new destination. No live session is involved.
    pub fn restore_backup(
        &self,
        id: String,
        destination: String,
        password: String,
        key_file: Option<String>,
    ) -> Result<CoreRecoveryResult, CoreError> {
        let password = Zeroizing::new(password);
        let bytes = backups::read(&self.path, self.backup_root.as_deref(), &id)?;
        let key = credentials(&password, key_file)?;
        // The same scoped KDF/decompression, compatibility and parser bounds as
        // normal open apply to originals as well as digest-verified generations.
        drop(io::load_bytes(&bytes, &key)?);
        let destination = io::canonical_destination(Path::new(&destination))?;
        if destination == self.path {
            return Err(CoreError::Conflict);
        }
        let (path, directory_synced) = backups::write_copy(&destination, &bytes)?;
        Ok(CoreRecoveryResult {
            path: path.to_string_lossy().into_owned(),
            directory_synced,
        })
    }
}

// Preserve normal-open credential composition and bounded key-file reads.
pub(super) fn credentials(
    password: &str,
    key_file: Option<String>,
) -> Result<DatabaseKey, CoreError> {
    let mut key = if password.is_empty() && key_file.is_some() {
        DatabaseKey::new()
    } else {
        DatabaseKey::new().with_password(password)
    };
    if let Some(path) = key_file {
        let mut options = File::options();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NONBLOCK);
        }
        let file = options.open(path).map_err(|_| CoreError::ReadFailed)?;
        let metadata = file.metadata().map_err(|_| CoreError::ReadFailed)?;
        if !metadata.is_file() {
            return Err(CoreError::ReadFailed);
        }
        let limit = resource_limits::MAX_KEY_FILE_BYTES as u64;
        if metadata.len() > limit {
            return Err(CoreError::UnsupportedDatabase);
        }
        let mut bytes = Zeroizing::new(Vec::new());
        file.take(limit + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| CoreError::ReadFailed)?;
        if bytes.len() as u64 > limit {
            return Err(CoreError::UnsupportedDatabase);
        }
        key = key
            .with_keyfile(&mut bytes.as_slice())
            .map_err(|_| CoreError::ReadFailed)?;
    }
    Ok(key)
}
