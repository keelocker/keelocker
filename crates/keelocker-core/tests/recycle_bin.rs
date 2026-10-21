use keelocker_core::{CoreEntryEdit, CoreError, CoreVault};
use keepass::{
    config::{DatabaseVersion, KdfConfig},
    db::{EntryId, GroupId, Times, Value},
    Database, DatabaseKey,
};
use std::{fs, path::Path, sync::Arc};

const PASSWORD: &str = "synthetic-recycle-password";

fn key() -> DatabaseKey {
    DatabaseKey::new().with_password(PASSWORD)
}

fn path(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn fixture() -> (Database, GroupId, EntryId) {
    let mut db = Database::new();
    db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
    let parent = {
        let mut root = db.root_mut();
        let mut group = root.add_group();
        group.name = "Original parent".into();
        group.id()
    };
    let entry = {
        let mut group = db.group_mut(parent).unwrap();
        let mut entry = group.add_entry();
        entry.set_unprotected("Title", "Synthetic entry");
        entry.set_protected("Password", "synthetic-secret");
        entry.times.location_changed = Some(Times::epoch());
        entry.id()
    };
    (db, parent, entry)
}

fn write(db: &Database, file: &Path) {
    db.save(&mut fs::File::create(file).unwrap(), key())
        .unwrap();
}

fn open(db: &Database) -> (tempfile::TempDir, std::path::PathBuf, Arc<CoreVault>) {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("synthetic.kdbx");
    write(db, &file);
    let vault = CoreVault::open(path(&file), PASSWORD.into(), None).unwrap();
    (dir, file, vault)
}

fn reopen(file: &Path) -> Database {
    Database::parse(&fs::read(file).unwrap(), key()).unwrap()
}

fn edit() -> CoreEntryEdit {
    CoreEntryEdit {
        title: "Rejected change".into(),
        username: String::new(),
        password: String::new(),
        url: String::new(),
        notes: String::new(),
        tags: vec![],
        custom_fields: vec![],
        icon: None,
    }
}

#[test]
fn trash_and_restore_preserve_history_at_imported_retention_capacity() {
    let (mut db, parent, entry) = fixture();
    let icon = {
        let mut source = db.entry_mut(entry).unwrap();
        source.set_protected("Password", "synthetic-older-password");
        source.add_attachment(
            "history-only.bin",
            Value::unprotected(b"synthetic historical bytes".to_vec()),
        );
        let icon = source.set_icon_custom_new(vec![7, 8, 9]).id();
        drop(source.track_changes());
        source.set_protected("Password", "synthetic-current-password");
        source.set_icon_builtin(0);
        source.remove_attachment_by_name("history-only.bin");
        icon
    };
    db.meta.history_max_items = Some(1);
    let (_dir, file, vault) = open(&db);
    for restore in [false, true] {
        if restore {
            vault.restore_entry(entry.to_string()).unwrap();
        } else {
            vault.delete_entry(entry.to_string()).unwrap();
        }
        vault.save().unwrap();
        let saved = reopen(&file);
        let source = saved.entry(entry).unwrap();
        assert_eq!(source.history.as_ref().unwrap().get_entries().len(), 1);
        let historical = source.historical(0).unwrap();
        assert_eq!(historical.get_password(), Some("synthetic-older-password"));
        assert_eq!(
            historical
                .attachment_by_name("history-only.bin")
                .unwrap()
                .data
                .get(),
            b"synthetic historical bytes"
        );
        assert!(saved.custom_icon(icon).is_some());
        if restore {
            assert_eq!(source.parent().id(), parent);
        }
    }
}

#[test]
fn enabled_and_missing_setting_trash_without_recreating_entry_or_tombstone() {
    for setting in [Some(true), None] {
        let (mut db, parent, entry) = fixture();
        db.meta.recyclebin_enabled = setting;
        let (_dir, file, vault) = open(&db);
        assert!(vault.snapshot().unwrap().info.recycle_bin_enabled);
        assert!(vault.snapshot().unwrap().info.recycle_bin_id.is_none());
        vault.delete_entry(entry.to_string()).unwrap();
        let snapshot = vault.snapshot().unwrap();
        let bin = snapshot.info.recycle_bin_id.unwrap();
        assert_eq!(snapshot.entries.len(), 1);
        assert_eq!(snapshot.entries[0].id, entry.to_string());
        assert_eq!(snapshot.entries[0].group_id, bin);
        assert_eq!(snapshot.entries[0].history_count, 0);
        assert_eq!(
            vault.entry(entry.to_string()).unwrap().password,
            "synthetic-secret"
        );
        vault.save().unwrap();
        let saved = reopen(&file);
        let source = saved.entry(entry).unwrap();
        assert_eq!(source.previous_parent().unwrap().id(), parent);
        assert!(source.times.location_changed.unwrap() > Times::epoch());
        assert_eq!(
            source.times.last_modification,
            db.entry(entry).unwrap().times.last_modification
        );
        assert!(!saved.deleted_objects.contains_key(&entry.uuid()));
        let group = saved.recycle_bin().unwrap();
        assert_eq!(group.enable_autotype, Some(false));
        assert_eq!(group.enable_searching, Some(false));
        assert_eq!(group.parent().unwrap().id(), saved.root().id());
        assert!(group.times.creation.is_some());
        assert!(group.times.last_modification.is_some());
        assert!(saved.meta.recyclebin_changed.is_some());
        assert_eq!(saved.meta.recyclebin_enabled, setting);
        vault.restore_entry(entry.to_string()).unwrap();
        assert_eq!(
            vault.entry(entry.to_string()).unwrap().group_id,
            parent.to_string()
        );
        vault.save().unwrap();
        assert!(!reopen(&file).deleted_objects.contains_key(&entry.uuid()));
    }
}

#[test]
fn disabled_recycle_bin_deletes_permanently_and_records_tombstone() {
    let (mut db, _, entry) = fixture();
    db.meta.recyclebin_enabled = Some(false);
    let (_dir, file, vault) = open(&db);
    assert!(!vault.snapshot().unwrap().info.recycle_bin_enabled);
    vault.delete_entry(entry.to_string()).unwrap();
    assert!(vault.snapshot().unwrap().entries.is_empty());
    assert!(vault.snapshot().unwrap().info.recycle_bin_id.is_none());
    vault.save().unwrap();
    let saved = reopen(&file);
    assert!(saved.entry(entry).is_none());
    assert!(saved.deleted_objects.contains_key(&entry.uuid()));
    assert_eq!(saved.meta.recyclebin_enabled, Some(false));
}

#[test]
fn invalid_missing_nil_and_root_references_create_a_separate_bin() {
    for reference in 0..4 {
        let (mut db, parent, entry) = fixture();
        let imported = match reference {
            0 => None,
            1 => Some(uuid::Uuid::new_v4()),
            2 => Some(uuid::Uuid::nil()),
            _ => Some(db.root().id().uuid()),
        };
        db.meta.recyclebin_uuid = imported;
        let (_dir, file, vault) = open(&db);
        assert!(vault.snapshot().unwrap().info.recycle_bin_id.is_none());
        assert_eq!(
            vault.restore_entry(entry.to_string()),
            Err(CoreError::InvalidOperation)
        );
        assert_eq!(
            vault.delete_entry_permanently(entry.to_string()),
            Err(CoreError::InvalidOperation)
        );
        assert!(!vault.snapshot().unwrap().info.dirty);
        vault.delete_entry(entry.to_string()).unwrap();
        vault.save().unwrap();
        let saved = reopen(&file);
        let bin = saved.recycle_bin().unwrap();
        assert_ne!(bin.id(), saved.root().id());
        assert_ne!(Some(bin.id().uuid()), imported);
        assert_eq!(
            saved.entry(entry).unwrap().previous_parent().unwrap().id(),
            parent
        );
        assert!(!saved.deleted_objects.contains_key(&entry.uuid()));
    }
}

#[test]
fn configured_nested_bin_is_reused_and_all_descendants_are_read_only() {
    let (mut db, parent, entry) = fixture();
    let bin = db.group_mut(parent).unwrap().add_group().id();
    db.group_mut(bin).unwrap().enable_autotype = Some(true);
    db.group_mut(bin).unwrap().enable_searching = None;
    let nested = db.group_mut(bin).unwrap().add_group().id();
    let trashed = db.group_mut(nested).unwrap().add_entry().id();
    db.meta.recyclebin_uuid = Some(bin.uuid());
    let (_dir, file, vault) = open(&db);
    assert_eq!(
        vault.snapshot().unwrap().info.recycle_bin_id,
        Some(bin.to_string())
    );
    vault.delete_entry(entry.to_string()).unwrap();
    assert_eq!(
        vault.entry(entry.to_string()).unwrap().group_id,
        bin.to_string()
    );
    vault.save().unwrap();
    let saved = reopen(&file);
    assert_eq!(saved.group(bin).unwrap().enable_autotype, Some(true));
    assert_eq!(saved.group(bin).unwrap().enable_searching, None);
    let count = vault.entry(trashed.to_string()).unwrap().history_count;
    for result in [
        vault.delete_entry(entry.to_string()),
        vault.delete_entry(trashed.to_string()),
        vault.update_entry(trashed.to_string(), edit()),
        vault.move_entry(trashed.to_string(), parent.to_string()),
        vault.move_entry(entry.to_string(), parent.to_string()),
        vault.put_attachment(trashed.to_string(), "x".into(), vec![1]),
        vault.delete_attachment(trashed.to_string(), "x".into()),
        vault.rename_group(bin.to_string(), "Wrong".into()),
        vault.move_group(bin.to_string(), db.root().id().to_string()),
        vault.move_group(nested.to_string(), parent.to_string()),
        vault.delete_group(nested.to_string()),
    ] {
        assert_eq!(result, Err(CoreError::InvalidOperation));
    }
    assert_eq!(
        vault.create_entry(nested.to_string(), edit()),
        Err(CoreError::InvalidOperation)
    );
    assert_eq!(
        vault.create_group(bin.to_string(), "Wrong".into()),
        Err(CoreError::InvalidOperation)
    );
    assert_eq!(
        vault.move_group(parent.to_string(), nested.to_string()),
        Err(CoreError::InvalidOperation)
    );
    assert_eq!(
        vault.entry(trashed.to_string()).unwrap().history_count,
        count
    );
    assert!(!vault.snapshot().unwrap().info.dirty);
    vault.restore_entry(trashed.to_string()).unwrap();
    assert_eq!(
        vault.entry(trashed.to_string()).unwrap().group_id,
        db.root().id().to_string()
    );
    vault.delete_entry_permanently(entry.to_string()).unwrap();
    vault.save().unwrap();
    assert!(reopen(&file).deleted_objects.contains_key(&entry.uuid()));
}

#[test]
fn restore_uses_previous_parent_and_falls_back_for_missing_or_trashed_parent() {
    for fallback in 0..3 {
        let (mut db, parent, entry) = fixture();
        let bin = db.root_mut().add_group().id();
        let nested = db.group_mut(bin).unwrap().add_group().id();
        db.meta.recyclebin_uuid = Some(bin.uuid());
        db.entry_mut(entry).unwrap().move_to(bin).unwrap();
        if fallback == 1 {
            db.group_mut(parent).unwrap().remove();
        } else if fallback == 2 {
            db.entry_mut(entry).unwrap().move_to(nested).unwrap();
        }
        let (_dir, file, vault) = open(&db);
        vault.restore_entry(entry.to_string()).unwrap();
        let expected = if fallback == 0 {
            parent
        } else {
            db.root().id()
        };
        assert_eq!(
            vault.entry(entry.to_string()).unwrap().group_id,
            expected.to_string()
        );
        assert_eq!(
            vault.restore_entry(entry.to_string()),
            Err(CoreError::InvalidOperation)
        );
        vault.save().unwrap();
        let saved = reopen(&file);
        assert_eq!(saved.entry(entry).unwrap().id(), entry);
        assert!(!saved.deleted_objects.contains_key(&entry.uuid()));
    }
}

#[test]
fn trash_restore_and_permanent_delete_preserve_shared_and_historical_assets() {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../KeeLockerTests/Fixtures/review-attachments.kdbx");
    let mut db = Database::parse(
        &fs::read(fixture).unwrap(),
        DatabaseKey::new().with_password("fixture-password"),
    )
    .unwrap();
    db.config.version = DatabaseVersion::KDB4(1);
    db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
    let entry = db
        .iter_all_entries()
        .find(|e| e.get_title() == Some("A"))
        .unwrap()
        .id();
    let shared = db
        .iter_all_entries()
        .find(|e| e.get_title() == Some("B"))
        .unwrap()
        .id();
    let icon = db
        .entry_mut(entry)
        .unwrap()
        .set_icon_custom_new(vec![1, 2, 3])
        .id();
    {
        let mut source = db.entry_mut(entry).unwrap();
        drop(source.track_changes());
        source.set_icon_builtin(0);
    }
    db.entry_mut(shared).unwrap().set_icon_custom(icon).unwrap();
    let (_dir, file, vault) = open(&db);
    vault.delete_entry(entry.to_string()).unwrap();
    vault.save().unwrap();
    let saved = reopen(&file);
    let source = saved.entry(entry).unwrap();
    assert!((0..source.history.as_ref().unwrap().get_entries().len())
        .filter_map(|i| source.historical(i))
        .any(|version| version.icon() == Some(&keepass::db::Icon::Custom(icon))));
    let old = (0..source.history.as_ref().unwrap().get_entries().len())
        .filter_map(|i| source.historical(i))
        .find(|version| version.attachment_by_name("old.bin").is_some())
        .unwrap();
    assert_eq!(
        old.attachment_by_name("old.bin").unwrap().data.get(),
        b"beta"
    );
    assert!(saved.custom_icon(icon).is_some());
    vault.restore_entry(entry.to_string()).unwrap();
    vault.delete_entry(entry.to_string()).unwrap();
    vault.delete_entry_permanently(entry.to_string()).unwrap();
    vault.save().unwrap();
    let saved = reopen(&file);
    assert!(saved.entry(entry).is_none());
    assert!(saved.deleted_objects.contains_key(&entry.uuid()));
    assert_eq!(
        saved
            .entry(shared)
            .unwrap()
            .attachment_by_name("shared.bin")
            .unwrap()
            .data
            .get(),
        b"alpha"
    );
    assert!(saved.custom_icon(icon).is_some());
}

#[test]
fn conflict_retains_in_memory_trash_mutation_and_can_save_copy() {
    let (db, _, entry) = fixture();
    let (dir, file, vault) = open(&db);
    let mut external = reopen(&file);
    external.meta.database_name = Some("External synthetic revision".into());
    write(&external, &file);
    vault.delete_entry(entry.to_string()).unwrap();
    assert_eq!(vault.save(), Err(CoreError::Conflict));
    let snapshot = vault.snapshot().unwrap();
    assert!(snapshot.info.dirty);
    assert_eq!(
        snapshot.entries[0].group_id,
        snapshot.info.recycle_bin_id.unwrap()
    );
    assert_eq!(
        reopen(&file).entry(entry).unwrap().parent().id(),
        db.entry(entry).unwrap().parent().id()
    );
    let copy = dir.path().join("recovered-trash.kdbx");
    vault.save_as(path(&copy)).unwrap();
    assert_eq!(
        reopen(&copy).entry(entry).unwrap().parent().id(),
        reopen(&copy).recycle_bin().unwrap().id()
    );
}

#[test]
#[ignore = "requires independent KeePassXC CLI"]
fn keepassxc_recycle_restore_and_permanent_delete_export_and_reopen() {
    use std::{
        io::Write,
        process::{Command, Stdio},
    };
    fn export(file: &Path) -> String {
        let cli = std::env::var("KEEPASSXC_CLI")
            .unwrap_or_else(|_| "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli".into());
        let mut child = Command::new(cli)
            .args(["export", "--quiet"])
            .arg(file)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("KeePassXC CLI required for interoperability tests");
        writeln!(child.stdin.take().unwrap(), "{PASSWORD}").unwrap();
        let result = child.wait_with_output().unwrap();
        assert!(
            result.status.success(),
            "KeePassXC export failed; output withheld"
        );
        String::from_utf8(result.stdout).unwrap()
    }
    let (db, parent, entry) = fixture();
    let (_dir, file, vault) = open(&db);
    vault.delete_entry(entry.to_string()).unwrap();
    vault.save().unwrap();
    let xml = export(&file);
    let document = roxmltree::Document::parse(&xml).unwrap();
    let bin = document
        .descendants()
        .find(|n| {
            n.has_tag_name("Group")
                && n.children()
                    .any(|c| c.has_tag_name("Name") && c.text() == Some("Recycle Bin"))
        })
        .unwrap();
    assert_eq!(
        bin.children().filter(|n| n.has_tag_name("Entry")).count(),
        1
    );
    for flag in ["EnableAutoType", "EnableSearching"] {
        assert_eq!(
            bin.children()
                .find(|node| node.has_tag_name(flag))
                .unwrap()
                .text(),
            Some("false")
        );
    }
    let reopened = CoreVault::open(path(&file), PASSWORD.into(), None).unwrap();
    reopened.restore_entry(entry.to_string()).unwrap();
    reopened.save().unwrap();
    let xml = export(&file);
    let document = roxmltree::Document::parse(&xml).unwrap();
    let group = document
        .descendants()
        .find(|n| {
            n.has_tag_name("Group")
                && n.children()
                    .any(|c| c.has_tag_name("Name") && c.text() == Some("Original parent"))
        })
        .unwrap();
    assert_eq!(
        group.children().filter(|n| n.has_tag_name("Entry")).count(),
        1
    );
    assert_eq!(
        reopened.entry(entry.to_string()).unwrap().group_id,
        parent.to_string()
    );
    reopened.delete_entry(entry.to_string()).unwrap();
    reopened
        .delete_entry_permanently(entry.to_string())
        .unwrap();
    reopened.save().unwrap();
    let xml = export(&file);
    let document = roxmltree::Document::parse(&xml).unwrap();
    assert_eq!(
        document
            .descendants()
            .filter(|n| n.has_tag_name("DeletedObject"))
            .count(),
        1
    );
    assert!(CoreVault::open(path(&file), PASSWORD.into(), None)
        .unwrap()
        .snapshot()
        .unwrap()
        .entries
        .is_empty());
}
