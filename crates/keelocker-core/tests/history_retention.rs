use keelocker_core::{CoreEntryEdit, CoreVault};
use keepass::{
    config::{DatabaseVersion, KdfConfig},
    db::{AutoType, AutoTypeAssociation, CustomDataItem, CustomDataValue, EntryId, Value},
    Database, DatabaseKey,
};
use std::{fs, path::Path};

const PASSWORD: &str = "fixture-password";

fn key() -> DatabaseKey {
    DatabaseKey::new().with_password(PASSWORD)
}

fn path(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn write(db: &Database, path: &Path) {
    db.save(&mut fs::File::create(path).unwrap(), key())
        .unwrap();
}

fn edit(title: &str) -> CoreEntryEdit {
    CoreEntryEdit {
        title: title.into(),
        username: String::new(),
        password: "synthetic".into(),
        url: String::new(),
        notes: String::new(),
        tags: vec![],
        custom_fields: vec![],
    }
}

#[test]
fn imported_item_limits_apply_on_mutation_without_pruning_on_open() {
    for (items, size, expected) in [
        (Some(0), Some(-1), vec![]),
        (Some(2), Some(-1), vec!["v3", "v2"]),
        (Some(-1), Some(-1), vec!["v3", "v2", "v1", "v0"]),
        (None, None, vec!["v3", "v2", "v1", "v0"]),
        (Some(-1), Some(0), vec![]),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("history.kdbx");
        let mut db = Database::new();
        db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
        let id = db.root_mut().add_entry().id();
        db.entry_mut(id).unwrap().set_unprotected("Title", "v0");
        for title in ["v1", "v2", "v3"] {
            db.entry_mut(id)
                .unwrap()
                .track_changes()
                .set_unprotected("Title", title);
        }
        db.meta.history_max_items = items;
        db.meta.history_max_size = size;
        write(&db, &file);
        let vault = CoreVault::open(path(&file), PASSWORD.into(), None).unwrap();
        assert_eq!(vault.history(id.to_string()).unwrap().len(), 3);
        vault.update_entry(id.to_string(), edit("v4")).unwrap();
        assert_eq!(
            vault
                .history(id.to_string())
                .unwrap()
                .iter()
                .map(|e| e.title.as_str())
                .collect::<Vec<_>>(),
            expected
        );
        vault.save().unwrap();
        let reopened = Database::parse(&fs::read(&file).unwrap(), key()).unwrap();
        assert_eq!(reopened.meta.history_max_items, items);
        assert_eq!(reopened.meta.history_max_size, size);
        assert_eq!(
            reopened
                .entry(id)
                .unwrap()
                .history
                .as_ref()
                .unwrap()
                .get_entries()
                .iter()
                .map(|e| e.get_title().unwrap())
                .collect::<Vec<_>>(),
            expected
        );
        assert_eq!(vault.entry(id.to_string()).unwrap().title, "v4");
    }
}

#[test]
fn imported_oldest_first_history_prunes_by_modification_time() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("oldest-first.kdbx");
    let mut db = Database::new();
    db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
    let id = db.root_mut().add_entry().id();
    let mut imported = keepass::db::History::default();
    // add_entry inserts at the front. Feed v2,v1,v0 to model an XML import
    // ordered oldest first, as other clients can produce.
    for n in (0..3).rev() {
        let mut version = db.entry(id).unwrap().clone();
        version.set_unprotected("Title", format!("v{n}"));
        version.times.last_modification =
            Some(keepass::db::Times::epoch() + chrono::Duration::seconds(n));
        imported.add_entry(version);
    }
    {
        let mut entry = db.entry_mut(id).unwrap();
        entry.set_unprotected("Title", "v3");
        entry.times.last_modification =
            Some(keepass::db::Times::epoch() + chrono::Duration::seconds(3));
        entry.history = Some(imported);
    }
    db.meta.history_max_items = Some(2);
    write(&db, &file);
    let vault = CoreVault::open(path(&file), PASSWORD.into(), None).unwrap();
    assert_eq!(vault.history(id.to_string()).unwrap()[0].title, "v0");
    vault.update_entry(id.to_string(), edit("v4")).unwrap();
    let titles: Vec<_> = vault
        .history(id.to_string())
        .unwrap()
        .into_iter()
        .map(|e| e.title)
        .collect();
    assert_eq!(titles, ["v3", "v2"]);
    vault.save().unwrap();
}

