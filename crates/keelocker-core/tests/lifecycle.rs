use keelocker_core::{CoreCustomField, CoreEntryEdit, CoreError, CoreVault};
use keepass::{
    config::{DatabaseVersion, KdfConfig, OuterCipherConfig},
    Database, DatabaseKey,
};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

const PASSWORD: &str = "fixture-password";

#[test]
#[ignore = "manual release-mode save timing with a realistic Argon2 cost"]
fn save_timing() {
    use std::time::Instant;
    let mut db = Database::new();
    let KdfConfig::Argon2 { version, .. } = db.config.kdf_config else {
        panic!()
    };
    db.config.kdf_config = KdfConfig::Argon2id {
        iterations: 10,
        memory: 64 * 1024 * 1024,
        parallelism: 2,
        version,
    };
    db.root_mut()
        .add_entry()
        .set_unprotected("Title", "Timing fixture");
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("timing.kdbx");
    for _ in 0..3 {
        let start = Instant::now();
        let mut bytes = Vec::new();
        db.save(&mut bytes, key()).unwrap();
        let serialize = start.elapsed();
        let start = Instant::now();
        Database::parse(&bytes, key()).unwrap();
        let reopen = start.elapsed();
        fs::write(&path, bytes).unwrap();
        let vault = CoreVault::open(path.to_string_lossy().into(), PASSWORD.into(), None).unwrap();
        let start = Instant::now();
        vault.save().unwrap();
        eprintln!("save timing: serialize={serialize:?}, independent reopen={reopen:?}, complete save={:?}", start.elapsed());
    }
}

fn key() -> DatabaseKey {
    DatabaseKey::new().with_password(PASSWORD)
}

#[test]
fn session_key_material_reopens_and_saves_without_original_credentials() {
    for id in [false, true] {
        for chacha in [false, true] {
            for minor in [0, 1] {
                for keyfile in [false, true] {
                    let dir = tempfile::tempdir().unwrap();
                    let p = fixture(dir.path(), id, chacha, minor, keyfile);
                    let key_path = dir.path().join("test.key");
                    let v = CoreVault::open(
                        path(&p),
                        PASSWORD.into(),
                        keyfile.then(|| path(&key_path)),
                    )
                    .unwrap();
                    let before = v.snapshot().unwrap();
                    let material = v.key_material().unwrap();
                    assert_eq!(material.len(), if keyfile { 68 } else { 36 });
                    v.lock();
                    assert_eq!(v.key_material(), Err(CoreError::InvalidOperation));
                    // The cached normalized key includes the key-file component for this session.
                    let original_key = if keyfile {
                        let k = key()
                            .with_keyfile(&mut fs::File::open(&key_path).unwrap())
                            .unwrap();
                        fs::remove_file(&key_path).unwrap();
                        k
                    } else {
                        key()
                    };
                    let quick = CoreVault::open_with_key_material(path(&p), material).unwrap();
                    let restored = quick.snapshot().unwrap();
                    assert_eq!(restored.info.root_id, before.info.root_id);
                    assert_eq!(restored.entries.len(), before.entries.len());
                    for original in &before.entries {
                        assert!(restored
                            .entries
                            .iter()
                            .any(|e| e.id == original.id && e.title == original.title));
                    }
                    let entry = quick
                        .create_entry(before.info.root_id, edit("Quick Unlock edit"))
                        .unwrap();
                    quick.save().unwrap();
                    let db = Database::parse(&fs::read(&p).unwrap(), original_key).unwrap();
                    assert_eq!(
                        db.entry(keepass::db::EntryId::from_uuid(entry.parse().unwrap()))
                            .unwrap()
                            .get_title(),
                        Some("Quick Unlock edit")
                    );
                    quick.lock();
                }
            }
        }
    }
}

#[test]
fn session_key_material_rejects_malformed_and_wrong_keys() {
    let dir = tempfile::tempdir().unwrap();
    let p = fixture(dir.path(), true, false, 1, false);
    for material in [
        vec![],
        vec![0; 36],
        b"KLQ1".to_vec(),
        [b"KLQ1".as_slice(), &[1; 33]].concat(),
    ] {
        assert!(matches!(
            CoreVault::open_with_key_material(path(&p), material),
            Err(CoreError::InvalidOperation)
        ));
    }
    let v = CoreVault::open(path(&p), PASSWORD.into(), None).unwrap();
    let mut material = v.key_material().unwrap();
    material[4] ^= 1;
    assert!(matches!(
        CoreVault::open_with_key_material(path(&p), material),
        Err(CoreError::WrongCredentials)
    ));
}

