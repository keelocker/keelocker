mod error;
mod kdbx;
mod models;
mod vault;

pub use error::CoreError;
pub use models::*;
pub use vault::CoreVault;
uniffi::setup_scaffolding!();