#[test]
fn history_size_counts_utf8_protected_fields_and_each_shared_binary_version() {
    // UTF-8 field keys/values: 17; attachment name/data: 70; custom data: 4;
    // tag: 6; Auto-Type window/sequence: 10. Each checkpoint is 107 bytes.
    for (items, size, expected) in [
        (Some(-1), Some(0), 0),
        (Some(-1), Some(106), 0),
        (Some(-1), Some(107), 1),
        (Some(-1), Some(214), 2),
        (Some(1), Some(214), 1),
        (Some(-1), Some(-1), 3),
        (None, None, 3),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("history-size.kdbx");
        let mut db = Database::new();
        db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
        db.meta.history_max_items = items;
        db.meta.history_max_size = size;
        let id = {
            let mut root = db.root_mut();
            let mut entry = root.add_entry();
            entry.set_unprotected("Title", "é");
            entry.set_protected("Secret", "🔐");
            entry.add_attachment("binary", Value::protected(vec![42; 64]));
            entry.tags = vec!["标签".into()];
            entry.custom_data.insert(
                "cd".into(),
                CustomDataItem {
                    value: Some(CustomDataValue::String("é".into())),
                    last_modification_time: None,
                },
            );
            entry.autotype = Some(AutoType {
                associations: vec![AutoTypeAssociation {
                    window: "win".into(),
                    sequence: "{ENTER}".into(),
                }],
                ..AutoType::default()
            });
            entry.id()
        };
        write(&db, &file);
        let vault = CoreVault::open(path(&file), PASSWORD.into(), None).unwrap();
        for _ in 0..3 {
            vault
                .move_entry(id.to_string(), db.root().id().to_string())
                .unwrap();
        }
        assert_eq!(
            vault.history(id.to_string()).unwrap().len(),
            expected,
            "limits {items:?}/{size:?}"
        );
        vault.save().unwrap();
        let reopened = Database::parse(&fs::read(&file).unwrap(), key()).unwrap();
        assert_eq!(reopened.num_attachments(), 1);
        let entry = reopened.entry(id).unwrap();
        assert_eq!(
            entry.attachment_by_name("binary").unwrap().data.get(),
            &vec![42; 64]
        );
        assert_eq!(
            entry.history.as_ref().unwrap().get_entries().len(),
            expected
        );
        assert_eq!(
            entry
                .attachment_by_name("binary")
                .unwrap()
                .entries(true)
                .count(),
            expected + 1
        );
        assert_reverse_ownership(&reopened);
    }
}

#[test]
fn history_size_counts_serialized_base64_custom_data() {
    // Title key/value contribute six bytes and the custom-data key one.
    // Cover both padding lengths, an unpadded encoding and a larger payload.
    for (decoded, encoded) in [(1, 4), (2, 4), (3, 4), (300, 400)] {
        let checkpoint_size = 7 + encoded;
        for (limit, expected) in [(checkpoint_size - 1, 0), (checkpoint_size, 1)] {
            let dir = tempfile::tempdir().unwrap();
            let file = dir.path().join("base64-history.kdbx");
            let mut db = Database::new();
            db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
            db.meta.history_max_items = Some(-1);
            db.meta.history_max_size = Some(limit);
            let id = {
                let mut root = db.root_mut();
                let mut entry = root.add_entry();
                entry.set_unprotected("Title", "t");
                entry.custom_data.insert(
                    "x".into(),
                    CustomDataItem {
                        value: Some(CustomDataValue::Binary(vec![0; decoded])),
                        last_modification_time: None,
                    },
                );
                entry.id()
            };
            write(&db, &file);
            let vault = CoreVault::open(path(&file), PASSWORD.into(), None).unwrap();
            vault
                .move_entry(id.to_string(), db.root().id().to_string())
                .unwrap();
            assert_eq!(
                vault.history(id.to_string()).unwrap().len(),
                expected,
                "decoded length {decoded}, encoded length {encoded}, limit {limit}"
            );
            vault.save().unwrap();
            let reopened = Database::parse(&fs::read(&file).unwrap(), key()).unwrap();
            let entry = reopened.entry(id).unwrap();
            assert_eq!(
                entry.history.as_ref().unwrap().get_entries().len(),
                expected
            );
            assert_eq!(
                entry.custom_data["x"].value,
                Some(CustomDataValue::Binary(vec![0; decoded]))
            );
        }
    }
}

fn shared_fixture() -> Database {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../KeeLockerTests/Fixtures/review-attachments.kdbx");
    let mut db = Database::parse(&fs::read(fixture).unwrap(), key()).unwrap();
    db.config.version = DatabaseVersion::KDB4(1);
    db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
    db.meta.history_max_items = Some(-1);
    db.meta.history_max_size = Some(-1);
    db
}

fn id(db: &Database, title: &str) -> EntryId {
    db.iter_all_entries()
        .find(|e| e.get_title() == Some(title))
        .unwrap()
        .id()
}