#[test]
fn session_key_material_supports_legacy_aes_kdf_and_keyfile_only() {
    let dir = tempfile::tempdir().unwrap();
    let legacy = dir.path().join("legacy.kdbx");
    fs::copy(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../KeeLockerTests/Fixtures/interop.kdbx"),
        &legacy,
    )
    .unwrap();
    let v = CoreVault::open(path(&legacy), "fixture-password".into(), None).unwrap();
    let material = v.key_material().unwrap();
    v.lock();
    let quick = CoreVault::open_with_key_material(path(&legacy), material).unwrap();
    quick.save().unwrap();
    let db = Database::parse(
        &fs::read(&legacy).unwrap(),
        DatabaseKey::new().with_password("fixture-password"),
    )
    .unwrap();
    assert!(matches!(db.config.kdf_config, KdfConfig::Aes { .. }));
    assert!(!quick.snapshot().unwrap().entries.is_empty());
    quick.lock();

    let p = fixture(dir.path(), true, false, 1, false);
    let mut db = Database::parse(&fs::read(&p).unwrap(), key()).unwrap();
    db.config.kdf_config = KdfConfig::Aes { rounds: 10_000 };
    let key_path = dir.path().join("only.key");
    fs::write(&key_path, [17u8; 32]).unwrap();
    let only_key = DatabaseKey::new()
        .with_keyfile(&mut &[17u8; 32][..])
        .unwrap();
    db.save(&mut fs::File::create(&p).unwrap(), only_key.clone())
        .unwrap();
    let v = CoreVault::open(path(&p), String::new(), Some(path(&key_path))).unwrap();
    let material = v.key_material().unwrap();
    assert_eq!(material.len(), 36);
    v.lock();
    fs::remove_file(key_path).unwrap();
    let quick = CoreVault::open_with_key_material(path(&p), material).unwrap();
    let root = quick.snapshot().unwrap().info.root_id;
    let entry = quick
        .create_entry(root, edit("Key-file-only Quick Unlock"))
        .unwrap();
    quick.save().unwrap();
    let db = Database::parse(&fs::read(&p).unwrap(), only_key).unwrap();
    assert_eq!(
        db.entry(keepass::db::EntryId::from_uuid(entry.parse().unwrap()))
            .unwrap()
            .get_title(),
        Some("Key-file-only Quick Unlock")
    );
    quick.lock();
}

#[test]
#[ignore = "manual release-mode performance profile"]
fn operation_timing() {
    use std::time::Instant;
    for (name, count, attachment_bytes, iterations, memory) in [
        ("argon2", 1, 0, 10, 64 * 1024 * 1024),
        ("aes-kdf", 1, 0, 0, 0),
        ("attachment-8MiB", 1, 8 * 1024 * 1024, 2, 1024 * 1024),
        ("entries-5000", 5000, 0, 2, 1024 * 1024),
    ] {
        let mut db = Database::new();
        let KdfConfig::Argon2 { version, .. } = db.config.kdf_config else {
            panic!()
        };
        db.config.kdf_config = if name == "aes-kdf" {
            KdfConfig::Aes { rounds: 6_000_000 }
        } else {
            KdfConfig::Argon2id {
                iterations,
                memory,
                parallelism: 2,
                version,
            }
        };
        for i in 0..count {
            let mut root = db.root_mut();
            let mut entry = root.add_entry();
            entry.set_unprotected("Title", format!("Synthetic entry {i}"));
            entry.set_protected("Password", "synthetic-password");
            if i == 0 && attachment_bytes > 0 {
                entry.add_attachment(
                    "synthetic.bin",
                    keepass::db::Value::unprotected(vec![42; attachment_bytes]),
                );
            }
        }
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("timing.kdbx");
        db.save(&mut fs::File::create(&file).unwrap(), key())
            .unwrap();
        for _ in 0..3 {
            let start = Instant::now();
            let vault = CoreVault::open(path(&file), PASSWORD.into(), None).unwrap();
            let open = start.elapsed();
            let start = Instant::now();
            let snapshot = vault.snapshot().unwrap();
            let snapshot_time = start.elapsed();
            vault
                .update_entry(snapshot.entries[0].id.clone(), edit("Changed"))
                .unwrap();
            let start = Instant::now();
            vault.save().unwrap();
            eprintln!(
                "{name}: open={open:?}, snapshot={snapshot_time:?}, save={:?}",
                start.elapsed()
            );
            std::thread::sleep(std::time::Duration::from_millis(400));
            vault
                .update_entry(snapshot.entries[0].id.clone(), edit("Changed again"))
                .unwrap();
            let start = Instant::now();
            vault.save().unwrap();
            eprintln!("{name}: save after editing pause={:?}", start.elapsed());
        }
    }
}

