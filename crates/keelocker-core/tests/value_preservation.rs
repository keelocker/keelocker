use keelocker_core::{CoreEntry, CoreVault};
use keepass::{config::KdfConfig, db::TOTP, Database, DatabaseKey};
use std::{
    fs,
    io::Write,
    path::Path,
    process::{Command, Stdio},
};

const PASSWORD: &str = "synthetic-value-preservation";

fn key() -> DatabaseKey {
    DatabaseKey::new().with_password(PASSWORD)
}

fn fixture(path: &Path) -> String {
    let mut db = Database::new();
    db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
    db.meta.database_name = Some("   ".into());
    db.meta.database_description = Some(" \u{2003} ".into());
    db.meta.default_username = Some(" \t ".into());
    db.root_mut().notes = Some("   ".into());
    db.root_mut().default_autotype_sequence = Some("   ".into());
    let id = db
        .root_mut()
        .add_entry()
        .edit(|e| {
            e.set_unprotected("Title", "Historical synthetic entry");
            e.set_unprotected("Password", "   ");
            e.set_unprotected("Notes", " \u{2003} ");
            e.set_unprotected("Spaces", "   ");
            e.set_protected("ProtectedSpaces", "   ");
            e.set_unprotected("Mixed", " x ");
            e.set_unprotected("Empty", "");
            e.override_url = Some("   ".into());
        })
        .id();
    db.entry_mut(id).unwrap().edit_tracking(|e| {
        e.set_unprotected("Title", "Current synthetic entry");
    });
    db.save(&mut fs::File::create(path).unwrap(), key())
        .unwrap();
    id.to_string()
}

fn assert_entry(entry: CoreEntry) {
    assert_eq!(entry.password, "   ");
    assert_eq!(entry.notes, " \u{2003} ");
    for (name, value, protected) in [
        ("Spaces", "   ", false),
        ("ProtectedSpaces", "   ", true),
        ("Mixed", " x ", false),
        ("Empty", "", false),
    ] {
        let field = entry.custom_fields.iter().find(|f| f.name == name).unwrap();
        assert_eq!(field.value, value, "{name}");
        assert_eq!(field.protected, protected, "{name}");
    }
}

#[test]
fn whitespace_values_survive_open_history_and_unrelated_saves() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("synthetic.kdbx");
    let id = fixture(&path);
    let original_xml = Database::get_xml(&mut fs::File::open(&path).unwrap(), key()).unwrap();
    assert!(String::from_utf8(original_xml)
        .unwrap()
        .contains("<Value>   </Value>"));
    let vault = CoreVault::open(path.to_string_lossy().into(), PASSWORD.into(), None).unwrap();
    assert_entry(vault.entry(id.clone()).unwrap());
    let history = vault.history(id.clone()).unwrap();
    assert_eq!(history.len(), 1);
    assert_entry(history.into_iter().next().unwrap());
    for name in ["Unrelated rename 1", "Unrelated rename 2"] {
        vault
            .rename_group(vault.snapshot().unwrap().info.root_id, name.into())
            .unwrap();
        vault.save().unwrap();
    }
    let reopened = CoreVault::open(path.to_string_lossy().into(), PASSWORD.into(), None).unwrap();
    assert_entry(reopened.entry(id.clone()).unwrap());
    assert_entry(reopened.history(id).unwrap().into_iter().next().unwrap());
    let db = Database::parse(&fs::read(path).unwrap(), key()).unwrap();
    assert_eq!(db.meta.database_name.as_deref(), Some("   "));
    assert_eq!(db.meta.database_description.as_deref(), Some(" \u{2003} "));
    assert_eq!(db.meta.default_username.as_deref(), Some(" \t "));
    assert_eq!(db.root().notes.as_deref(), Some("   "));
    assert_eq!(db.root().default_autotype_sequence.as_deref(), Some("   "));
    assert_eq!(
        db.iter_all_entries()
            .next()
            .unwrap()
            .override_url
            .as_deref(),
        Some("   ")
    );
}

