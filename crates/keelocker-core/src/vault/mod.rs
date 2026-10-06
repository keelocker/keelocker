use crate::{
    kdbx::{io, mapping},
    models::*,
    CoreError,
};
use keepass::{
    db::{EntryId, GroupId, Times, Value},
    Database, DatabaseKey,
};
use std::{
    fs::File,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, MutexGuard},
};
use uuid::Uuid;
use zeroize::Zeroizing;

struct Session {
    db: Database,
    key: DatabaseKey,
    path: PathBuf,
    hash: [u8; 32],
    dirty: bool,
    next_save: Option<std::thread::JoinHandle<Result<keepass::db::PreparedKdbx4Save, CoreError>>>,
}

impl Session {
    fn reload(&mut self, discard_changes: bool) -> Result<bool, CoreError> {
        let bytes = io::read_canonical(&self.path)?;
        let hash = io::digest(&bytes);
        if !discard_changes && hash == self.hash {
            return Ok(false);
        }
        if !discard_changes && self.dirty {
            return Err(CoreError::Conflict);
        }
        // Decode and validate before replacing anything. Failed refreshes retain
        // the session, its unsaved changes and the last accepted file hash.
        let db = io::load_bytes(&bytes, &self.key)?;
        let kdf_changed = db.config.kdf_config != self.db.config.kdf_config;
        self.db = db;
        self.hash = hash;
        self.dirty = false;
        if kdf_changed {
            self.prepare_next_save();
        }
        Ok(true)
    }

    fn prepare_next_save(&mut self) {
        let config = self.db.config.kdf_config.clone();
        let key = self.key.clone();
        // Only one future save is prepared per session. Dropping the session
        // drops its handle/result; an in-flight KDF finishes and drops its result.
        self.next_save = std::thread::Builder::new()
            .name("kdbx-next-save".into())
            .spawn(move || {
                keepass::db::PreparedKdbx4Save::new(config, key).map_err(|_| CoreError::WriteFailed)
            })
            .ok();
    }

    fn save_to(&mut self, path: &Path, expected: Option<[u8; 32]>) -> Result<(), CoreError> {
        let prepared = self
            .next_save
            .take()
            .map(|task| task.join().map_err(|_| CoreError::WriteFailed)?)
            .transpose();
        let result =
            prepared.and_then(|prepared| io::save(&self.db, &self.key, path, expected, prepared));
        self.prepare_next_save();
        let outcome = result?;
        self.path = outcome.path;
        self.hash = outcome.hash;
        self.dirty = !outcome.directory_synced;
        if outcome.directory_synced {
            Ok(())
        } else {
            Err(CoreError::WriteFailed)
        }
    }
}

#[derive(uniffi::Object)]
pub struct CoreVault {
    session: Mutex<Option<Session>>,
}

fn entry_id(id: &str) -> Result<EntryId, CoreError> {
    Uuid::parse_str(id)
        .map(EntryId::from_uuid)
        .map_err(|_| CoreError::InvalidOperation)
}
fn group_id(id: &str) -> Result<GroupId, CoreError> {
    Uuid::parse_str(id)
        .map(GroupId::from_uuid)
        .map_err(|_| CoreError::InvalidOperation)
}

impl CoreVault {
    fn open_key(path: String, key: DatabaseKey) -> Result<Arc<Self>, CoreError> {
        let path = Path::new(&path)
            .canonicalize()
            .map_err(|_| CoreError::ReadFailed)?;
        let (db, hash) = io::load(&path, &key)?;
        let mut session = Session {
            db,
            key,
            path,
            hash,
            dirty: false,
            next_save: None,
        };
        session.prepare_next_save();
        Ok(Arc::new(Self {
            session: Mutex::new(Some(session)),
        }))
    }

    fn guard(&self) -> Result<MutexGuard<'_, Option<Session>>, CoreError> {
        self.session.lock().map_err(|_| CoreError::InvalidOperation)
    }
    fn with<T>(
        &self,
        f: impl FnOnce(&mut Session) -> Result<T, CoreError>,
    ) -> Result<T, CoreError> {
        let mut guard = self.guard()?;
        f(guard.as_mut().ok_or(CoreError::InvalidOperation)?)
    }
}