#[test]
fn validated_save_matches_independent_reopen_with_fresh_encryption() {
    let dir = tempfile::tempdir().unwrap();
    for argon_id in [false, true] {
        for chacha in [false, true] {
            for keyed in [false, true] {
                let source = fixture(dir.path(), argon_id, chacha, 1, keyed);
                let key = if keyed {
                    key().with_keyfile(&mut &[42u8; 32][..]).unwrap()
                } else {
                    key()
                };
                let db = Database::parse(&fs::read(source).unwrap(), key.clone()).unwrap();
                let mut previous = Vec::new();
                for _ in 0..2 {
                    let mut bytes = Vec::new();
                    let validated = db.save_and_reopen(&mut bytes, key.clone()).unwrap();
                    let independent = Database::parse(&bytes, key.clone()).unwrap();
                    let decrypted = Database::decrypt(&bytes, key.clone()).unwrap();
                    assert_eq!(
                        decrypted.xml(),
                        Database::get_xml(&mut bytes.as_slice(), key.clone()).unwrap()
                    );
                    assert_eq!(decrypted.parse().unwrap(), independent);
                    assert_eq!(validated, independent);
                    assert_eq!(validated.config, db.config);
                    assert_ne!(bytes, previous);
                    previous = bytes;
                }
            }
        }
    }
}

#[test]
fn prepared_save_rejects_changed_kdf_and_reopens_with_original_credentials() {
    let dir = tempfile::tempdir().unwrap();
    let source = fixture(dir.path(), true, true, 1, true);
    let key = key().with_keyfile(&mut &[42u8; 32][..]).unwrap();
    let mut db = Database::parse(&fs::read(source).unwrap(), key.clone()).unwrap();
    let prepared =
        keepass::db::PreparedKdbx4Save::new(db.config.kdf_config.clone(), key.clone()).unwrap();
    let original_config = db.config.clone();
    db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
    let mut bytes = Vec::new();
    assert!(prepared.save_and_reopen(&db, &mut bytes).is_err());
    assert!(bytes.is_empty());
    db.config = original_config;
    let mut previous = Vec::new();
    for _ in 0..2 {
        let prepared =
            keepass::db::PreparedKdbx4Save::new(db.config.kdf_config.clone(), key.clone()).unwrap();
        let mut bytes = Vec::new();
        let validated = prepared.save_and_reopen(&db, &mut bytes).unwrap();
        assert_eq!(validated, Database::parse(&bytes, key.clone()).unwrap());
        assert!(Database::parse(&bytes, DatabaseKey::new().with_password("wrong")).is_err());
        assert_ne!(bytes, previous);
        previous = bytes;
    }
}

