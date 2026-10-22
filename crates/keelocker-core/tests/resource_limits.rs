use keelocker_core::{CoreEntryEdit, CoreError, CoreVault};
use keepass::{
    config::{CompressionConfig, KdfConfig},
    db::{DatabaseOpenError, DatabaseSaveError, KdbxLimits, PreparedKdbx4Save, Value},
    Database, DatabaseKey,
};
use sha2::{Digest, Sha256};
use std::{fs, path::Path};

const PASSWORD: &str = "fixture-password";

fn key() -> DatabaseKey {
    DatabaseKey::new().with_password(PASSWORD)
}

fn limits() -> KdbxLimits {
    KdbxLimits {
        max_file_bytes: 64 * 1024,
        max_decompressed_bytes: 128 * 1024,
        max_argon2_memory_bytes: 64 * 1024,
        max_argon2_iterations: 2,
        max_argon2_parallelism: 2,
        max_aes_rounds: 10,
    }
}

fn database() -> Database {
    let mut db = Database::new();
    db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
    let mut root = db.root_mut();
    let mut entry = root.add_entry();
    entry.set_unprotected("Title", "Synthetic resource test");
    entry.set_protected("Password", "synthetic-secret");
    entry.add_attachment("synthetic.bin", Value::unprotected(vec![42; 8192]));
    db
}

fn encrypted(db: &Database) -> Vec<u8> {
    let mut bytes = Vec::new();
    db.save(&mut bytes, key()).unwrap();
    bytes
}

fn fixture(name: &str) -> Vec<u8> {
    fs::read(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../KeeLockerTests/Fixtures")
            .join(name),
    )
    .unwrap()
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
            return (pos + 1 + width, length);
        }
        assert_ne!(bytes[pos], 0);
        pos += 1 + width + length;
    }
}

// Test-only edits of fields in an already serialized synthetic header. The
// production policy exclusively uses the library's existing header parsers.
fn change_kdf(bytes: &mut [u8], name: &str, value: &[u8]) {
    let (start, length) = header_field(bytes, 11, 4);
    let mut pos = start + 2;
    while pos + 9 < start + length {
        pos += 1;
        let name_length = u32::from_le_bytes(bytes[pos..pos + 4].try_into().unwrap()) as usize;
        pos += 4;
        let matches = &bytes[pos..pos + name_length] == name.as_bytes();
        pos += name_length;
        let value_length = u32::from_le_bytes(bytes[pos..pos + 4].try_into().unwrap()) as usize;
        pos += 4;
        if matches {
            assert_eq!(value_length, value.len());
            bytes[pos..pos + value_length].copy_from_slice(value);
            return;
        }
        pos += value_length;
    }
    panic!("Missing test KDF field");
}

fn repair_header_hash(bytes: &mut [u8]) {
    let (end, length) = header_field(bytes, 0, 4);
    let end = end + length;
    let hash = Sha256::digest(&bytes[..end]);
    bytes[end..end + 32].copy_from_slice(&hash);
}

fn argon(id: bool) -> KdfConfig {
    let KdfConfig::Argon2 { version, .. } = Database::new().config.kdf_config else {
        panic!("Default KDF changed");
    };
    if id {
        KdfConfig::Argon2id {
            memory: 64 * 1024,
            iterations: 1,
            parallelism: 1,
            version,
        }
    } else {
        KdfConfig::Argon2 {
            memory: 64 * 1024,
            iterations: 1,
            parallelism: 1,
            version,
        }
    }
}

fn assert_limit(result: Result<keepass::db::DecryptedKdbx, DatabaseOpenError>) {
    match result {
        Err(error) => assert!(
            error.is_resource_limit(),
            "Wrong error classification: {error}"
        ),
        Ok(_) => panic!("Expected resource admission failure"),
    }
}

