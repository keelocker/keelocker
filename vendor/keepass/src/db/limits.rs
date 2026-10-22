use crate::config::KdfConfig;
use std::convert::TryFrom;

/// Per-call safety bounds for opening a KDBX database. These never alter its KDF.
#[derive(Clone, Copy, Debug)]
pub struct KdbxLimits {
    /// Maximum encrypted input size in bytes.
    pub max_file_bytes: usize,
    /// Maximum expanded payload size, including XML and binary attachments.
    pub max_decompressed_bytes: usize,
    /// Maximum Argon2 memory in bytes (the unit stored by KDBX).
    pub max_argon2_memory_bytes: u64,
    /// Maximum Argon2 iteration count.
    pub max_argon2_iterations: u64,
    /// Maximum Argon2 lane count.
    pub max_argon2_parallelism: u32,
    /// Maximum AES-KDF round count.
    pub max_aes_rounds: u64,
}

/// A caller's supported resource budget was exceeded, or a KDF integer would
/// be truncated or fall outside the underlying algorithm's valid range.
#[derive(Debug, thiserror::Error)]
#[error("Database exceeds supported resource limits")]
pub struct ResourceLimitError;

impl KdbxLimits {
    /// Validate before any KDF work, without changing the supplied parameters.
    pub fn validate_kdf(&self, config: &KdfConfig) -> Result<(), ResourceLimitError> {
        let valid = match config {
            KdfConfig::Aes { rounds } => *rounds <= self.max_aes_rounds,
            KdfConfig::Argon2 {
                memory,
                iterations,
                parallelism,
                ..
            }
            | KdfConfig::Argon2id {
                memory,
                iterations,
                parallelism,
                ..
            } => {
                *memory <= self.max_argon2_memory_bytes
                    && *memory % 1024 == 0
                    && *memory / 1024 >= 8 * u64::from(*parallelism)
                    && u32::try_from(*memory / 1024).is_ok()
                    && *iterations > 0
                    && *iterations <= self.max_argon2_iterations
                    && u32::try_from(*iterations).is_ok()
                    && *parallelism > 0
                    && *parallelism <= self.max_argon2_parallelism
                    && *parallelism <= 0x00ff_ffff
            }
        };
        if valid {
            Ok(())
        } else {
            Err(ResourceLimitError)
        }
    }
}