#[test]
fn keyfile_only_and_standard_totp_defaults() {
    let dir = tempfile::tempdir().unwrap();
    let p = fixture(dir.path(), true, false, 1, false);
    let mut db = Database::parse(&fs::read(&p).unwrap(), key()).unwrap();
    let mut root = db.root_mut();
    let mut e = root.add_entry();
    e.set_protected("otp", "otpauth://totp/Test?secret=JBSWY3DPEHPK3PXP");
    let id = e.id().to_string();
    let k = dir.path().join("only.key");
    fs::write(&k, [17u8; 32]).unwrap();
    let key = DatabaseKey::new()
        .with_keyfile(&mut &[17u8; 32][..])
        .unwrap();
    db.save(&mut fs::File::create(&p).unwrap(), key).unwrap();
    let v = CoreVault::open(path(&p), String::new(), Some(path(&k))).unwrap();
    assert_eq!(v.entry(id.clone()).unwrap().otp.unwrap().code.len(), 6);
    v.save().unwrap();
    let reopened = CoreVault::open(path(&p), String::new(), Some(path(&k))).unwrap();
    assert!(reopened.entry(id).unwrap().otp.is_some());
}
fn path(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}
fn edit(title: &str) -> CoreEntryEdit {
    CoreEntryEdit {
        title: title.into(),
        username: "fixture-user".into(),
        password: "secret 🔐".into(),
        url: "https://example.test".into(),
        notes: "line 1\nзаметка".into(),
        tags: vec!["work".into(), "тест".into()],
        custom_fields: vec![
            CoreCustomField {
                name: "Recovery".into(),
                value: "protected-test".into(),
                protected: true,
            },
            CoreCustomField {
                name: "KP2A_URL".into(),
                value: "https://second.example.test".into(),
                protected: false,
            },
        ],
    }
}
fn fixture(dir: &Path, id: bool, chacha: bool, minor: u16, keyfile: bool) -> PathBuf {
    let mut db = Database::new();
    db.meta.database_name = Some("Integration Vault".into());
    db.root_mut().name = "Different root".into();
    db.config.version = DatabaseVersion::KDB4(1);
    if minor == 1 {
        db.root_mut().tags = vec!["requires-4.1".into()];
    }
    db.config.outer_cipher_config = if chacha {
        OuterCipherConfig::ChaCha20
    } else {
        OuterCipherConfig::AES256
    };
    let KdfConfig::Argon2 { version, .. } = db.config.kdf_config else {
        panic!("default KDF changed")
    };
    db.config.kdf_config = if id {
        KdfConfig::Argon2id {
            iterations: 2,
            memory: 1024 * 1024,
            parallelism: 1,
            version,
        }
    } else {
        KdfConfig::Argon2 {
            iterations: 2,
            memory: 1024 * 1024,
            parallelism: 1,
            version,
        }
    };
    let p = dir.join("source.kdbx");
    let mut k = key();
    if keyfile {
        fs::write(dir.join("test.key"), [42u8; 32]).unwrap();
        k = k.with_keyfile(&mut &[42u8; 32][..]).unwrap();
    }
    db.save(&mut fs::File::create(&p).unwrap(), k).unwrap();
    p
}

#[test]
fn lifecycle_and_atomic_conflict() {
    let dir = tempfile::tempdir().unwrap();
    let p = fixture(dir.path(), true, false, 1, false);
    let v = CoreVault::open(path(&p), PASSWORD.into(), None).unwrap();
    let root = v.snapshot().unwrap().info.root_id;
    let g = v.create_group(root.clone(), "Nested".into()).unwrap();
    let child = v.create_group(g.clone(), "Child".into()).unwrap();
    assert_eq!(
        v.move_group(g.clone(), child.clone()),
        Err(CoreError::InvalidOperation)
    );
    let id = v.create_entry(child.clone(), edit("Before")).unwrap();
    let before = v.entry(id.clone()).unwrap();
    v.put_attachment(id.clone(), "test.bin".into(), vec![0, 1, 2, 255])
        .unwrap();
    v.update_entry(id.clone(), edit("After")).unwrap();
    assert!(v
        .history(id.clone())
        .unwrap()
        .iter()
        .any(|e| e.title == "Before"));
    v.move_entry(id.clone(), g.clone()).unwrap();
    v.rename_group(g.clone(), "Renamed".into()).unwrap();
    v.delete_group(child).unwrap();
    v.save().unwrap();
    assert!(dir.path().join("source.kdbx.bak").exists());
    let reopened = CoreVault::open(path(&p), PASSWORD.into(), None).unwrap();
    let entry = reopened.entry(id.clone()).unwrap();
    assert_eq!(entry.title, "After");
    assert_eq!(entry.created_at, before.created_at);
    assert_eq!(entry.password, "secret 🔐");
    assert_eq!(
        reopened.attachment(id.clone(), "test.bin".into()).unwrap(),
        [0, 1, 2, 255]
    );
    assert!(reopened
        .snapshot()
        .unwrap()
        .entries
        .iter()
        .all(|e| e.password.is_empty()));
    fs::write(&p, b"externally replaced").unwrap();
    assert_eq!(v.save(), Err(CoreError::Conflict));
    assert_eq!(fs::read(&p).unwrap(), b"externally replaced");
    v.lock();
    assert!(matches!(v.snapshot(), Err(CoreError::InvalidOperation)));
    assert_eq!(v.save(), Err(CoreError::InvalidOperation));
    assert_eq!(fs::read(&p).unwrap(), b"externally replaced");
}