#[test]
fn scoped_kdf_limits_reject_hostile_headers_before_key_lookup_or_authentication() {
    let mut aes = encrypted(&database());
    change_kdf(&mut aes, "R", &11u64.to_le_bytes());
    for repair in [false, true] {
        if repair {
            repair_header_hash(&mut aes);
        }
        // No credentials: rejection must precede credential lookup, not merely
        // fail later because of a bad header hash or an incorrect password.
        assert_limit(Database::decrypt_with_limits(
            &aes,
            DatabaseKey::new(),
            &limits(),
        ));
    }

    let mut legacy = fixture("interop.kdbx");
    let (pos, length) = header_field(&legacy, 6, 2);
    assert_eq!(length, 8);
    legacy[pos..pos + 8].copy_from_slice(&u64::MAX.to_le_bytes());
    assert_limit(Database::decrypt_with_limits(
        &legacy,
        DatabaseKey::new(),
        &limits(),
    ));

    for id in [false, true] {
        let mut db = database();
        db.config.kdf_config = argon(id);
        let original = encrypted(&db);
        for (field, value) in [
            ("M", (64 * 1024 + 1024u64).to_le_bytes().to_vec()),
            ("M", u64::MAX.to_le_bytes().to_vec()),
            ("I", 3u64.to_le_bytes().to_vec()),
            ("I", (u64::from(u32::MAX) + 1).to_le_bytes().to_vec()),
            ("P", 3u32.to_le_bytes().to_vec()),
            ("P", 0u32.to_le_bytes().to_vec()),
        ] {
            let mut bytes = original.clone();
            change_kdf(&mut bytes, field, &value);
            for repair in [false, true] {
                if repair {
                    repair_header_hash(&mut bytes);
                }
                assert_limit(Database::decrypt_with_limits(
                    &bytes,
                    DatabaseKey::new(),
                    &limits(),
                ));
            }
        }
    }
}

#[test]
fn argon_integer_ranges_are_checked_even_with_permissive_policy() {
    let mut policy = limits();
    policy.max_argon2_memory_bytes = u64::MAX;
    policy.max_argon2_iterations = u64::MAX;
    policy.max_argon2_parallelism = u32::MAX;
    for id in [false, true] {
        let original = argon(id);
        policy.validate_kdf(&original).unwrap();
        for (memory, iterations, parallelism) in [
            (64 * 1024, 0, 1),
            (64 * 1024, u64::from(u32::MAX) + 1, 1),
            ((u64::from(u32::MAX) + 1) * 1024, 1, 1),
            (64 * 1024 + 1, 1, 1),
            (7 * 1024, 1, 1),
            (8 * 1024, 1, 2),
            (64 * 1024, 1, 0),
            (64 * 1024, 1, u32::MAX),
        ] {
            let mut config = original.clone();
            match &mut config {
                KdfConfig::Argon2 {
                    memory: m,
                    iterations: i,
                    parallelism: p,
                    ..
                }
                | KdfConfig::Argon2id {
                    memory: m,
                    iterations: i,
                    parallelism: p,
                    ..
                } => {
                    *m = memory;
                    *i = iterations;
                    *p = parallelism;
                }
                _ => unreachable!(),
            }
            assert!(policy.validate_kdf(&config).is_err());
        }
    }
}

#[test]
fn expanded_payload_bound_covers_xml_and_inner_attachments_with_or_without_gzip() {
    for compression in [CompressionConfig::GZip, CompressionConfig::None] {
        let mut db = database();
        db.config.compression_config = compression;
        let bytes = encrypted(&db);
        let xml_length = Database::decrypt(&bytes, key()).unwrap().xml().len();
        let mut policy = limits();
        policy.max_decompressed_bytes = xml_length + 128;
        // The XML fits, but the complete inner attachment/header payload does not.
        assert_limit(Database::decrypt_with_limits(&bytes, key(), &policy));
        policy.max_decompressed_bytes = 128;
        assert_limit(Database::decrypt_with_limits(&bytes, key(), &policy));
        assert_eq!(
            Database::decrypt_with_limits(&bytes, key(), &limits())
                .unwrap()
                .parse()
                .unwrap(),
            db
        );
        assert_eq!(Database::parse(&bytes, key()).unwrap(), db);
    }
}

#[test]
fn encrypted_input_bound_is_checked_before_parsing() {
    let policy = KdbxLimits {
        max_file_bytes: 3,
        ..limits()
    };
    assert_limit(Database::decrypt_with_limits(
        b"not a database",
        DatabaseKey::new(),
        &policy,
    ));
}

#[test]
fn core_rejects_oversized_sparse_encrypted_file_without_modifying_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("sparse.kdbx");
    let file = fs::File::create(&path).unwrap();
    let length = 256 * 1024 * 1024 + 1;
    file.set_len(length).unwrap();
    assert!(matches!(
        CoreVault::open(path.to_string_lossy().into(), PASSWORD.into(), None),
        Err(CoreError::UnsupportedDatabase)
    ));
    assert_eq!(file.metadata().unwrap().len(), length);
}