// Compare the actual reverse owners to all current/history forward references.
// Reading each owner also catches stale history indices that would panic.
fn assert_reverse_ownership(db: &Database) {
    let describe = |e: keepass::db::EntryRef<'_>| {
        (
            e.id().to_string(),
            e.get_title().unwrap_or_default().to_owned(),
            e.attachments().map(|a| a.id()).collect::<Vec<_>>(),
            e.custom_icon().map(|i| i.id()),
        )
    };
    let mut versions = Vec::new();
    for e in db.iter_all_entries() {
        for i in 0..e.history.as_ref().map_or(0, |h| h.get_entries().len()) {
            versions.push(describe(e.historical(i).unwrap()));
        }
        versions.push(describe(e));
    }
    for attachment in db.iter_all_attachments() {
        let mut forward: Vec<_> = versions
            .iter()
            .filter(|e| e.2.contains(&attachment.id()))
            .map(|e| (e.0.clone(), e.1.clone()))
            .collect();
        let mut reverse: Vec<_> = attachment
            .entries(true)
            .map(|e| {
                (
                    e.id().to_string(),
                    e.get_title().unwrap_or_default().to_owned(),
                )
            })
            .collect();
        forward.sort();
        reverse.sort();
        assert_eq!(reverse, forward);
    }
    for icon in db.iter_all_custom_icons() {
        let mut forward: Vec<_> = versions
            .iter()
            .filter(|e| e.3 == Some(icon.id()))
            .map(|e| (e.0.clone(), e.1.clone()))
            .collect();
        let mut reverse: Vec<_> = icon
            .entries(true)
            .map(|e| {
                (
                    e.id().to_string(),
                    e.get_title().unwrap_or_default().to_owned(),
                )
            })
            .collect();
        forward.sort();
        reverse.sort();
        assert_eq!(reverse, forward);
    }
}

#[test]
fn pruning_releases_history_only_assets_and_preserves_shared_current_owners() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("shared-history.kdbx");
    let mut db = shared_fixture();
    let a = id(&db, "A");
    let b = id(&db, "B");
    let orphan_icon = db
        .entry_mut(a)
        .unwrap()
        .set_icon_custom_new(vec![1, 2, 3])
        .id();
    let shared_icon = db
        .entry_mut(b)
        .unwrap()
        .set_icon_custom_new(vec![4, 5, 6])
        .id();
    db.root_mut().set_icon_custom(shared_icon).unwrap();
    let orphan_binary = db
        .entry_mut(a)
        .unwrap()
        .add_attachment("orphan", Value::protected(vec![7; 32]))
        .id();
    {
        let mut entry = db.entry_mut(a).unwrap();
        entry.times.last_modification = Some(keepass::db::Times::now());
        drop(entry.track_changes());
        entry.remove_attachment_by_name("orphan");
        entry.set_icon_custom(shared_icon).unwrap();
    }
    let group_icon = {
        let mut entry = db.entry_mut(a).unwrap();
        drop(entry.track_changes());
        entry.set_icon_custom_new(vec![8, 9, 10]).id()
    };
    db.root_mut()
        .add_group()
        .set_icon_custom(group_icon)
        .unwrap();
    {
        let mut entry = db.entry_mut(a).unwrap();
        drop(entry.track_changes());
        entry.set_icon_custom(shared_icon).unwrap();
    }
    assert!(db.attachment(orphan_binary).is_some());
    db.meta.history_max_items = Some(1);
    write(&db, &file);
    let vault = CoreVault::open(path(&file), PASSWORD.into(), None).unwrap();
    vault.update_entry(a.to_string(), edit("A edited")).unwrap();
    vault.save().unwrap();
    let reopened = Database::parse(&fs::read(&file).unwrap(), key()).unwrap();
    assert_eq!(reopened.num_attachments(), 2);
    assert!(reopened.custom_icon(orphan_icon).is_none());
    assert_eq!(reopened.num_custom_icons(), 2);
    let group_only = reopened.custom_icon(group_icon).unwrap();
    assert_eq!(group_only.entries(true).count(), 0);
    assert_eq!(group_only.groups().count(), 1);
    let icon = reopened.custom_icon(shared_icon).unwrap();
    assert_eq!(icon.entries(true).count(), 3); // A current, A history, B current
    assert_eq!(icon.groups().count(), 1);
    let a = reopened.entry(a).unwrap();
    assert_eq!(a.attachment_by_name("a.bin").unwrap().data.get(), b"alpha");
    assert_eq!(
        a.historical(0)
            .unwrap()
            .attachment_by_name("b.bin")
            .unwrap()
            .data
            .get(),
        b"alpha"
    );
    assert_eq!(
        reopened
            .entry(b)
            .unwrap()
            .attachment_by_name("shared.bin")
            .unwrap()
            .data
            .get(),
        b"alpha"
    );
    assert_eq!(
        reopened
            .entry(b)
            .unwrap()
            .attachment_by_name("beta.bin")
            .unwrap()
            .data
            .get(),
        b"beta"
    );
    assert_reverse_ownership(&reopened);
}