#[test]
fn external_reload_retains_credentials_and_accepts_subsequent_saves() {
    for keyed in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let p = fixture(dir.path(), true, false, 1, keyed);
        let keyfile = keyed.then(|| path(&dir.path().join("test.key")));
        let v = CoreVault::open(path(&p), PASSWORD.into(), keyfile.clone()).unwrap();
        let external = CoreVault::open(path(&p), PASSWORD.into(), keyfile).unwrap();
        assert!(!v.reload_if_changed().unwrap());
        let root = external.snapshot().unwrap().info.root_id;
        let group = external
            .create_group(root, "External group".into())
            .unwrap();
        let id = external
            .create_entry(group.clone(), edit("External entry"))
            .unwrap();
        external
            .put_attachment(id.clone(), "external.bin".into(), vec![1, 2, 3])
            .unwrap();
        external.save().unwrap();
        if keyed {
            // Refresh uses the already loaded composite key, not a keyfile path.
            fs::remove_file(dir.path().join("test.key")).unwrap();
        }
        assert!(v.reload_if_changed().unwrap());
        assert!(!v.reload_if_changed().unwrap());
        let entry = v.entry(id.clone()).unwrap();
        assert_eq!(entry.title, "External entry");
        assert_eq!(entry.password, "secret 🔐");
        assert_eq!(entry.group_id, group);
        assert_eq!(
            v.attachment(id.clone(), "external.bin".into()).unwrap(),
            [1, 2, 3]
        );
        assert!(entry
            .custom_fields
            .iter()
            .any(|f| f.protected && f.value == "protected-test"));
        v.update_entry(id.clone(), edit("Local edit after refresh"))
            .unwrap();
        // An unchanged file must never erase dirty in-memory work.
        assert!(!v.reload_if_changed().unwrap());
        assert!(v.snapshot().unwrap().info.dirty);
        v.save().unwrap();
        assert!(!v.reload_if_changed().unwrap());
        let key = if keyed {
            key().with_keyfile(&mut &[42u8; 32][..]).unwrap()
        } else {
            key()
        };
        let reopened = Database::parse(&fs::read(&p).unwrap(), key).unwrap();
        assert!(reopened
            .iter_all_entries()
            .any(|e| e.get_title() == Some("Local edit after refresh")));
        v.lock();
        assert_eq!(v.reload_if_changed(), Err(CoreError::InvalidOperation));
        assert_eq!(v.reload(), Err(CoreError::InvalidOperation));
    }
}

#[test]
fn external_reload_preserves_dirty_work_until_explicit_recovery() {
    let dir = tempfile::tempdir().unwrap();
    let p = fixture(dir.path(), true, false, 1, false);
    let v = CoreVault::open(path(&p), PASSWORD.into(), None).unwrap();
    let root = v.snapshot().unwrap().info.root_id;
    let id = v.create_entry(root, edit("Original")).unwrap();
    v.save().unwrap();
    let external = CoreVault::open(path(&p), PASSWORD.into(), None).unwrap();
    v.update_entry(id.clone(), edit("Unsaved local work"))
        .unwrap();
    external
        .update_entry(id.clone(), edit("Externally saved work"))
        .unwrap();
    external.save().unwrap();
    let external_bytes = fs::read(&p).unwrap();
    assert_eq!(v.save(), Err(CoreError::Conflict));
    assert_eq!(v.reload_if_changed(), Err(CoreError::Conflict));
    assert_eq!(v.entry(id.clone()).unwrap().title, "Unsaved local work");
    assert!(v.snapshot().unwrap().info.dirty);
    assert_eq!(fs::read(&p).unwrap(), external_bytes);

    fs::write(&p, b"temporarily invalid file").unwrap();
    assert_eq!(v.reload(), Err(CoreError::UnsupportedDatabase));
    assert_eq!(v.entry(id.clone()).unwrap().title, "Unsaved local work");
    assert!(v.snapshot().unwrap().info.dirty);
    fs::write(&p, external_bytes).unwrap();
    v.reload().unwrap();
    assert_eq!(v.entry(id.clone()).unwrap().title, "Externally saved work");
    assert!(!v.snapshot().unwrap().info.dirty);
    v.update_entry(id, edit("Recovered and saved")).unwrap();
    v.save().unwrap();
}