#[cfg(unix)]
#[test]
fn core_rejects_fifo_without_waiting_for_a_writer_and_rejects_directories() {
    use std::ffi::CString;

    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("synthetic.fifo");
    let native = CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: native is a live NUL-terminated temporary pathname and mkfifo
    // only creates this synthetic pipe with owner-only permissions.
    assert_eq!(unsafe { libc::mkfifo(native.as_ptr(), 0o600) }, 0);
    assert!(matches!(
        CoreVault::open(path.to_string_lossy().into(), PASSWORD.into(), None),
        Err(CoreError::UnsupportedDatabase)
    ));
    assert!(matches!(
        CoreVault::open(dir.path().to_string_lossy().into(), PASSWORD.into(), None),
        Err(CoreError::UnsupportedDatabase)
    ));
}

#[test]
fn legacy_xml_binaries_share_the_payload_budget_and_preserve_error_classification() {
    let bytes = fixture("review-attachments.kdbx");
    let decrypted = Database::decrypt(&bytes, key()).unwrap();
    let document =
        roxmltree::Document::parse(std::str::from_utf8(decrypted.xml()).unwrap()).unwrap();
    assert!(document.descendants().any(|node| node.has_tag_name("Binary") && node.attribute("Compressed") == Some("True")), "Synthetic legacy fixture must exercise nested gzip expansion");
    let xml_length = decrypted.xml().len();
    let policy = KdbxLimits {
        max_aes_rounds: 100_000_000,
        max_decompressed_bytes: xml_length,
        ..limits()
    };
    let payload = Database::decrypt_with_limits(&bytes, key(), &policy).unwrap();
    let error = payload.parse().unwrap_err();
    assert!(
        error.is_resource_limit(),
        "Nested binary failure must retain resource classification: {error}"
    );
    let policy = KdbxLimits {
        max_decompressed_bytes: xml_length + 9,
        ..policy
    };
    let reopened = Database::decrypt_with_limits(&bytes, key(), &policy)
        .unwrap()
        .parse()
        .unwrap();
    assert_eq!(reopened, Database::parse(&bytes, key()).unwrap());
    let policy = KdbxLimits {
        max_decompressed_bytes: xml_length + 8,
        ..policy
    };
    assert!(Database::decrypt_with_limits(&bytes, key(), &policy)
        .unwrap()
        .parse()
        .unwrap_err()
        .is_resource_limit());
}

#[test]
fn bounded_save_validation_rejects_unopenable_output_without_writing() {
    let db = database();
    let config = db.config.clone();
    for policy in [
        KdbxLimits {
            max_decompressed_bytes: 128,
            ..limits()
        },
        KdbxLimits {
            max_file_bytes: 1,
            ..limits()
        },
        KdbxLimits {
            max_aes_rounds: 9,
            ..limits()
        },
    ] {
        let mut destination = b"unchanged destination".to_vec();
        let error = db
            .save_and_reopen_with_limits(&mut destination, key(), &policy)
            .unwrap_err();
        assert!(matches!(error, DatabaseSaveError::Validation(ref e) if e.is_resource_limit()));
        assert_eq!(destination, b"unchanged destination");
        let prepared = PreparedKdbx4Save::new(db.config.kdf_config.clone(), key()).unwrap();
        let error = prepared
            .save_and_reopen_with_limits(&db, &mut destination, &policy)
            .unwrap_err();
        assert!(matches!(error, DatabaseSaveError::Validation(ref e) if e.is_resource_limit()));
        assert_eq!(destination, b"unchanged destination");
        assert_eq!(db.config, config);
    }
    let mut bytes = Vec::new();
    let reopened = db
        .save_and_reopen_with_limits(&mut bytes, key(), &limits())
        .unwrap();
    assert_eq!(reopened, db);
    assert_eq!(
        Database::decrypt_with_limits(&bytes, key(), &limits())
            .unwrap()
            .parse()
            .unwrap(),
        db
    );
}