#[uniffi::export]
impl CoreVault {
    #[uniffi::constructor]
    pub fn open(
        path: String,
        password: String,
        key_file: Option<String>,
    ) -> Result<Arc<Self>, CoreError> {
        let password = Zeroizing::new(password);
        let mut key = if password.is_empty() && key_file.is_some() {
            DatabaseKey::new()
        } else {
            DatabaseKey::new().with_password(&password)
        };
        if let Some(file) = key_file {
            key = key
                .with_keyfile(&mut File::open(file).map_err(|_| CoreError::ReadFailed)?)
                .map_err(|_| CoreError::ReadFailed)?;
        }
        Self::open_key(path, key)
    }

    /// Reopen with normalized credential components, never a cached final KDF key.
    #[uniffi::constructor]
    pub fn open_with_key_material(path: String, material: Vec<u8>) -> Result<Arc<Self>, CoreError> {
        let material = Zeroizing::new(material);
        if !material.starts_with(b"KLQ1") || !matches!(material.len(), 36 | 68) {
            return Err(CoreError::InvalidOperation);
        }
        let elements = material[4..]
            .as_chunks::<32>()
            .0
            .iter()
            .map(|part| part.to_vec())
            .collect();
        let key =
            DatabaseKey::from_key_elements(elements).map_err(|_| CoreError::InvalidOperation)?;
        Self::open_key(path, key)
    }

    /// Secret, versioned pre-KDF components for the host's session-only quick unlock.
    pub fn key_material(&self) -> Result<Vec<u8>, CoreError> {
        self.with(|session| {
            let elements = Zeroizing::new(
                session
                    .key
                    .get_key_elements()
                    .map_err(|_| CoreError::InvalidOperation)?,
            );
            if !matches!(elements.len(), 1 | 2) || elements.iter().any(|part| part.len() != 32) {
                return Err(CoreError::InvalidOperation);
            }
            let mut material = Vec::with_capacity(4 + elements.len() * 32);
            material.extend_from_slice(b"KLQ1");
            for element in elements.iter() {
                material.extend_from_slice(element);
            }
            Ok(material)
        })
    }

    pub fn lock(&self) {
        if let Ok(mut guard) = self.session.lock() {
            *guard = None;
        }
    }

    // Returns false for our own saves and unrelated directory events. Credentials
    // stay in Rust; refreshing never asks Swift to retain the master password.
    pub fn reload_if_changed(&self) -> Result<bool, CoreError> {
        self.with(|s| s.reload(false))
    }

    // Explicit user recovery: discard local changes only after a successful read.
    pub fn reload(&self) -> Result<(), CoreError> {
        self.with(|s| s.reload(true).map(|_| ()))
    }

    pub fn snapshot(&self) -> Result<CoreSnapshot, CoreError> {
        self.with(|s| {
            let name =
                s.db.meta
                    .database_name
                    .clone()
                    .filter(|n| !n.trim().is_empty())
                    .unwrap_or_else(|| {
                        s.path
                            .file_stem()
                            .unwrap_or_default()
                            .to_string_lossy()
                            .into()
                    });
            Ok(CoreSnapshot {
                info: CoreVaultInfo {
                    name,
                    path: s.path.to_string_lossy().into(),
                    dirty: s.dirty,
                    root_id: s.db.root().id().to_string(),
                },
                groups: mapping::groups(&s.db),
                entries: s
                    .db
                    .iter_all_entries()
                    .map(|e| mapping::entry(e, false))
                    .collect(),
            })
        })
    }

    pub fn entry(&self, id: String) -> Result<CoreEntry, CoreError> {
        self.with(|s| {
            Ok(mapping::entry(
                s.db.entry(entry_id(&id)?)
                    .ok_or(CoreError::InvalidOperation)?,
                true,
            ))
        })
    }

