use keelocker_core::CoreVault;
use keepass::{config::KdfConfig, db::Value, Database, DatabaseKey};
use std::{fs, path::Path};
const PASSWORD: &str = "fixture-password";
fn key() -> DatabaseKey {
    DatabaseKey::new().with_password(PASSWORD)
}
fn path(p: &Path) -> String {
    p.to_string_lossy().into()
}
fn source(p: &Path) -> std::sync::Arc<CoreVault> {
    fs::copy(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../KeeLockerTests/Fixtures/review-attachments.kdbx"),
        p,
    )
    .unwrap();
    CoreVault::open(path(p), PASSWORD.into(), None).unwrap()
}
fn id(v: &CoreVault, title: &str) -> String {
    v.snapshot()
        .unwrap()
        .entries
        .into_iter()
        .find(|e| e.title == title)
        .unwrap()
        .id
}

#[test]
fn imported_kdbx3_retains_distinct_binaries_and_shared_names() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("shared.kdbx");
    let v = source(&p);
    let a = id(&v, "A");
    let b = id(&v, "B");
    assert_eq!(v.attachment(a.clone(), "a.bin".into()).unwrap(), b"alpha");
    assert_eq!(v.attachment(a.clone(), "b.bin".into()).unwrap(), b"alpha");
    assert_eq!(v.attachment(b.clone(), "beta.bin".into()).unwrap(), b"beta");
    v.save().unwrap();
    v.lock();
    let reopened = CoreVault::open(path(&p), PASSWORD.into(), None).unwrap();
    assert_eq!(reopened.attachment(a, "b.bin".into()).unwrap(), b"alpha");
    assert_eq!(reopened.attachment(b, "beta.bin".into()).unwrap(), b"beta");
}

#[test]
fn replacing_one_shared_name_preserves_other_names_entries_and_history() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("shared.kdbx");
    let v = source(&p);
    let a = id(&v, "A");
    let b = id(&v, "B");
    v.put_attachment(a.clone(), "a.bin".into(), b"replacement".to_vec())
        .unwrap();
    assert_eq!(v.attachment(a.clone(), "b.bin".into()).unwrap(), b"alpha");
    assert_eq!(
        v.attachment(b.clone(), "shared.bin".into()).unwrap(),
        b"alpha"
    );
    v.save().unwrap();
    let db = Database::parse(&fs::read(&p).unwrap(), key()).unwrap();
    let a = db
        .iter_all_entries()
        .find(|e| e.get_title() == Some("A"))
        .unwrap();
    assert_eq!(
        a.attachment_by_name("a.bin").unwrap().data.get(),
        b"replacement"
    );
    assert_eq!(
        a.historical(1)
            .unwrap()
            .attachment_by_name("old.bin")
            .unwrap()
            .data
            .get(),
        b"beta"
    );
    assert_eq!(
        a.historical(0)
            .unwrap()
            .attachment_by_name("a.bin")
            .unwrap()
            .data
            .get(),
        b"alpha"
    );
}

#[test]
fn deleting_entries_preserves_other_owners_and_cleans_all_historical_binaries() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("shared.kdbx");
    let v = source(&p);
    let a = id(&v, "A");
    let b = id(&v, "B");
    v.delete_entry(a).unwrap();
    assert_eq!(
        v.attachment(b.clone(), "shared.bin".into()).unwrap(),
        b"alpha"
    );
    assert_eq!(v.attachment(b.clone(), "beta.bin".into()).unwrap(), b"beta");
    v.save().unwrap();
    v.delete_entry(b).unwrap();
    v.save().unwrap();
    assert_eq!(
        Database::parse(&fs::read(&p).unwrap(), key())
            .unwrap()
            .num_attachments(),
        0
    );
}

#[test]
fn deleting_entry_with_two_names_for_one_binary_does_not_panic() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("shared.kdbx");
    let v = source(&p);
    let a = id(&v, "A");
    let b = id(&v, "B");
    v.delete_entry(b).unwrap();
    v.delete_entry(a).unwrap();
    v.save().unwrap();
    assert!(v.snapshot().unwrap().entries.is_empty());
}

#[test]
fn sparse_binary_ids_remain_readable_after_delete_and_save() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("sparse.kdbx");
    let mut db = Database::new();
    db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
    let first = {
        let mut root = db.root_mut();
        let mut entry = root.add_entry();
        entry.add_attachment("first", Value::unprotected(b"first".to_vec()));
        entry.id()
    };
    let second = {
        let mut root = db.root_mut();
        let mut entry = root.add_entry();
        entry.add_attachment("second", Value::unprotected(b"second".to_vec()));
        entry.id()
    };
    db.save(&mut fs::File::create(&p).unwrap(), key()).unwrap();
    let v = CoreVault::open(path(&p), PASSWORD.into(), None).unwrap();
    v.delete_entry(first.to_string()).unwrap();
    v.save().unwrap();
    let reopened = CoreVault::open(path(&p), PASSWORD.into(), None).unwrap();
    assert_eq!(
        reopened
            .attachment(second.to_string(), "second".into())
            .unwrap(),
        b"second"
    );
}