#[test]
fn disabled_history_preserves_shared_names_during_attachment_replace_and_delete() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("disabled-history.kdbx");
    let mut db = shared_fixture();
    let a = id(&db, "A");
    let b = id(&db, "B");
    db.meta.history_max_items = Some(0);
    write(&db, &file);
    let vault = CoreVault::open(path(&file), PASSWORD.into(), None).unwrap();
    vault
        .put_attachment(a.to_string(), "a.bin".into(), b"replacement".to_vec())
        .unwrap();
    assert!(vault.history(a.to_string()).unwrap().is_empty());
    assert_eq!(
        vault.attachment(a.to_string(), "b.bin".into()).unwrap(),
        b"alpha"
    );
    assert_eq!(
        vault
            .attachment(b.to_string(), "shared.bin".into())
            .unwrap(),
        b"alpha"
    );
    vault
        .delete_attachment(a.to_string(), "b.bin".into())
        .unwrap();
    vault
        .delete_attachment(a.to_string(), "a.bin".into())
        .unwrap();
    vault.save().unwrap();
    let reopened = Database::parse(&fs::read(&file).unwrap(), key()).unwrap();
    assert_eq!(reopened.num_attachments(), 2); // Only B's alpha and beta remain.
    assert_eq!(reopened.entry(a).unwrap().attachments().count(), 0);
    assert_eq!(
        reopened
            .entry(b)
            .unwrap()
            .attachment_by_name("shared.bin")
            .unwrap()
            .data
            .get(),
        b"alpha"
    );
    assert_reverse_ownership(&reopened);
}

#[test]
#[ignore = "requires KeePassXC CLI"]
fn pruned_history_and_shared_attachments_reopen_in_keepassxc() {
    use std::{
        io::Write,
        process::{Command, Stdio},
    };

    fn xc(args: &[&str]) -> Vec<u8> {
        let cli = std::env::var("KEEPASSXC_CLI")
            .unwrap_or_else(|_| "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli".into());
        let mut command = Command::new(cli)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("KeePassXC CLI required");
        writeln!(command.stdin.take().unwrap(), "{PASSWORD}").unwrap();
        let output = command.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "KeePassXC {} failed; output withheld",
            args[0]
        );
        output.stdout
    }

    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("interop.kdbx");
    let mut db = shared_fixture();
    let a = id(&db, "A");
    db.meta.history_max_items = Some(1);
    write(&db, &file);
    let vault = CoreVault::open(path(&file), PASSWORD.into(), None).unwrap();
    vault
        .put_attachment(a.to_string(), "a.bin".into(), b"replacement".to_vec())
        .unwrap();
    vault.update_entry(a.to_string(), edit("A edited")).unwrap();
    vault.save().unwrap();
    let file = path(&file);
    let xml = String::from_utf8(xc(&["export", "-q", &file])).unwrap();
    let document = roxmltree::Document::parse(&xml).unwrap();
    let edited = document
        .descendants()
        .find(|node| {
            node.has_tag_name("Entry")
                && node.children().any(|field| {
                    field.has_tag_name("String")
                        && field
                            .children()
                            .any(|key| key.has_tag_name("Key") && key.text() == Some("Title"))
                        && field.children().any(|value| {
                            value.has_tag_name("Value") && value.text() == Some("A edited")
                        })
                })
        })
        .unwrap();
    let history = edited
        .children()
        .find(|node| node.has_tag_name("History"))
        .unwrap();
    assert_eq!(
        history
            .children()
            .filter(|node| node.has_tag_name("Entry"))
            .count(),
        1
    );
    for (entry, name, expected) in [
        ("A edited", "a.bin", &b"replacement"[..]),
        ("A edited", "b.bin", &b"alpha"[..]),
        ("B", "shared.bin", &b"alpha"[..]),
        ("B", "beta.bin", &b"beta"[..]),
    ] {
        let exported = dir.path().join("exported.bin");
        xc(&[
            "attachment-export",
            "-q",
            &file,
            entry,
            name,
            &path(&exported),
        ]);
        assert_eq!(fs::read(&exported).unwrap(), expected);
        fs::remove_file(exported).unwrap();
    }
}