    pub fn create_entry(&self, group: String, edit: CoreEntryEdit) -> Result<String, CoreError> {
        validate_edit(&edit)?;
        self.with(|s| {
            let id =
                s.db.group_mut(group_id(&group)?)
                    .ok_or(CoreError::InvalidOperation)?
                    .add_entry()
                    .id();
            apply_edit(&mut s.db, id, edit)?;
            s.dirty = true;
            Ok(id.to_string())
        })
    }

    pub fn update_entry(&self, id: String, edit: CoreEntryEdit) -> Result<(), CoreError> {
        validate_edit(&edit)?;
        self.with(|s| {
            apply_edit(&mut s.db, entry_id(&id)?, edit)?;
            s.dirty = true;
            Ok(())
        })
    }

    pub fn delete_entry(&self, id: String) -> Result<(), CoreError> {
        self.with(|s| {
            s.db.entry_mut(entry_id(&id)?)
                .ok_or(CoreError::InvalidOperation)?
                .track_changes()
                .remove();
            s.dirty = true;
            Ok(())
        })
    }

    pub fn move_entry(&self, id: String, destination: String) -> Result<(), CoreError> {
        self.with(|s| {
            let destination = group_id(&destination)?;
            s.db.group(destination).ok_or(CoreError::InvalidOperation)?;
            s.db.entry_mut(entry_id(&id)?)
                .ok_or(CoreError::InvalidOperation)?
                .track_changes()
                .move_to(destination)
                .map_err(|_| CoreError::InvalidOperation)?;
            s.dirty = true;
            Ok(())
        })
    }

    pub fn create_group(&self, parent: String, name: String) -> Result<String, CoreError> {
        if name.trim().is_empty() {
            return Err(CoreError::InvalidOperation);
        }
        self.with(|s| {
            let mut parent =
                s.db.group_mut(group_id(&parent)?)
                    .ok_or(CoreError::InvalidOperation)?;
            let mut child = parent.add_group();
            child.name = name;
            let id = child.id().to_string();
            s.dirty = true;
            Ok(id)
        })
    }

    pub fn rename_group(&self, id: String, name: String) -> Result<(), CoreError> {
        if name.trim().is_empty() {
            return Err(CoreError::InvalidOperation);
        }
        self.with(|s| {
            let mut g =
                s.db.group_mut(group_id(&id)?)
                    .ok_or(CoreError::InvalidOperation)?;
            g.name = name;
            g.times.last_modification = Some(Times::now());
            s.dirty = true;
            Ok(())
        })
    }

    pub fn move_group(&self, id: String, destination: String) -> Result<(), CoreError> {
        self.with(|s| {
            s.db.group_mut(group_id(&id)?)
                .ok_or(CoreError::InvalidOperation)?
                .track_changes()
                .move_to(group_id(&destination)?)
                .map_err(|_| CoreError::InvalidOperation)?;
            s.dirty = true;
            Ok(())
        })
    }

    pub fn delete_group(&self, id: String) -> Result<(), CoreError> {
        self.with(|s| {
            let id = group_id(&id)?;
            let g = s.db.group(id).ok_or(CoreError::InvalidOperation)?;
            // Avoid accidental recursive destruction. Move/delete children explicitly.
            if g.parent().is_none() || g.groups().next().is_some() || g.entries().next().is_some() {
                return Err(CoreError::InvalidOperation);
            }
            s.db.group_mut(id)
                .ok_or(CoreError::InvalidOperation)?
                .track_changes()
                .remove()
                .map_err(|_| CoreError::InvalidOperation)?;
            s.dirty = true;
            Ok(())
        })
    }

    pub fn attachment(&self, entry: String, name: String) -> Result<Vec<u8>, CoreError> {
        self.with(|s| {
            Ok(s.db
                .entry(entry_id(&entry)?)
                .ok_or(CoreError::InvalidOperation)?
                .attachment_by_name(&name)
                .ok_or(CoreError::InvalidOperation)?
                .data
                .get()
                .clone())
        })
    }