#[test]
fn external_reload_adopts_kdf_and_rejects_changed_credentials_without_losing_session() {
    let dir = tempfile::tempdir().unwrap();
    let p = fixture(dir.path(), true, false, 1, false);
    let v = CoreVault::open(path(&p), PASSWORD.into(), None).unwrap();
    let mut db = Database::parse(&fs::read(&p).unwrap(), key()).unwrap();
    db.config.kdf_config = KdfConfig::Aes { rounds: 10_000 };
    db.meta.database_name = Some("Externally renamed vault".into());
    db.save(&mut fs::File::create(&p).unwrap(), key()).unwrap();
    assert!(v.reload_if_changed().unwrap());
    assert_eq!(v.snapshot().unwrap().info.name, "Externally renamed vault");
    v.save().unwrap();
    let reopened = Database::parse(&fs::read(&p).unwrap(), key()).unwrap();
    assert_eq!(reopened.config.kdf_config, db.config.kdf_config);
    db.save(
        &mut fs::File::create(&p).unwrap(),
        DatabaseKey::new().with_password("new-password"),
    )
    .unwrap();
    let external_bytes = fs::read(&p).unwrap();
    assert_eq!(v.reload_if_changed(), Err(CoreError::WrongCredentials));
    assert_eq!(v.snapshot().unwrap().info.name, "Externally renamed vault");
    assert_eq!(v.save(), Err(CoreError::Conflict));
    assert_eq!(fs::read(&p).unwrap(), external_bytes);
}

#[test]
fn wrong_credentials_corruption_and_save_as_collision() {
    let dir = tempfile::tempdir().unwrap();
    let p = fixture(dir.path(), false, true, 0, true);
    assert!(matches!(
        CoreVault::open(path(&p), PASSWORD.into(), None),
        Err(CoreError::WrongCredentials)
    ));
    let v = CoreVault::open(
        path(&p),
        PASSWORD.into(),
        Some(path(&dir.path().join("test.key"))),
    )
    .unwrap();
    let copy = dir.path().join("copy.kdbx");
    v.save_as(path(&copy)).unwrap();
    let other = dir.path().join("existing.kdbx");
    fs::write(&other, b"keep").unwrap();
    assert_eq!(v.save_as(path(&other)), Err(CoreError::Conflict));
    assert_eq!(fs::read(other).unwrap(), b"keep");
    let mut damaged = fs::read(&copy).unwrap();
    let last = damaged.len() - 10;
    damaged[last] ^= 0x40;
    fs::write(&copy, damaged).unwrap();
    assert!(matches!(
        CoreVault::open(
            path(&copy),
            PASSWORD.into(),
            Some(path(&dir.path().join("test.key")))
        ),
        Err(CoreError::CorruptedDatabase)
    ));
}

fn xc(args: &[&str], input: &str) -> Vec<u8> {
    let cli = std::env::var("KEEPASSXC_CLI")
        .unwrap_or_else(|_| "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli".into());
    let mut c = Command::new(cli)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("KeePassXC CLI required for interoperability tests");
    c.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = c.wait_with_output().unwrap();
    assert!(
        out.status.success(),
        "KeePassXC command {} failed (output intentionally withheld)",
        args[0]
    );
    out.stdout
}

