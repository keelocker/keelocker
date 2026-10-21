//! Supported-app bounds, applied per operation without changing vault settings.

use crate::CoreError;
use keepass::{
    config::DatabaseVersion,
    db::{DatabaseOpenError, DecryptedKdbx, KdbxLimits, ResourceLimitError},
    Database, DatabaseKey,
};
use std::error::Error;

pub(crate) const MAX_FILE_BYTES: usize = 256 * 1024 * 1024;
pub(crate) const MAX_KEY_FILE_BYTES: usize = 16 * 1024 * 1024;
pub(crate) const LIMITS: KdbxLimits = KdbxLimits {
    max_file_bytes: MAX_FILE_BYTES,
    max_decompressed_bytes: 256 * 1024 * 1024,
    max_argon2_memory_bytes: 256 * 1024 * 1024,
    max_argon2_iterations: 100,
    max_argon2_parallelism: 16,
    max_aes_rounds: 100_000_000,
};

pub(crate) fn decrypt(bytes: &[u8], key: DatabaseKey) -> Result<DecryptedKdbx, CoreError> {
    Database::decrypt_with_limits(bytes, key, &LIMITS).map_err(|error| {
        if matches!(
            Database::get_version(&mut &*bytes),
            Ok(DatabaseVersion::KDB3(_))
        ) && matches!(
            error,
            DatabaseOpenError::Cryptography(keepass::error::CryptographyError::InvalidPadding(_))
        ) {
            CoreError::WrongCredentials
        } else {
            open_error(error)
        }
    })
}

// Limits on nested XML attachment decompression are carried through the existing
// parser errors. Preserve their classification instead of reporting an I/O or
// corruption failure. io::Error's source can skip its embedded custom error.
pub(crate) fn is_resource_limit(error: &(dyn Error + 'static)) -> bool {
    error
        .downcast_ref::<DatabaseOpenError>()
        .is_some_and(DatabaseOpenError::is_resource_limit)
        || matches!(error.downcast_ref::<keepass::db::DatabaseSaveError>(), Some(keepass::db::DatabaseSaveError::Validation(error)) if error.is_resource_limit())
        || error.is::<ResourceLimitError>()
        || error
            .downcast_ref::<std::io::Error>()
            .and_then(std::io::Error::get_ref)
            .is_some_and(|error| error.is::<ResourceLimitError>())
        || error.source().is_some_and(is_resource_limit)
}

pub(crate) fn open_error(error: DatabaseOpenError) -> CoreError {
    if is_resource_limit(&error) {
        CoreError::UnsupportedDatabase
    } else {
        super::io::open_error(error)
    }
}