#[test]
fn valid_aes_and_argon_imports_and_bounded_saves_preserve_kdf_parameters() {
    for config in [KdfConfig::Aes { rounds: 10 }, argon(false), argon(true)] {
        let mut db = database();
        db.config.kdf_config = config.clone();
        let bytes = encrypted(&db);
        let opened = Database::decrypt_with_limits(&bytes, key(), &limits())
            .unwrap()
            .parse()
            .unwrap();
        assert_eq!(opened, db);
        let mut saved = Vec::new();
        let reopened = opened
            .save_and_reopen_with_limits(&mut saved, key(), &limits())
            .unwrap();
        assert_eq!(reopened.config.kdf_config, config);
        assert_eq!(Database::parse(&saved, key()).unwrap(), db);
        let prepared = PreparedKdbx4Save::new(config.clone(), key()).unwrap();
        saved.clear();
        let reopened = prepared
            .save_and_reopen_with_limits(&db, &mut saved, &limits())
            .unwrap();
        assert_eq!(reopened.config.kdf_config, config);
        assert_eq!(
            Database::decrypt_with_limits(&saved, key(), &limits())
                .unwrap()
                .parse()
                .unwrap(),
            db
        );
        assert_eq!(db.config.kdf_config, config);
    }
}

#[test]
fn core_open_rejects_hostile_kdbx3_and_kdbx4_headers_without_modifying_source() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("hostile.kdbx");
    let mut legacy = fixture("interop.kdbx");
    let (pos, _) = header_field(&legacy, 6, 2);
    legacy[pos..pos + 8].copy_from_slice(&100_000_001u64.to_le_bytes());
    let mut cases = vec![legacy];
    let mut aes = encrypted(&database());
    change_kdf(&mut aes, "R", &100_000_001u64.to_le_bytes());
    cases.push(aes.clone());
    repair_header_hash(&mut aes);
    cases.push(aes);
    for id in [false, true] {
        let mut db = database();
        db.config.kdf_config = argon(id);
        let original = encrypted(&db);
        for (field, value) in [
            ("M", (256 * 1024 * 1024 + 1024u64).to_le_bytes().to_vec()),
            ("I", 101u64.to_le_bytes().to_vec()),
            ("P", 17u32.to_le_bytes().to_vec()),
        ] {
            let mut bytes = original.clone();
            change_kdf(&mut bytes, field, &value);
            cases.push(bytes.clone());
            repair_header_hash(&mut bytes);
            cases.push(bytes);
        }
    }
    for bytes in cases {
        fs::write(&path, &bytes).unwrap();
        assert!(matches!(
            CoreVault::open(path.to_string_lossy().into(), PASSWORD.into(), None),
            Err(CoreError::UnsupportedDatabase)
        ));
        assert_eq!(fs::read(&path).unwrap(), bytes);
    }
}

#[test]
fn hostile_reload_keeps_clean_and_dirty_sessions_recoverable() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("source.kdbx");
    let copy = dir.path().join("recovery.kdbx");
    let db = database();
    let original = encrypted(&db);
    fs::write(&source, &original).unwrap();
    let vault = CoreVault::open(source.to_string_lossy().into(), PASSWORD.into(), None).unwrap();
    let id = vault.snapshot().unwrap().entries[0].id.clone();
    let mut hostile = original.clone();
    change_kdf(&mut hostile, "R", &100_000_001u64.to_le_bytes());
    repair_header_hash(&mut hostile);
    fs::write(&source, &hostile).unwrap();
    assert_eq!(
        vault.reload_if_changed(),
        Err(CoreError::UnsupportedDatabase)
    );
    assert!(!vault.snapshot().unwrap().info.dirty);
    assert_eq!(
        vault.entry(id.clone()).unwrap().title,
        "Synthetic resource test"
    );
    vault
        .update_entry(
            id.clone(),
            CoreEntryEdit {
                title: "Unsaved synthetic edit".into(),
                icon: None,
                username: String::new(),
                password: "synthetic-secret".into(),
                url: String::new(),
                notes: String::new(),
                tags: vec![],
                custom_fields: vec![],
            },
        )
        .unwrap();
    assert_eq!(vault.reload(), Err(CoreError::UnsupportedDatabase));
    assert_eq!(
        vault.entry(id.clone()).unwrap().title,
        "Unsaved synthetic edit"
    );
    assert!(vault.snapshot().unwrap().info.dirty);
    assert_eq!(fs::read(&source).unwrap(), hostile);
    vault.save_as(copy.to_string_lossy().into()).unwrap();
    let reopened = Database::parse(&fs::read(copy).unwrap(), key()).unwrap();
    assert_eq!(reopened.config.kdf_config, db.config.kdf_config);
    assert_eq!(
        CoreVault::open(vault.snapshot().unwrap().info.path, PASSWORD.into(), None)
            .unwrap()
            .entry(id)
            .unwrap()
            .title,
        "Unsaved synthetic edit"
    );
}
