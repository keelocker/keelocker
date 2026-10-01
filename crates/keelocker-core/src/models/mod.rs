// KeeLocker-owned bridge DTOs. No keepass types or key material cross FFI.
#[derive(Clone, uniffi::Record)]
pub struct CoreVaultInfo {
    pub name: String,
    pub path: String,
    pub dirty: bool,
    pub root_id: String,
}
#[derive(Clone, uniffi::Record)]
pub struct CoreGroup {
    pub id: String,
    pub parent_id: Option<String>,
    pub name: String,
    pub path: String,
    pub created_at: Option<i64>,
    pub modified_at: Option<i64>,
}
#[derive(Clone, uniffi::Record)]
pub struct CoreCustomField {
    pub name: String,
    pub value: String,
    pub protected: bool,
}
#[derive(Clone, uniffi::Record)]
pub struct CoreAttachmentMetadata {
    pub name: String,
    pub size: u64,
}
#[derive(Clone, uniffi::Record)]
pub struct CoreOtp {
    pub code: String,
    pub period: u64,
}
#[derive(Clone, uniffi::Record)]
pub struct CoreEntry {
    pub id: String,
    pub group_id: String,
    pub title: String,
    pub username: String,
    pub password: String,
    pub url: String,
    pub notes: String,
    pub tags: Vec<String>,
    pub custom_fields: Vec<CoreCustomField>,
    pub attachments: Vec<CoreAttachmentMetadata>,
    pub history_count: u64,
    pub created_at: Option<i64>,
    pub modified_at: Option<i64>,
    pub otp: Option<CoreOtp>,
}
#[derive(Clone, uniffi::Record)]
pub struct CoreEntryEdit {
    pub title: String,
    pub username: String,
    pub password: String,
    pub url: String,
    pub notes: String,
    pub tags: Vec<String>,
    pub custom_fields: Vec<CoreCustomField>,
}
#[derive(Clone, uniffi::Record)]
pub struct CoreSnapshot {
    pub info: CoreVaultInfo,
    pub groups: Vec<CoreGroup>,
    pub entries: Vec<CoreEntry>,
}