#[test]
fn blank_tag_lists_allow_unrelated_saves() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("blank-tags.kdbx");
    let mut db = Database::new();
    db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
    db.root_mut().tags = vec!["   ".into()];
    db.root_mut().add_entry().tags = vec![" \u{2003} ".into()];
    db.save(&mut fs::File::create(&path).unwrap(), key())
        .unwrap();
    let vault = CoreVault::open(path.to_string_lossy().into(), PASSWORD.into(), None).unwrap();
    vault
        .rename_group(
            vault.snapshot().unwrap().info.root_id,
            "Unrelated rename".into(),
        )
        .unwrap();
    vault.save().unwrap();
    let db = Database::parse(&fs::read(&path).unwrap(), key()).unwrap();
    assert!(db.root().tags.is_empty());
    assert!(db.iter_all_entries().next().unwrap().tags.is_empty());
}

#[test]
fn otp_generation_accepts_only_time_based_uri_types() {
    let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
    let totp: TOTP = format!("otpauth://totp/Synthetic?secret={secret}")
        .parse()
        .unwrap();
    assert_eq!(totp.period, 30);
    assert_eq!(totp.digits, 6);
    assert_eq!(totp.value_at(59).code, "287082");
    for kind in ["hotp", "unknown", ""] {
        let raw = format!("otpauth://{kind}/Synthetic?secret={secret}&counter=0");
        assert!(raw.parse::<TOTP>().is_err(), "unsupported OTP type {kind}");
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("unsupported-otp.kdbx");
        let mut db = Database::new();
        db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
        let id = db
            .root_mut()
            .add_entry()
            .edit(|entry| {
                entry.set_unprotected("Title", "Synthetic unsupported OTP");
                entry.set_unprotected("otp", &raw);
            })
            .id()
            .to_string();
        db.save(&mut fs::File::create(&path).unwrap(), key())
            .unwrap();
        let vault = CoreVault::open(path.to_string_lossy().into(), PASSWORD.into(), None).unwrap();
        vault
            .rename_group(
                vault.snapshot().unwrap().info.root_id,
                "Unrelated edit".into(),
            )
            .unwrap();
        vault.save().unwrap();
        let reopened =
            CoreVault::open(path.to_string_lossy().into(), PASSWORD.into(), None).unwrap();
        let entry = reopened.entry(id).unwrap();
        assert!(entry.otp.is_none());
        assert_eq!(
            entry
                .custom_fields
                .iter()
                .find(|field| field.name == "otp")
                .unwrap()
                .value,
            raw
        );
    }
}

#[test]
#[ignore = "requires KeePassXC CLI"]
fn keepassxc_preserves_whitespace_after_keelocker_save() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("synthetic.kdbx");
    fixture(&path);
    let vault = CoreVault::open(path.to_string_lossy().into(), PASSWORD.into(), None).unwrap();
    vault
        .rename_group(
            vault.snapshot().unwrap().info.root_id,
            "Unrelated change".into(),
        )
        .unwrap();
    vault.save().unwrap();
    let cli = std::env::var("KEEPASSXC_CLI")
        .unwrap_or_else(|_| "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli".into());
    let mut child = Command::new(cli)
        .args(["export", "--quiet"])
        .arg(&path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("KeePassXC CLI required for interoperability tests");
    writeln!(child.stdin.take().unwrap(), "{PASSWORD}").unwrap();
    let result = child.wait_with_output().unwrap();
    assert!(
        result.status.success(),
        "KeePassXC export failed; output intentionally withheld"
    );
    let text = std::str::from_utf8(&result.stdout).unwrap();
    let xml = roxmltree::Document::parse(text).unwrap();
    let mut checked = 0;
    for entry in xml.descendants().filter(|n| n.has_tag_name("Entry")) {
        for field in entry.children().filter(|n| n.has_tag_name("String")) {
            let name = field
                .children()
                .find(|n| n.has_tag_name("Key"))
                .unwrap()
                .text()
                .unwrap();
            let expected = match name {
                "Password" | "Spaces" | "ProtectedSpaces" => "   ",
                "Notes" => " \u{2003} ",
                "Mixed" => " x ",
                "Empty" => "",
                _ => continue,
            };
            let value = field
                .children()
                .find(|n| n.has_tag_name("Value"))
                .unwrap()
                .text()
                .unwrap_or("");
            assert_eq!(value, expected, "{name}");
            checked += 1;
        }
    }
    assert_eq!(checked, 12, "six fields in current and historical versions");
}
