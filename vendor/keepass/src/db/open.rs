use thiserror::Error;

use crate::{
    config::{DatabaseConfig, DatabaseVersion},
    crypt::ciphers::Cipher,
    db::{Database, Value},
    format::{
        kdb::parse_kdb,
        kdbx3::{decrypt_kdbx3, parse_kdbx3},
        kdbx4::{decrypt_kdbx4, parse_kdbx4},
        DatabaseVersionParseError,
    },
    DatabaseKey,
};

/// A KDBX payload decrypted once, ready for application XML checks and parsing.
/// The cipher state and attachment data remain owned by the library.
pub struct DecryptedKdbx {
    config: DatabaseConfig,
    attachments: Vec<Value<Vec<u8>>>,
    inner_decryptor: Box<dyn Cipher>,
    xml: zeroize::Zeroizing<Vec<u8>>,
}

impl DecryptedKdbx {
    /// Inspect the XML before parsing (for example, to reject unsupported extensions).
    pub fn xml(&self) -> &[u8] {
        &self.xml
    }

    /// Parse using the already-decrypted payload without deriving the key again.
    pub fn parse(mut self) -> Result<Database, DatabaseOpenError> {
        let mut db = crate::format::xml_db::parse_xml(
            &self.xml,
            &self.attachments,
            &mut *self.inner_decryptor,
        )
        .map_err(|e| {
            DatabaseOpenError::Format(match self.config.version {
                DatabaseVersion::KDB3(_) => {
                    DatabaseFormatError::Kdbx3(crate::format::kdbx3::Kdbx3OpenError::Xml(e))
                }
                _ => DatabaseFormatError::Kdbx4(crate::format::kdbx4::Kdbx4OpenError::Xml(e)),
            })
        })?;
        db.config = self.config;
        Ok(db)
    }
}

impl Database {
    /// Decrypt a KDBX3/4 payload once for inspection followed by parsing.
    pub fn decrypt(data: &[u8], key: DatabaseKey) -> Result<DecryptedKdbx, DatabaseOpenError> {
        let (config, attachments, inner_decryptor, xml) = match DatabaseVersion::parse(data)? {
            DatabaseVersion::KDB3(_) => {
                let (config, cipher, xml) = decrypt_kdbx3(data, &key)?;
                (config, Vec::new(), cipher, xml)
            }
            DatabaseVersion::KDB4(_) => decrypt_kdbx4(data, &key)?,
            _ => return Err(DatabaseOpenError::UnsupportedVersion),
        };
        Ok(DecryptedKdbx {
            config,
            attachments,
            inner_decryptor,
            xml: zeroize::Zeroizing::new(xml),
        })
    }

    /// Parse a database from a std::io::Read
    pub fn open(
        source: &mut dyn std::io::Read,
        key: DatabaseKey,
    ) -> Result<Database, DatabaseOpenError> {
        let mut data = Vec::new();
        source.read_to_end(&mut data)?;

        Database::parse(data.as_ref(), key)
    }

    /// Parse a database from a byte slice
    pub fn parse(data: &[u8], key: DatabaseKey) -> Result<Database, DatabaseOpenError> {
        let database_version = DatabaseVersion::parse(data)?;

        match database_version {
            DatabaseVersion::KDB(_) => parse_kdb(data, &key),
            DatabaseVersion::KDB2(_) => Err(DatabaseOpenError::UnsupportedVersion),
            DatabaseVersion::KDB3(_) => parse_kdbx3(data, &key),
            DatabaseVersion::KDB4(_) => parse_kdbx4(data, &key),
        }
    }

    /// Helper function to load a database into its internal XML chunks
    pub fn get_xml(
        source: &mut dyn std::io::Read,
        key: DatabaseKey,
    ) -> Result<Vec<u8>, DatabaseOpenError> {
        let mut data = Vec::new();
        source.read_to_end(&mut data)?;

        let database_version = DatabaseVersion::parse(data.as_ref())?;

        let data = match database_version {
            DatabaseVersion::KDB(_) => return Err(DatabaseOpenError::UnsupportedVersion),
            DatabaseVersion::KDB2(_) => return Err(DatabaseOpenError::UnsupportedVersion),
            DatabaseVersion::KDB3(_) => decrypt_kdbx3(data.as_ref(), &key)?.2,
            DatabaseVersion::KDB4(_) => decrypt_kdbx4(data.as_ref(), &key)?.3,
        };

        Ok(data)
    }

    /// Get the version of a database without decrypting it
    pub fn get_version(
        source: &mut dyn std::io::Read,
    ) -> Result<DatabaseVersion, DatabaseOpenError> {
        let mut data = vec![0; DatabaseVersion::get_version_header_size()];
        source.read_exact(&mut data)?;
        let version = DatabaseVersion::parse(data.as_ref())?;
        Ok(version)
    }
}

/// Errors that can occur when opening a database
#[derive(Debug, Error)]
#[non_exhaustive]
pub enum DatabaseOpenError {
    /// I/O errors that can occur while reading the database from the source
    #[error(transparent)]
    Io(#[from] std::io::Error),

    /// An unexpected end of file was encountered while reading the database
    #[error("Unexpected end of file")]
    UnexpectedEof,

    /// Errors related to parsing the database version from the file header
    #[error(transparent)]
    VersionParse(#[from] DatabaseVersionParseError),

    /// Attempted to open a database with an unsupported version
    #[error("Unsupported database version")]
    UnsupportedVersion,

    /// Errors related to the database key, such as incorrect keys
    #[error(transparent)]
    Key(#[from] crate::key::DatabaseKeyError),

    /// Errors related to decryption
    #[error(transparent)]
    Cryptography(#[from] crate::crypt::CryptographyError),

    /// Errors related to parsing the database format
    #[error(transparent)]
    Format(#[from] DatabaseFormatError),
}

/// Format-specific database parsing errors
#[derive(Debug, Error)]
#[non_exhaustive]
pub enum DatabaseFormatError {
    /// Errors related to parsing KDB files
    #[error(transparent)]
    Kdb(#[from] crate::format::kdb::KdbOpenError),

    /// Errors related to parsing KDBX3 files
    #[error(transparent)]
    Kdbx3(#[from] crate::format::kdbx3::Kdbx3OpenError),

    /// Errors related to parsing KDBX4 files
    #[error(transparent)]
    Kdbx4(#[from] crate::format::kdbx4::Kdbx4OpenError),
}