    pub fn put_attachment(
        &self,
        entry: String,
        name: String,
        data: Vec<u8>,
    ) -> Result<(), CoreError> {
        if name.is_empty() {
            return Err(CoreError::InvalidOperation);
        }
        self.with(|s| {
            let mut e =
                s.db.entry_mut(entry_id(&entry)?)
                    .ok_or(CoreError::InvalidOperation)?;
            // Materialize history before replacing a referenced binary.
            drop(e.track_changes());
            e.add_attachment(name, Value::protected(data));
            e.times.last_modification = Some(Times::now());
            s.dirty = true;
            Ok(())
        })
    }

    pub fn delete_attachment(&self, entry: String, name: String) -> Result<(), CoreError> {
        self.with(|s| {
            let mut e =
                s.db.entry_mut(entry_id(&entry)?)
                    .ok_or(CoreError::InvalidOperation)?;
            if e.as_ref().attachment_by_name(&name).is_none() {
                return Err(CoreError::InvalidOperation);
            }
            drop(e.track_changes());
            e.remove_attachment_by_name(&name);
            e.times.last_modification = Some(Times::now());
            s.dirty = true;
            Ok(())
        })
    }

    pub fn history(&self, entry: String) -> Result<Vec<CoreEntry>, CoreError> {
        self.with(|s| {
            let e =
                s.db.entry(entry_id(&entry)?)
                    .ok_or(CoreError::InvalidOperation)?;
            let count = e.history.as_ref().map_or(0, |h| h.get_entries().len());
            Ok((0..count)
                .filter_map(|i| e.historical(i))
                .map(|h| mapping::entry_in_group(h, true, e.parent().id().to_string()))
                .collect())
        })
    }

    pub fn save(&self) -> Result<(), CoreError> {
        self.with(|s| s.save_to(&s.path.clone(), Some(s.hash)))
    }

    pub fn save_as(&self, path: String) -> Result<(), CoreError> {
        self.with(|s| {
            let path = io::canonical_destination(Path::new(&path))?;
            s.save_to(&path, if path == s.path { Some(s.hash) } else { None })
        })
    }
}

fn validate_edit(edit: &CoreEntryEdit) -> Result<(), CoreError> {
    let mut names = std::collections::HashSet::new();
    for field in &edit.custom_fields {
        if field.name.is_empty()
            || mapping::STANDARD.contains(&field.name.as_str())
            || !names.insert(&field.name)
        {
            return Err(CoreError::InvalidOperation);
        }
    }
    if edit.tags.iter().any(|t| t.contains([';', ',', '\t'])) {
        return Err(CoreError::InvalidOperation);
    }
    Ok(())
}

fn apply_edit(db: &mut Database, id: EntryId, edit: CoreEntryEdit) -> Result<(), CoreError> {
    let mut e = db.entry_mut(id).ok_or(CoreError::InvalidOperation)?;
    let mut track = e.track_changes();
    for (key, value) in [
        ("Title", edit.title),
        ("UserName", edit.username),
        ("Password", edit.password),
        ("URL", edit.url),
        ("Notes", edit.notes),
    ] {
        let protected =
            key == "Password" || track.fields.get(key).is_some_and(|v| v.is_protected());
        track.set(
            key,
            if protected {
                Value::protected(value)
            } else {
                Value::unprotected(value)
            },
        );
    }
    track
        .fields
        .retain(|k, _| mapping::STANDARD.contains(&k.as_str()));
    for f in edit.custom_fields {
        track.set(
            f.name,
            if f.protected {
                Value::protected(f.value)
            } else {
                Value::unprotected(f.value)
            },
        );
    }
    track.tags = edit
        .tags
        .into_iter()
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .collect();
    track.times.last_modification = Some(Times::now());
    Ok(())
}

#[cfg(test)]
mod persistence_recovery_tests {
    use super::*;
    use keepass::config::KdfConfig;
    use std::fs;

    const PASSWORD: &str = "synthetic-recovery-password";

    fn path(path: &Path) -> String {
        path.to_string_lossy().into_owned()
    }

