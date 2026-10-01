use keepass::{db::EntryRef, Database};
use serde_json::{json, Value};
use std::collections::BTreeMap;

// KDBX renumbers binary IDs and history has no physical parent field. Compare
// the complete model with only these derived references normalized. Password
// protection is checked separately because keepass's Serialize omits that bit.
pub fn equivalent(a: &Database, b: &Database) -> bool {
    match (canonical(a), canonical(b)) {
        (Some(a), Some(b)) => a == b,
        _ => false,
    }
}

fn canonical(db: &Database) -> Option<Value> {
    let mut value = db
        .serialize_without_attachments(serde_json::value::Serializer)
        .ok()?;
    let attachments: BTreeMap<_, _> = db
        .iter_all_attachments()
        .map(|a| {
            (
                a.id().to_string(),
                json!([a.data.is_protected(), super::io::digest(a.data.get())]),
            )
        })
        .collect();
    let mut binaries: Vec<_> = attachments.values().cloned().collect();
    binaries.sort_by_key(Value::to_string);
    value["attachments"] = json!(binaries);
    // Reverse-reference sets are reconstructed by the library on parse.
    for icon in value["custom_icons"].as_object_mut()?.values_mut() {
        for field in ["entries", "groups"] {
            if let Some(refs) = icon[field].as_array_mut() {
                refs.sort_by_key(Value::to_string);
            }
        }
    }
    for entry in db.iter_all_entries() {
        let e = &mut value["entries"][entry.id().to_string()];
        normalize_entry(e, entry, &attachments, false)?;
    }
    Some(value)
}

fn normalize_entry(
    v: &mut Value,
    e: EntryRef<'_>,
    attachments: &BTreeMap<String, Value>,
    historical: bool,
) -> Option<()> {
    if historical {
        v.as_object_mut()?.remove("parent");
    }
    let protection: BTreeMap<_, _> = e
        .fields
        .iter()
        .map(|(k, v)| (k.clone(), v.is_protected()))
        .collect();
    v["field_protection"] = json!(protection);
    for id in v["attachments"].as_object_mut()?.values_mut() {
        *id = attachments.get(&id.as_u64()?.to_string())?.clone();
    }
    if let Some(history) = v["history"]["entries"].as_array_mut() {
        for (index, old) in history.iter_mut().enumerate() {
            normalize_entry(old, e.historical(index)?, attachments, true)?;
        }
    }
    Some(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metadata_projection_omits_only_the_attachment_table() {
        let mut db = Database::new();
        db.meta.database_name = Some("Projection fixture".into());
        db.root_mut()
            .add_entry()
            .add_attachment("file", keepass::db::Value::protected(vec![1, 2, 3]));
        let mut full = serde_json::to_value(&db).unwrap();
        full.as_object_mut().unwrap().remove("attachments");
        let metadata = db
            .serialize_without_attachments(serde_json::value::Serializer)
            .unwrap();
        assert_eq!(metadata, full);
    }

    #[test]
    fn attachment_bytes_and_protection_are_still_validated() {
        let mut db = Database::new();
        let id = db
            .root_mut()
            .add_entry()
            .add_attachment("file", keepass::db::Value::protected(vec![1, 2, 3]))
            .id();
        assert!(equivalent(&db, &db));
        let mut changed = db.clone();
        changed.attachment_mut(id).unwrap().data = keepass::db::Value::protected(vec![1, 2, 4]);
        assert!(!equivalent(&db, &changed));
        changed.attachment_mut(id).unwrap().data = keepass::db::Value::unprotected(vec![1, 2, 3]);
        assert!(!equivalent(&db, &changed));
    }
}
