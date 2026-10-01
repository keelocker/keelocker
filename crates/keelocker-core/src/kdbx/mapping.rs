use crate::models::*;
use keepass::db::EntryRef;
use keepass::Database;

pub fn groups(db: &Database) -> Vec<CoreGroup> {
    let mut result = Vec::new();
    let mut pending = vec![(db.root().id(), String::new())];
    while let Some((id, parent_path)) = pending.pop() {
        let group = db.group(id).expect("existing group");
        let path = if parent_path.is_empty() {
            group.name.clone()
        } else {
            format!("{parent_path} / {}", group.name)
        };
        result.push(CoreGroup {
            id: group.id().to_string(),
            parent_id: group.parent().map(|p| p.id().to_string()),
            name: group.name.clone(),
            path: path.clone(),
            created_at: group.times.creation.map(|t| t.and_utc().timestamp()),
            modified_at: group
                .times
                .last_modification
                .map(|t| t.and_utc().timestamp()),
        });
        let ids: Vec<_> = group.group_ids().collect();
        for id in ids.into_iter().rev() {
            pending.push((id, path.clone()));
        }
    }
    result
}

pub const STANDARD: [&str; 5] = ["Title", "UserName", "Password", "URL", "Notes"];

pub fn entry(source: EntryRef<'_>, secrets: bool) -> CoreEntry {
    let group_id = source.parent().id().to_string();
    entry_in_group(source, secrets, group_id)
}

pub fn entry_in_group(source: EntryRef<'_>, secrets: bool, group_id: String) -> CoreEntry {
    let mut custom_fields: Vec<_> = source
        .fields
        .iter()
        .filter(|(k, _)| !STANDARD.contains(&k.as_str()))
        .map(|(k, v)| CoreCustomField {
            name: k.clone(),
            value: if secrets || !v.is_protected() && k != "otp" {
                v.get().clone()
            } else {
                String::new()
            },
            protected: v.is_protected() || k == "otp",
        })
        .collect();
    custom_fields.sort_by(|a, b| a.name.cmp(&b.name));
    let otp = if secrets {
        source
            .get_otp()
            .ok()
            .filter(|o| o.period > 0 && (1..=10).contains(&o.digits))
            .and_then(|o| o.value_now().ok())
            .map(|o| CoreOtp {
                code: o.code,
                period: o.period.as_secs(),
            })
    } else {
        None
    };
    CoreEntry {
        id: source.id().to_string(),
        group_id,
        title: source.get_title().unwrap_or_default().into(),
        username: source.get_username().unwrap_or_default().into(),
        password: if secrets {
            source.get_password().unwrap_or_default().into()
        } else {
            String::new()
        },
        url: source.get_url().unwrap_or_default().into(),
        notes: source.get("Notes").unwrap_or_default().into(),
        tags: source.tags.clone(),
        custom_fields,
        attachments: source
            .attachments_named()
            .map(|(n, a)| CoreAttachmentMetadata {
                name: n.into(),
                size: a.data.get().len() as u64,
            })
            .collect(),
        history_count: source
            .history
            .as_ref()
            .map_or(0, |h| h.get_entries().len() as u64),
        created_at: source.times.creation.map(|t| t.and_utc().timestamp()),
        modified_at: source
            .times
            .last_modification
            .map(|t| t.and_utc().timestamp()),
        otp,
    }
}
