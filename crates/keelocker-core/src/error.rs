#[derive(Debug, thiserror::Error, uniffi::Error, PartialEq, Eq)]
pub enum CoreError {
    #[error("Wrong credentials")]
    WrongCredentials,
    #[error("Unsupported database")]
    UnsupportedDatabase,
    #[error("Corrupted database")]
    CorruptedDatabase,
    #[error("Failed to read file")]
    ReadFailed,
    #[error("Failed to write file")]
    WriteFailed,
    #[error("The file changed on disk. Save a copy instead.")]
    Conflict,
    #[error("Invalid operation")]
    InvalidOperation,
}
