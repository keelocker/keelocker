use super::*;

/// Ignore stale/nil references and, critically, a reference to the database root.
pub(super) fn id(db: &Database) -> Option<GroupId> {
    db.meta
        .recyclebin_uuid
        .map(GroupId::from_uuid)
        .filter(|id| !id.uuid().is_nil() && *id != db.root().id() && db.group(*id).is_some())
}

pub(super) fn contains(db: &Database, group: GroupId) -> bool {
    let Some(bin) = id(db) else { return false };
    let mut current = Some(group);
    while let Some(id) = current {
        if id == bin {
            return true;
        }
        current = db.group(id).and_then(|g| g.parent().map(|p| p.id()));
    }
    false
}

pub(super) fn writable_group(db: &Database, group: GroupId) -> Result<(), CoreError> {
    if db.group(group).is_none() || contains(db, group) {
        return Err(CoreError::InvalidOperation);
    }
    Ok(())
}

pub(super) fn writable_entry(db: &Database, entry: EntryId) -> Result<(), CoreError> {
    let entry = db.entry(entry).ok_or(CoreError::InvalidOperation)?;
    writable_group(db, entry.parent().id())
}

fn ensure(db: &mut Database) -> GroupId {
    if let Some(id) = id(db) {
        return id;
    }
    let id = {
        let mut root = db.root_mut();
        let mut bin = root.add_group();
        bin.name = "Recycle Bin".into();
        bin.set_icon_builtin(43);
        bin.enable_autotype = Some(false);
        bin.enable_searching = Some(false);
        bin.id()
    };
    db.meta.recyclebin_uuid = Some(id.uuid());
    db.meta.recyclebin_changed = Some(Times::now());
    id
}

pub(super) fn delete(s: &mut Session, entry: EntryId) -> Result<(), CoreError> {
    // Repeating Delete must never turn a recoverable deletion into destruction.
    writable_entry(&s.db, entry)?;
    if s.db.meta.recyclebin_enabled.unwrap_or(true) {
        let destination = ensure(&mut s.db);
        relocate(s, entry, destination)?;
    } else {
        s.db.entry_mut(entry)
            .ok_or(CoreError::InvalidOperation)?
            .track_changes()
            .remove();
    }
    s.dirty = true;
    Ok(())
}

pub(super) fn restore(s: &mut Session, entry: EntryId) -> Result<(), CoreError> {
    let source = s.db.entry(entry).ok_or(CoreError::InvalidOperation)?;
    if !contains(&s.db, source.parent().id()) {
        return Err(CoreError::InvalidOperation);
    }
    let destination = source
        .previous_parent()
        .map(|group| group.id())
        .filter(|group| !contains(&s.db, *group))
        .unwrap_or_else(|| s.db.root().id());
    relocate(s, entry, destination)?;
    s.dirty = true;
    Ok(())
}

pub(super) fn delete_permanently(s: &mut Session, entry: EntryId) -> Result<(), CoreError> {
    let source = s.db.entry(entry).ok_or(CoreError::InvalidOperation)?;
    if !contains(&s.db, source.parent().id()) {
        return Err(CoreError::InvalidOperation);
    }
    s.db.entry_mut(entry)
        .ok_or(CoreError::InvalidOperation)?
        .track_changes()
        .remove();
    s.dirty = true;
    Ok(())
}

fn relocate(s: &mut Session, entry: EntryId, destination: GroupId) -> Result<(), CoreError> {
    // A recoverable deletion/restoration changes location, not content. Adding
    // a history checkpoint here could evict an older password or exclusive
    // historical asset when imported retention limits are already full.
    let mut entry = s.db.entry_mut(entry).ok_or(CoreError::InvalidOperation)?;
    entry
        .move_to(destination)
        .map_err(|_| CoreError::InvalidOperation)?;
    entry.times.location_changed = Some(Times::now());
    Ok(())
}