    fn open(path: &Path) -> Arc<CoreVault> {
        CoreVault::open(self::path(path), PASSWORD.into(), None).unwrap()
    }

    fn source(path: &Path) -> Arc<CoreVault> {
        let mut db = Database::new();
        db.config.kdf_config = KdfConfig::Aes { rounds: 10 };
        db.root_mut()
            .add_entry()
            .set_unprotected("Title", "original");
        db.save(
            &mut File::create(path).unwrap(),
            DatabaseKey::new().with_password(PASSWORD),
        )
        .unwrap();
        open(path)
    }

    fn edit(vault: &CoreVault, title: &str) {
        let id = vault.snapshot().unwrap().entries[0].id.clone();
        vault
            .update_entry(
                id,
                CoreEntryEdit {
                    title: title.into(),
                    username: String::new(),
                    password: "synthetic".into(),
                    url: String::new(),
                    notes: String::new(),
                    tags: vec![],
                    custom_fields: vec![],
                },
            )
            .unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn canonical_path_retargeted_before_read_cannot_open_another_vault() {
        use std::os::unix::fs::symlink;

        let dir = tempfile::tempdir().unwrap();
        let first = dir.path().join("first.kdbx");
        let second = dir.path().join("second.kdbx");
        let parked = dir.path().join("parked.kdbx");
        source(&first).lock();
        let other = source(&second);
        edit(&other, "other vault with the same credentials");
        other.save().unwrap();
        other.lock();
        // This is the boundary between open_key's canonicalization and load.
        let canonical = first.canonicalize().unwrap();
        fs::rename(&first, &parked).unwrap();
        symlink(&second, &first).unwrap();
        let loaded = io::load(&canonical, &DatabaseKey::new().with_password(PASSWORD));
        assert!(
            matches!(loaded, Err(CoreError::ReadFailed)),
            "A resolved path must not publish bytes from a different canonical file"
        );
    }

    #[cfg(unix)]
    #[test]
    fn retargeted_reload_preserves_the_original_session_and_local_edit() {
        use std::os::unix::fs::symlink;

        for discard_changes in [true, false] {
            let dir = tempfile::tempdir().unwrap();
            let first = dir.path().join("first.kdbx");
            let second = dir.path().join("second.kdbx");
            let parked = dir.path().join("parked.kdbx");
            let vault = source(&first);
            let other = source(&second);
            edit(&other, "other vault with the same credentials");
            other.save().unwrap();
            other.lock();
            edit(&vault, "local unsaved edit");
            fs::rename(&first, &parked).unwrap();
            symlink(&second, &first).unwrap();
            let result = if discard_changes {
                vault.reload().map(|_| false)
            } else {
                vault.reload_if_changed()
            };
            assert_eq!(result, Err(CoreError::ReadFailed));
            assert_eq!(
                vault.snapshot().unwrap().entries[0].title,
                "local unsaved edit"
            );
            assert!(vault.snapshot().unwrap().info.dirty);
            fs::remove_file(&first).unwrap();
            fs::rename(&parked, &first).unwrap();
            vault.save().unwrap();
            assert_eq!(
                open(&first).snapshot().unwrap().entries[0].title,
                "local unsaved edit"
            );
            assert_eq!(
                open(&second).snapshot().unwrap().entries[0].title,
                "other vault with the same credentials"
            );
        }
    }

    #[test]
    fn directory_sync_failure_retains_warning_and_allows_save_retry() {
        let dir = tempfile::tempdir().unwrap();
        let source_path = dir.path().join("source.kdbx");
        let vault = source(&source_path);
        let original = fs::read(&source_path).unwrap();
        edit(&vault, "local edit");
        assert_eq!(
            io::with_directory_sync_failure(|| vault.save()),
            Err(CoreError::WriteFailed)
        );
        assert!(vault.snapshot().unwrap().info.dirty);
        assert_eq!(
            open(&source_path).snapshot().unwrap().entries[0].title,
            "local edit"
        );
        assert_eq!(
            fs::read(source_path.with_extension("kdbx.bak")).unwrap(),
            original
        );
        assert_eq!(vault.reload_if_changed(), Ok(false));

        // Another failed sync must advance the accepted hash again, retaining the warning.
        assert_eq!(
            io::with_directory_sync_failure(|| vault.save()),
            Err(CoreError::WriteFailed)
        );
        assert!(vault.snapshot().unwrap().info.dirty);
        vault.save().unwrap();
        assert!(!vault.snapshot().unwrap().info.dirty);
        assert_eq!(vault.reload_if_changed(), Ok(false));
    }

    #[test]
    fn directory_sync_failure_adopts_save_as_destination_and_allows_retry() {
        let dir = tempfile::tempdir().unwrap();
        let source_path = dir.path().join("source.kdbx");
        let copy_path = dir.path().join("copy.kdbx");
        let vault = source(&source_path);
        let original = fs::read(&source_path).unwrap();
        edit(&vault, "copied edit");
        assert_eq!(
            io::with_directory_sync_failure(|| vault.save_as(path(&copy_path))),
            Err(CoreError::WriteFailed)
        );
        assert_eq!(
            vault.snapshot().unwrap().info.path,
            path(&copy_path.canonicalize().unwrap())
        );
        assert!(vault.snapshot().unwrap().info.dirty);
        assert_eq!(
            open(&copy_path).snapshot().unwrap().entries[0].title,
            "copied edit"
        );
        assert_eq!(fs::read(&source_path).unwrap(), original);
        vault.save_as(path(&copy_path)).unwrap();
        assert!(!vault.snapshot().unwrap().info.dirty);
        edit(&vault, "later edit");
        vault.save().unwrap();
        assert_eq!(
            open(&copy_path).snapshot().unwrap().entries[0].title,
            "later edit"
        );
        assert_eq!(fs::read(&source_path).unwrap(), original);
    }

    #[test]
    fn directory_sync_recovery_preserves_actual_external_changes() {
        for save_as in [false, true] {
            let dir = tempfile::tempdir().unwrap();
            let source_path = dir.path().join("source.kdbx");
            let copy_path = dir.path().join("copy.kdbx");
            let destination = if save_as { &copy_path } else { &source_path };
            let vault = source(&source_path);
            edit(&vault, "local edit");
            let save = || {
                if save_as {
                    vault.save_as(path(destination))
                } else {
                    vault.save()
                }
            };
            assert_eq!(
                io::with_directory_sync_failure(save),
                Err(CoreError::WriteFailed)
            );
            let external = open(destination);
            edit(&external, "external edit");
            external.save().unwrap();
            let external_bytes = fs::read(destination).unwrap();
            assert_eq!(save(), Err(CoreError::Conflict));
            assert_eq!(vault.save(), Err(CoreError::Conflict));
            assert_eq!(vault.reload_if_changed(), Err(CoreError::Conflict));
            assert!(vault.snapshot().unwrap().info.dirty);
            assert_eq!(vault.snapshot().unwrap().entries[0].title, "local edit");
            assert_eq!(fs::read(destination).unwrap(), external_bytes);
            assert_eq!(
                open(destination).snapshot().unwrap().entries[0].title,
                "external edit"
            );
        }
    }

    #[test]
    fn save_as_failure_before_commit_retains_original_session() {
        let dir = tempfile::tempdir().unwrap();
        let source_path = dir.path().join("source.kdbx");
        let other_path = dir.path().join("other.kdbx");
        let vault = source(&source_path);
        let _other = source(&other_path);
        let other_bytes = fs::read(&other_path).unwrap();
        edit(&vault, "local edit");
        assert_eq!(vault.save_as(path(&other_path)), Err(CoreError::Conflict));
        assert_eq!(
            vault.snapshot().unwrap().info.path,
            path(&source_path.canonicalize().unwrap())
        );
        assert_eq!(fs::read(&other_path).unwrap(), other_bytes);
        assert!(vault.snapshot().unwrap().info.dirty);
        vault.save().unwrap();
    }
}
