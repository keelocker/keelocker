use keelocker_core::{CoreEntryEdit, CoreError, CoreVault};
use keepass::{config::KdfConfig, Database, DatabaseKey};
use std::{fs, path::Path};

const PASSWORD: &str = "fixture-password";
fn key() -> DatabaseKey {
    DatabaseKey::new().with_password(PASSWORD)
}
fn path(p: &Path) -> String {
    p.to_string_lossy().into()
}
fn edit(title: &str) -> CoreEntryEdit {
    CoreEntryEdit {
        title: title.into(),
        username: "user".into(),
        password: "synthetic-secret".into(),
        url: String::new(),
        notes: String::new(),
        tags: vec![],
        custom_fields: vec![],
    }
}
fn database() -> Database {
    let mut db = Database::new();
    db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
    db.root_mut()
        .add_entry()
        .set_unprotected("Title", "Original");
    db
}
fn header_field(bytes: &[u8], field: u8, width: usize) -> (usize, usize) {
    let mut pos = 12;
    loop {
        let length = if width == 2 {
            u16::from_le_bytes(bytes[pos + 1..pos + 3].try_into().unwrap()) as usize
        } else {
            u32::from_le_bytes(bytes[pos + 1..pos + 5].try_into().unwrap()) as usize
        };
        if bytes[pos] == field {
            return (pos, length);
        }
        assert_ne!(bytes[pos], 0, "Required synthetic header field missing");
        pos += 1 + width + length;
    }
}

#[test]
fn kdbx3_protected_stream_header_tampering_is_rejected() {
    let mut bytes = fs::read(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../KeeLockerTests/Fixtures/interop.kdbx"),
    )
    .unwrap();
    Database::parse(&bytes, key()).unwrap();
    let (pos, _) = header_field(&bytes, 8, 2);
    bytes[pos + 3] ^= 0x80;
    assert!(
        Database::parse(&bytes, key()).is_err(),
        "Protected fields must never be parsed with a tampered header key"
    );
}

#[test]
fn malformed_reload_preserves_unsaved_session_and_save_copy() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("source.kdbx");
    let copy = dir.path().join("recovered.kdbx");
    let db = database();
    db.save(&mut fs::File::create(&source).unwrap(), key())
        .unwrap();
    let vault = CoreVault::open(path(&source), PASSWORD.into(), None).unwrap();
    let id = vault.snapshot().unwrap().entries[0].id.clone();
    vault
        .update_entry(id.clone(), edit("Unsaved edit"))
        .unwrap();
    let mut bytes = fs::read(&source).unwrap();
    let (pos, length) = header_field(&bytes, 3, 4);
    bytes[pos + 1..pos + 5].copy_from_slice(&1u32.to_le_bytes());
    bytes.drain(pos + 6..pos + 5 + length);
    fs::write(&source, bytes).unwrap();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| vault.reload()));
    assert!(
        result.is_ok(),
        "Malformed files must return an error without poisoning the session"
    );
    assert!(result.unwrap().is_err());
    assert_eq!(vault.entry(id.clone()).unwrap().title, "Unsaved edit");
    vault.save_as(path(&copy)).unwrap();
    assert_eq!(
        CoreVault::open(path(&copy), PASSWORD.into(), None)
            .unwrap()
            .entry(id)
            .unwrap()
            .password,
        "synthetic-secret"
    );
}

#[test]
fn rejected_entry_moves_do_not_create_history_or_dirty_changes() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("moves.kdbx");
    database()
        .save(&mut fs::File::create(&source).unwrap(), key())
        .unwrap();
    let vault = CoreVault::open(path(&source), PASSWORD.into(), None).unwrap();
    let id = vault.snapshot().unwrap().entries[0].id.clone();
    for destination in ["not-a-uuid".into(), uuid::Uuid::new_v4().to_string()] {
        let count = vault.entry(id.clone()).unwrap().history_count;
        assert_eq!(
            vault.move_entry(id.clone(), destination),
            Err(CoreError::InvalidOperation)
        );
        assert_eq!(vault.entry(id.clone()).unwrap().history_count, count);
        assert!(!vault.snapshot().unwrap().info.dirty);
    }
}

#[test]
fn tab_delimited_tags_are_rejected_before_mutation() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("tags.kdbx");
    database()
        .save(&mut fs::File::create(&source).unwrap(), key())
        .unwrap();
    let vault = CoreVault::open(path(&source), PASSWORD.into(), None).unwrap();
    let id = vault.snapshot().unwrap().entries[0].id.clone();
    let mut edited = edit("Changed");
    edited.tags = vec!["alpha\tbeta".into()];
    assert_eq!(
        vault.update_entry(id.clone(), edited),
        Err(CoreError::InvalidOperation)
    );
    assert_eq!(vault.entry(id).unwrap().title, "Original");
    assert!(!vault.snapshot().unwrap().info.dirty);
}

#[test]
fn deleting_custom_icon_group_cleans_references_and_remains_savable() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("groups.kdbx");
    let mut db = database();
    let id = {
        let mut root = db.root_mut();
        let mut child = root.add_group();
        child.name = "Custom icon group".into();
        child.set_icon_custom_new(vec![1, 2, 3]);
        child.id()
    };
    db.meta.last_selected_group = Some(id.uuid());
    db.meta.last_top_visible_group = Some(id.uuid());
    db.meta.entry_templates_group = Some(id.uuid());
    db.meta.recyclebin_uuid = Some(id.uuid());
    db.save(&mut fs::File::create(&source).unwrap(), key())
        .unwrap();
    let vault = CoreVault::open(path(&source), PASSWORD.into(), None).unwrap();
    vault.delete_group(id.to_string()).unwrap();
    vault.save().unwrap();
    let reopened = Database::parse(&fs::read(source).unwrap(), key()).unwrap();
    assert!(reopened.group(id).is_none());
    assert!(reopened.deleted_objects.contains_key(&id.uuid()));
    assert!(reopened.meta.last_selected_group.is_none());
    assert!(reopened.meta.last_top_visible_group.is_none());
    assert!(reopened.meta.entry_templates_group.is_none());
    assert!(reopened.meta.recyclebin_uuid.is_none());
}