#[test]
#[ignore = "requires KeePassXC CLI; run cargo test -- --include-ignored"]
fn keepassxc_crypto_matrix_roundtrip() {
    for id in [false, true] {
        for chacha in [false, true] {
            for minor in [0, 1] {
                for keyfile in [false, true] {
                    let dir = tempfile::tempdir().unwrap();
                    let p = fixture(dir.path(), id, chacha, minor, keyfile);
                    let k = dir.path().join("test.key");
                    let mut args = vec!["add", "-q", "-u", "xc-user", "-p"];
                    let ks = path(&k);
                    if keyfile {
                        args.extend(["-k", &ks]);
                    }
                    let ps = path(&p);
                    args.extend([&ps, "XC created"]);
                    xc(&args, "fixture-password\nxc-password\n");
                    assert_eq!(
                        Database::get_version(&mut fs::File::open(&p).unwrap()).unwrap(),
                        DatabaseVersion::KDB4(minor)
                    );
                    if let Ok(destination) = std::env::var("KEELOCKER_MATRIX_OUTPUT") {
                        let name = format!(
                            "xc-4{minor}-{}-{}{}.kdbx",
                            if id { "argon2id" } else { "argon2d" },
                            if chacha { "chacha20" } else { "aes" },
                            if keyfile { "-key" } else { "" }
                        );
                        fs::create_dir_all(&destination).unwrap();
                        fs::copy(&p, Path::new(&destination).join(name)).unwrap();
                        if keyfile {
                            fs::copy(&k, Path::new(&destination).join("test.key")).unwrap();
                        }
                    }
                    let v = CoreVault::open(ps, PASSWORD.into(), keyfile.then_some(ks.clone()))
                        .unwrap();
                    let material = v.key_material().unwrap();
                    v.lock();
                    // KeePassXC independently verifies edits saved after a cached-key reopen.
                    let v = CoreVault::open_with_key_material(path(&p), material).unwrap();
                    let s = v.snapshot().unwrap();
                    let e = s.entries.iter().find(|e| e.title == "XC created").unwrap();
                    assert_eq!(v.entry(e.id.clone()).unwrap().password, "xc-password");
                    let g = v.create_group(s.info.root_id, "Nested".into()).unwrap();
                    let entry = v.create_entry(g, edit("Rust created")).unwrap();
                    v.put_attachment(entry.clone(), "test.bin".into(), vec![1, 2, 3])
                        .unwrap();
                    v.update_entry(entry.clone(), edit("Rust edited")).unwrap();
                    let saved = path(&dir.path().join("saved.kdbx"));
                    v.save_as(saved.clone()).unwrap();
                    let mut args = vec!["export", "-q"];
                    if keyfile {
                        args.extend(["-k", &ks]);
                    }
                    args.push(&saved);
                    let xml = String::from_utf8(xc(&args, "fixture-password\n")).unwrap();
                    for required in [
                        "Rust edited",
                        "protected-test",
                        "KP2A_URL",
                        "test.bin",
                        "<History>",
                        "заметка",
                        "тест",
                    ] {
                        assert!(xml.contains(required), "missing {required}");
                    }
                    let mut args = vec!["edit", "-q", "-u", "xc-modified"];
                    if keyfile {
                        args.extend(["-k", &ks]);
                    }
                    args.extend([&saved, "Nested/Rust edited"]);
                    xc(&args, "fixture-password\n");
                    let reopened =
                        CoreVault::open(saved, PASSWORD.into(), keyfile.then_some(ks)).unwrap();
                    assert_eq!(
                        reopened.entry(entry.clone()).unwrap().username,
                        "xc-modified"
                    );
                    assert_eq!(
                        reopened.attachment(entry, "test.bin".into()).unwrap(),
                        [1, 2, 3]
                    );
                }
            }
        }
    }
}

#[test]
#[ignore = "requires KeePassXC CLI"]
fn keepassxc_creates_fixture() {
    let dir = tempfile::tempdir().unwrap();
    let p = path(&dir.path().join("xc.kdbx"));
    xc(
        &["db-create", "-q", "-p", "-t", "100", &p],
        "fixture-password\nfixture-password\n",
    );
    // KeePassXC db-create defaults to KDBX 3.1/AES-KDF; save upgrades it to 4.1.
    let v = CoreVault::open(p.clone(), PASSWORD.into(), None).unwrap();
    v.save_as(path(&dir.path().join("copy.kdbx"))).unwrap();
    if let Ok(destination) = std::env::var("KEELOCKER_FIXTURE_OUTPUT") {
        fs::copy(p, destination).unwrap();
    }
}

#[test]
fn attachment_versions_survive_replace_and_delete() {
    let dir = tempfile::tempdir().unwrap();
    let p = fixture(dir.path(), true, false, 1, false);
    let v = CoreVault::open(path(&p), PASSWORD.into(), None).unwrap();
    let id = v
        .create_entry(
            v.snapshot().unwrap().info.root_id,
            edit("Attachment history"),
        )
        .unwrap();
    v.put_attachment(id.clone(), "a.bin".into(), vec![1, 2, 3])
        .unwrap();
    v.put_attachment(id.clone(), "a.bin".into(), vec![4, 5, 6])
        .unwrap();
    assert_eq!(v.attachment(id.clone(), "a.bin".into()).unwrap(), [4, 5, 6]);
    v.delete_attachment(id.clone(), "a.bin".into()).unwrap();
    v.save().unwrap();
    let db = Database::parse(&fs::read(&p).unwrap(), key()).unwrap();
    let e = db
        .iter_all_entries()
        .find(|e| e.id().to_string() == id)
        .unwrap();
    let mut historic_data = Vec::new();
    for i in 0..e.history.as_ref().unwrap().get_entries().len() {
        if let Some(a) = e.historical(i).unwrap().attachment_by_name("a.bin") {
            historic_data.push(a.data.get().clone());
        }
    }
    assert!(historic_data.contains(&vec![1, 2, 3]));
    assert!(historic_data.contains(&vec![4, 5, 6]));
    assert!(e.attachments_named().next().is_none());
}

#[test]
fn metadata_uuid_icons_timestamps_and_deletion_survive() {
    use keepass::db::{CustomDataItem, CustomDataValue};
    let dir = tempfile::tempdir().unwrap();
    let p = fixture(dir.path(), true, false, 1, false);
    let mut db = Database::parse(&fs::read(&p).unwrap(), key()).unwrap();
    let value = CustomDataItem {
        value: Some(CustomDataValue::String("plugin-value!".into())),
        last_modification_time: Some(keepass::db::Times::now()),
    };
    db.meta
        .custom_data
        .insert("unknown-plugin-key".into(), value.clone());
    db.config
        .public_custom_data
        .get_or_insert_default()
        .set("plugin-header", "header-value".to_string());
    db.root_mut()
        .custom_data
        .insert("unknown-group-key".into(), value.clone());
    let id = {
        let mut root = db.root_mut();
        let mut e = root.add_entry();
        e.set_unprotected("Title", "Metadata");
        e.custom_data
            .insert("unknown-entry-key".into(), value.clone());
        let id = e.id();
        e.set_icon_custom_new(vec![1, 2, 3]).name = Some("Custom icon".into());
        id
    };
    db.save(&mut fs::File::create(&p).unwrap(), key()).unwrap();
    let v = CoreVault::open(path(&p), PASSWORD.into(), None).unwrap();
    let before = v.entry(id.to_string()).unwrap();
    v.update_entry(id.to_string(), edit("Metadata edited"))
        .unwrap();
    v.save().unwrap();
    let reopened = Database::parse(&fs::read(&p).unwrap(), key()).unwrap();
    assert_eq!(reopened.meta.custom_data, db.meta.custom_data);
    assert_eq!(
        reopened.config.public_custom_data,
        db.config.public_custom_data
    );
    assert_eq!(reopened.root().custom_data, db.root().custom_data);
    assert_eq!(
        reopened.entry(id).unwrap().custom_data,
        db.entry(id).unwrap().custom_data
    );
    assert_eq!(
        reopened.entry(id).unwrap().custom_icon().unwrap().data,
        [1, 2, 3]
    );
    assert_eq!(
        v.entry(id.to_string()).unwrap().created_at,
        before.created_at
    );
    v.delete_entry(id.to_string()).unwrap();
    v.save().unwrap();
    let reopened = Database::parse(&fs::read(&p).unwrap(), key()).unwrap();
    assert!(reopened.entry(id).is_none());
    assert!(reopened.deleted_objects.contains_key(&id.uuid()));
}
