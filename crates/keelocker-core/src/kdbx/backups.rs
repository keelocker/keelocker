//! Immutable encrypted recovery copies. Names contain only a timestamp and digests.
use crate::{kdbx::io::digest, CoreError};
use std::{
    fs,
    path::{Component, Path, PathBuf},
};

/// Resolve existing ancestors once without creating anything. The configured root
/// itself is owned by KeeLocker and must never be a symlink.
pub(crate) fn configured_root(path: &Path) -> Result<PathBuf, CoreError> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map_err(|_| CoreError::WriteFailed)?
            .join(path)
    };
    if absolute
        .components()
        .any(|c| matches!(c, Component::ParentDir))
    {
        return Err(CoreError::WriteFailed);
    }
    let name = absolute.file_name().ok_or(CoreError::WriteFailed)?;
    match fs::symlink_metadata(&absolute) {
        Ok(metadata) if !metadata.file_type().is_dir() => return Err(CoreError::WriteFailed),
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
            return Err(CoreError::WriteFailed)
        }
        _ => {}
    }
    let mut parent = absolute.parent().ok_or(CoreError::WriteFailed)?;
    let mut missing = Vec::new();
    loop {
        match parent.canonicalize() {
            Ok(mut resolved) => {
                for component in missing.iter().rev() {
                    resolved.push(component);
                }
                return Ok(resolved.join(name));
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                // A dangling symlink is not a missing directory.
                if fs::symlink_metadata(parent).is_ok() {
                    return Err(CoreError::WriteFailed);
                }
                missing.push(
                    parent
                        .file_name()
                        .ok_or(CoreError::WriteFailed)?
                        .to_os_string(),
                );
                parent = parent.parent().ok_or(CoreError::WriteFailed)?;
            }
            Err(_) => return Err(CoreError::WriteFailed),
        }
    }
}

#[cfg(unix)]
pub(crate) use unix::{list, read, recovery_identity, write_copy, BackupSet};

#[cfg(unix)]
mod unix {
    use super::*;
    use chrono::Utc;
    use sha2::{Digest, Sha256};
    use std::{
        collections::HashSet,
        ffi::{CStr, CString, OsStr},
        fs::File,
        io::{self, Read, Write},
        os::{
            fd::{AsRawFd, FromRawFd},
            unix::{ffi::OsStrExt, fs::MetadataExt},
        },
    };

    const PREFIX: &str = "snapshot-v1-";
    const SUFFIX: &str = ".kdbx";
    const DAY_MICROS: u64 = 86_400_000_000;

    fn invalid() -> io::Error {
        io::Error::other("Unsafe backup namespace")
    }

    fn c_name(name: &OsStr) -> io::Result<CString> {
        CString::new(name.as_bytes()).map_err(|_| invalid())
    }

    fn cvt(value: libc::c_int) -> io::Result<libc::c_int> {
        if value == -1 {
            Err(io::Error::last_os_error())
        } else {
            Ok(value)
        }
    }

    struct Directory(File);

    impl Directory {
        // Recovery must never call the creating/chmodding save path below.
        fn existing_path(path: &Path) -> io::Result<Self> {
            if !path.is_absolute() {
                return Err(invalid());
            }
            let mut directory = Self(File::open("/")?);
            for part in path.components() {
                match part {
                    Component::RootDir => {}
                    Component::Normal(name) => directory = directory.existing_child(name)?,
                    _ => return Err(invalid()),
                }
            }
            Ok(directory)
        }

        fn existing_child(&self, name: &OsStr) -> io::Result<Self> {
            let name = c_name(name)?;
            // SAFETY: the live directory/name anchor every lookup. No symlink
            // traversal, directory creation or permission changes are allowed.
            let fd = cvt(unsafe {
                libc::openat(
                    self.0.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            })?;
            // SAFETY: openat transferred ownership of a fresh descriptor.
            Ok(Self(unsafe { File::from_raw_fd(fd) }))
        }

        fn check_private(&self) -> io::Result<()> {
            check_private(&self.0.metadata()?)
        }

        fn open_path(path: &Path) -> io::Result<Self> {
            if !path.is_absolute() {
                return Err(invalid());
            }
            let mut directory = Self(File::open("/")?);
            for part in path.components() {
                match part {
                    Component::RootDir => {}
                    Component::Normal(name) => directory = directory.child(name)?,
                    _ => return Err(invalid()),
                }
            }
            directory.private()?;
            Ok(directory)
        }

        fn child(&self, name: &OsStr) -> io::Result<Self> {
            let name = c_name(name)?;
            // SAFETY: the directory fd and NUL-terminated child name remain live;
            // O_NOFOLLOW rejects symlinks, including concurrent replacements.
            let mut fd = unsafe {
                libc::openat(
                    self.0.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            if fd == -1 && io::Error::last_os_error().kind() == io::ErrorKind::NotFound {
                // SAFETY: same live directory/name; mkdirat creates only this child.
                let created = unsafe { libc::mkdirat(self.0.as_raw_fd(), name.as_ptr(), 0o700) };
                if created == -1
                    && io::Error::last_os_error().kind() != io::ErrorKind::AlreadyExists
                {
                    return Err(io::Error::last_os_error());
                }
                // SAFETY: as above; never follow a symlink installed after mkdirat.
                fd = unsafe {
                    libc::openat(
                        self.0.as_raw_fd(),
                        name.as_ptr(),
                        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                    )
                };
                let child = cvt(fd)?;
                // SAFETY: successful openat transferred ownership of a fresh fd.
                let directory = Self(unsafe { File::from_raw_fd(child) });
                directory.private()?;
                self.sync()?;
                return Ok(directory);
            }
            let fd = cvt(fd)?;
            // SAFETY: successful openat transferred ownership of a fresh fd.
            Ok(Self(unsafe { File::from_raw_fd(fd) }))
        }

        fn private(&self) -> io::Result<()> {
            // SAFETY: fchmod operates on this owned directory descriptor.
            cvt(unsafe { libc::fchmod(self.0.as_raw_fd(), 0o700) }).map(|_| ())
        }

        fn sync(&self) -> io::Result<()> {
            self.0.sync_all()
        }

        fn regular(&self, name: &str) -> io::Result<File> {
            let name = c_name(OsStr::new(name))?;
            // SAFETY: the fd/name remain live. NONBLOCK prevents a foreign FIFO
            // from blocking before we reject anything other than a regular file.
            let fd = cvt(unsafe {
                libc::openat(
                    self.0.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
                )
            })?;
            // SAFETY: successful openat transferred ownership of a fresh fd.
            let file = unsafe { File::from_raw_fd(fd) };
            let metadata = file.metadata()?;
            if !metadata.is_file() || metadata.nlink() != 1 {
                return Err(invalid());
            }
            Ok(file)
        }

        fn names(&self) -> io::Result<Vec<String>> {
            self.names_bounded(usize::MAX)
        }

        fn names_bounded(&self, limit: usize) -> io::Result<Vec<String>> {
            let dot = c".";
            // SAFETY: opening "." gives the iterator its own directory offset.
            let fd = cvt(unsafe {
                libc::openat(
                    self.0.as_raw_fd(),
                    dot.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            })?;
            // SAFETY: fd is a newly opened directory fd. fdopendir takes ownership on success.
            let stream = unsafe { libc::fdopendir(fd) };
            if stream.is_null() {
                let error = io::Error::last_os_error();
                // SAFETY: fdopendir failed, leaving fd owned here.
                unsafe {
                    libc::close(fd);
                }
                return Err(error);
            }
            struct Entries(*mut libc::DIR);
            impl Drop for Entries {
                fn drop(&mut self) {
                    // SAFETY: this guard uniquely owns the live directory stream.
                    unsafe {
                        libc::closedir(self.0);
                    }
                }
            }
            let entries = Entries(stream);
            let mut names = Vec::new();
            let mut scanned = 0;
            loop {
                set_errno(0);
                // SAFETY: entries owns a live stream; each returned name is copied
                // before the next readdir invalidates its storage.
                let entry = unsafe { libc::readdir(entries.0) };
                if entry.is_null() {
                    if errno() != 0 {
                        return Err(io::Error::last_os_error());
                    }
                    return Ok(names);
                }
                // SAFETY: readdir returns a NUL-terminated d_name.
                let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
                if scanned == limit {
                    return Err(invalid());
                }
                scanned += 1;
                if let Ok(name) = name.to_str() {
                    names.push(name.to_owned());
                }
            }
        }

        fn publish(&self, name: &str, bytes: &[u8], expected: Option<[u8; 32]>) -> io::Result<()> {
            match self.regular(name) {
                Ok(file) => return verify_existing(file, expected),
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
            let temp_name = c_name(OsStr::new(&format!(
                ".keelocker-tmp-{}",
                uuid::Uuid::new_v4()
            )))?;
            // SAFETY: create a fresh private file relative to our anchored directory.
            let fd = cvt(unsafe {
                libc::openat(
                    self.0.as_raw_fd(),
                    temp_name.as_ptr(),
                    libc::O_WRONLY
                        | libc::O_CREAT
                        | libc::O_EXCL
                        | libc::O_NOFOLLOW
                        | libc::O_CLOEXEC,
                    0o600,
                )
            })?;
            struct Pending<'a> {
                directory: &'a Directory,
                name: CString,
                file: File,
            }
            impl Drop for Pending<'_> {
                fn drop(&mut self) {
                    // SAFETY: unlink only this temporary child, without following it.
                    unsafe {
                        libc::unlinkat(self.directory.0.as_raw_fd(), self.name.as_ptr(), 0);
                    }
                }
            }
            let mut pending = Pending {
                directory: self,
                name: temp_name,
                // SAFETY: successful openat transferred ownership of a fresh fd.
                file: unsafe { File::from_raw_fd(fd) },
            };
            #[cfg(test)]
            let checkpoint_path = super::super::io::descriptor_path(&self.0)?
                .join(OsStr::from_bytes(pending.name.as_bytes()));
            #[cfg(test)]
            super::super::io::save_faults::checkpoint(
                super::super::io::save_faults::Stage::BackupWrite,
                &checkpoint_path,
            )?;
            pending.file.write_all(bytes)?;
            #[cfg(test)]
            super::super::io::save_faults::checkpoint(
                super::super::io::save_faults::Stage::BackupSync,
                &checkpoint_path,
            )?;
            pending.file.sync_all()?;
            #[cfg(test)]
            super::super::io::save_faults::checkpoint(
                super::super::io::save_faults::Stage::BackupPublish,
                &checkpoint_path,
            )?;
            let destination = c_name(OsStr::new(name))?;
            // Rename without replacement publishes one link atomically. Using
            // linkat/unlinkat would strand a second link after a process crash,
            // making our foreign-hard-link guard reject the recovery file.
            #[cfg(target_vendor = "apple")]
            // SAFETY: both descriptors/names remain live and RENAME_EXCL refuses
            // every existing destination, including symlinks.
            let published = unsafe {
                libc::renameatx_np(
                    self.0.as_raw_fd(),
                    pending.name.as_ptr(),
                    self.0.as_raw_fd(),
                    destination.as_ptr(),
                    libc::RENAME_EXCL,
                )
            };
            #[cfg(target_os = "linux")]
            // SAFETY: as above; RENAME_NOREPLACE refuses existing destinations.
            let published = unsafe {
                libc::renameat2(
                    self.0.as_raw_fd(),
                    pending.name.as_ptr(),
                    self.0.as_raw_fd(),
                    destination.as_ptr(),
                    libc::RENAME_NOREPLACE,
                )
            };
            #[cfg(not(any(target_vendor = "apple", target_os = "linux")))]
            let published = return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "Atomic backup publication requires Apple or Linux support",
            ));
            if published == -1 {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::AlreadyExists {
                    return Err(error);
                }
                verify_existing(self.regular(name)?, expected)?;
            }
            #[cfg(test)]
            super::super::io::save_faults::checkpoint(
                super::super::io::save_faults::Stage::BackupPublished,
                &checkpoint_path,
            )?;
            drop(pending);
            Ok(())
        }

        fn snapshot_file(&self, snapshot: &Snapshot) -> io::Result<File> {
            let mut file = self.regular(&snapshot.name)?;
            if hex(&bounded_digest(&mut file)?) != snapshot.hash {
                return Err(invalid());
            }
            Ok(file)
        }

        #[allow(clippy::unnecessary_cast)] // stat field widths differ on Apple and Linux.
        fn remove_snapshot(&self, snapshot: &Snapshot) -> io::Result<()> {
            // Never remove a foreign, corrupt, nonregular or symlink entry.
            let file = self.snapshot_file(snapshot)?;
            let metadata = file.metadata()?;
            let name = c_name(OsStr::new(&snapshot.name))?;
            let mut current = std::mem::MaybeUninit::<libc::stat>::uninit();
            // SAFETY: fstatat initializes current on success and does not follow links.
            cvt(unsafe {
                libc::fstatat(
                    self.0.as_raw_fd(),
                    name.as_ptr(),
                    current.as_mut_ptr(),
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            })?;
            // SAFETY: fstatat succeeded above.
            let current = unsafe { current.assume_init() };
            if current.st_mode & libc::S_IFMT != libc::S_IFREG
                || current.st_dev as u64 != metadata.dev()
                || current.st_ino as u64 != metadata.ino()
            {
                return Err(invalid());
            }
            // SAFETY: unlinkat removes only this child, never its target.
            cvt(unsafe { libc::unlinkat(self.0.as_raw_fd(), name.as_ptr(), 0) }).map(|_| ())
        }
    }

    fn check_private(metadata: &fs::Metadata) -> io::Result<()> {
        // SAFETY: geteuid has no preconditions and does not change process state.
        if metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o077 != 0 {
            return Err(invalid());
        }
        Ok(())
    }

    /// Recovery callers supply a captured canonical identity, never an alias to
    /// resolve again after another client may have replaced the source path.
    pub(crate) fn recovery_identity(path: &Path) -> Result<PathBuf, CoreError> {
        let absolute = if path.is_absolute() {
            path.to_path_buf()
        } else {
            std::env::current_dir()
                .map_err(|_| CoreError::ReadFailed)?
                .join(path)
        };
        if absolute
            .components()
            .any(|part| matches!(part, Component::ParentDir))
        {
            return Err(CoreError::ReadFailed);
        }
        let absolute: PathBuf = absolute.components().collect();
        absolute.file_name().ok_or(CoreError::ReadFailed)?;
        let mut ancestor = absolute.parent().ok_or(CoreError::ReadFailed)?;
        loop {
            match Directory::existing_path(ancestor) {
                Ok(directory) => {
                    if super::super::io::descriptor_path(&directory.0)
                        .map_err(|_| CoreError::ReadFailed)?
                        != ancestor
                    {
                        return Err(CoreError::ReadFailed);
                    }
                    break;
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    ancestor = ancestor.parent().ok_or(CoreError::ReadFailed)?;
                }
                Err(_) => return Err(CoreError::ReadFailed),
            }
        }
        match fs::symlink_metadata(&absolute) {
            Ok(metadata) if !metadata.file_type().is_file() => return Err(CoreError::ReadFailed),
            Err(error) if error.kind() != io::ErrorKind::NotFound => {
                return Err(CoreError::ReadFailed)
            }
            _ => {}
        }
        Ok(absolute)
    }

    fn recovery_namespace(path: &Path, root: Option<&Path>) -> io::Result<Directory> {
        let fallback = path
            .parent()
            .ok_or_else(invalid)?
            .join(".keelocker-backups");
        let root = Directory::existing_path(root.unwrap_or(&fallback))?;
        root.check_private()?;
        let namespace =
            root.existing_child(OsStr::new(&hex(&digest(path.as_os_str().as_bytes()))))?;
        namespace.check_private()?;
        Ok(namespace)
    }

    fn recovery_file(namespace: &Directory, id: &str) -> Result<File, CoreError> {
        let file = namespace.regular(id).map_err(|_| CoreError::ReadFailed)?;
        let metadata = file.metadata().map_err(|_| CoreError::ReadFailed)?;
        check_private(&metadata).map_err(|_| CoreError::ReadFailed)?;
        if metadata.len() > super::super::resource_limits::MAX_FILE_BYTES as u64 {
            return Err(CoreError::UnsupportedDatabase);
        }
        Ok(file)
    }

    /// Listing authenticates generation digests but never decrypts a vault.
    /// Unrecognized, unsafe and corrupt children are excluded without mutation.
    pub(crate) fn list(
        path: &Path,
        root: Option<&Path>,
    ) -> Result<Vec<crate::CoreBackup>, CoreError> {
        let namespace = match recovery_namespace(path, root) {
            Ok(namespace) => namespace,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(_) => return Err(CoreError::ReadFailed),
        };
        let mut backups = Vec::new();
        for id in namespace
            .names_bounded(4096)
            .map_err(|_| CoreError::ReadFailed)?
        {
            let snapshot = Snapshot::parse(id.clone());
            let is_original = id == "original.kdbx";
            if !is_original && snapshot.is_none() {
                continue;
            }
            let Ok(mut file) = recovery_file(&namespace, &id) else {
                continue;
            };
            let Ok(hash) = bounded_digest(&mut file) else {
                continue;
            };
            if let Some(snapshot) = &snapshot {
                if hex(&hash) != snapshot.hash {
                    continue;
                }
            }
            let Ok(metadata) = file.metadata() else {
                continue;
            };
            if metadata.nlink() != 1 || check_private(&metadata).is_err() {
                continue;
            }
            let created_at = snapshot.map(|s| (s.micros / 1_000_000) as i64).or_else(|| {
                metadata
                    .created()
                    .ok()
                    .map(|time| chrono::DateTime::<Utc>::from(time).timestamp())
            });
            let id = if is_original {
                format!("original:{}", hex(&hash))
            } else {
                id
            };
            backups.push(crate::CoreBackup {
                id,
                created_at,
                size: metadata.len(),
                is_original,
            });
        }
        backups.sort_by(|a, b| {
            a.is_original
                .cmp(&b.is_original)
                .then_with(|| b.created_at.cmp(&a.created_at))
                .then_with(|| a.id.cmp(&b.id))
        });
        Ok(backups)
    }

    fn bounded_digest(file: &mut File) -> io::Result<[u8; 32]> {
        let limit = super::super::resource_limits::MAX_FILE_BYTES as u64;
        if file.metadata()?.len() > limit {
            return Err(invalid());
        }
        let mut bounded = file.take(limit + 1);
        let mut hash = Sha256::new();
        let mut buffer = [0u8; 64 * 1024];
        let mut size = 0;
        loop {
            let count = bounded.read(&mut buffer)?;
            if count == 0 {
                return Ok(hash.finalize().into());
            }
            size += count as u64;
            if size > limit {
                return Err(invalid());
            }
            hash.update(&buffer[..count]);
        }
    }

    pub(crate) fn read(path: &Path, root: Option<&Path>, id: &str) -> Result<Vec<u8>, CoreError> {
        let snapshot = Snapshot::parse(id.to_owned());
        let original_hash = id.strip_prefix("original:").filter(|hash| {
            hash.len() == 64
                && hash
                    .bytes()
                    .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
        });
        if original_hash.is_none() && snapshot.is_none() {
            return Err(CoreError::InvalidOperation);
        }
        let namespace = recovery_namespace(path, root).map_err(|_| CoreError::ReadFailed)?;
        let mut file = recovery_file(
            &namespace,
            if original_hash.is_some() {
                "original.kdbx"
            } else {
                id
            },
        )?;
        let limit = super::super::resource_limits::MAX_FILE_BYTES as u64;
        let mut bytes = Vec::new();
        (&mut file)
            .take(limit + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| CoreError::ReadFailed)?;
        if bytes.len() as u64 > limit {
            return Err(CoreError::UnsupportedDatabase);
        }
        let metadata = file.metadata().map_err(|_| CoreError::ReadFailed)?;
        if metadata.nlink() != 1 || check_private(&metadata).is_err() {
            return Err(CoreError::ReadFailed);
        }
        let expected = original_hash.or_else(|| snapshot.as_ref().map(|s| s.hash.as_str()));
        if expected.is_some_and(|expected| hex(&digest(&bytes)) != expected) {
            return Err(CoreError::CorruptedDatabase);
        }
        Ok(bytes)
    }

    /// Sibling temporary file plus exclusive rename, all relative to one opened
    /// parent directory. Errors before publication remove only our private temp.
    pub(crate) fn write_copy(path: &Path, bytes: &[u8]) -> Result<(PathBuf, bool), CoreError> {
        let parent = path.parent().ok_or(CoreError::WriteFailed)?;
        let directory = Directory::existing_path(parent).map_err(|_| CoreError::WriteFailed)?;
        let destination = c_name(path.file_name().ok_or(CoreError::WriteFailed)?)
            .map_err(|_| CoreError::WriteFailed)?;
        let temporary = c_name(OsStr::new(&format!(
            ".keelocker-recovery-{}",
            uuid::Uuid::new_v4()
        )))
        .map_err(|_| CoreError::WriteFailed)?;
        // SAFETY: the owned parent/name remain live; EXCL creates only our own
        // private file and cannot follow an attacker-provided temporary symlink.
        let fd = cvt(unsafe {
            libc::openat(
                directory.0.as_raw_fd(),
                temporary.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        })
        .map_err(|_| CoreError::WriteFailed)?;
        struct Pending<'a> {
            directory: &'a Directory,
            name: CString,
            file: File,
            published: bool,
        }
        impl Drop for Pending<'_> {
            fn drop(&mut self) {
                if self.published {
                    return;
                }
                // SAFETY: removes only this child, never any symlink target.
                unsafe {
                    libc::unlinkat(self.directory.0.as_raw_fd(), self.name.as_ptr(), 0);
                }
            }
        }
        let mut pending = Pending {
            directory: &directory,
            name: temporary,
            // SAFETY: openat transferred ownership of a fresh descriptor.
            file: unsafe { File::from_raw_fd(fd) },
            published: false,
        };
        #[cfg(test)]
        recovery_checkpoint(RecoveryStage::Write).map_err(|_| CoreError::WriteFailed)?;
        pending
            .file
            .write_all(bytes)
            .map_err(|_| CoreError::WriteFailed)?;
        #[cfg(test)]
        recovery_checkpoint(RecoveryStage::FileSync).map_err(|_| CoreError::WriteFailed)?;
        pending
            .file
            .sync_all()
            .map_err(|_| CoreError::WriteFailed)?;
        if super::super::io::descriptor_path(&directory.0).map_err(|_| CoreError::WriteFailed)?
            != parent
        {
            return Err(CoreError::WriteFailed);
        }
        #[cfg(test)]
        recovery_checkpoint(RecoveryStage::Publish).map_err(|_| CoreError::WriteFailed)?;
        #[cfg(target_vendor = "apple")]
        // SAFETY: both names are anchored to this owned directory; EXCL never
        // replaces a file, directory, symlink or concurrent competing copy.
        let published = unsafe {
            libc::renameatx_np(
                directory.0.as_raw_fd(),
                pending.name.as_ptr(),
                directory.0.as_raw_fd(),
                destination.as_ptr(),
                libc::RENAME_EXCL,
            )
        };
        #[cfg(target_os = "linux")]
        // SAFETY: same live descriptors/names and exclusive publication as above.
        let published = unsafe {
            libc::renameat2(
                directory.0.as_raw_fd(),
                pending.name.as_ptr(),
                directory.0.as_raw_fd(),
                destination.as_ptr(),
                libc::RENAME_NOREPLACE,
            )
        };
        #[cfg(not(any(target_vendor = "apple", target_os = "linux")))]
        let published = return Err(CoreError::WriteFailed);
        if published == -1 {
            return Err(
                if io::Error::last_os_error().kind() == io::ErrorKind::AlreadyExists {
                    CoreError::Conflict
                } else {
                    CoreError::WriteFailed
                },
            );
        }
        // Publication committed. Never return a precommit error from here.
        pending.published = true;
        let committed_parent = super::super::io::descriptor_path(&directory.0).ok();
        let directory_synced =
            directory.sync().is_ok() && committed_parent.as_deref() == Some(parent);
        #[cfg(test)]
        let directory_synced =
            directory_synced && recovery_checkpoint(RecoveryStage::DirectorySync).is_ok();
        let committed_path = committed_parent
            .map(|parent| parent.join(path.file_name().unwrap()))
            .unwrap_or_else(|| path.to_path_buf());
        Ok((committed_path, directory_synced))
    }

    #[cfg(test)]
    #[derive(Clone, Copy, PartialEq, Eq)]
    enum RecoveryStage {
        Write,
        FileSync,
        Publish,
        DirectorySync,
    }

    #[cfg(test)]
    thread_local! {
        static RECOVERY_FAILURE: std::cell::Cell<Option<RecoveryStage>> = const { std::cell::Cell::new(None) };
    }

    #[cfg(test)]
    fn recovery_checkpoint(stage: RecoveryStage) -> io::Result<()> {
        if RECOVERY_FAILURE.with(|failure| failure.get() == Some(stage)) {
            Err(io::Error::from(io::ErrorKind::StorageFull))
        } else {
            Ok(())
        }
    }

    fn verify_existing(mut file: File, expected: Option<[u8; 32]>) -> io::Result<()> {
        if file.metadata()?.nlink() != 1 {
            return Err(invalid());
        }
        if let Some(expected) = expected {
            if bounded_digest(&mut file)? != expected {
                return Err(invalid());
            }
        }
        // SAFETY: descriptor was opened with O_NOFOLLOW and verified regular.
        cvt(unsafe { libc::fchmod(file.as_raw_fd(), 0o600) })?;
        file.sync_all()
    }

    #[cfg(target_vendor = "apple")]
    fn errno() -> i32 {
        unsafe { *libc::__error() }
    }
    #[cfg(target_vendor = "apple")]
    fn set_errno(value: i32) {
        unsafe {
            *libc::__error() = value;
        }
    }
    #[cfg(not(target_vendor = "apple"))]
    fn errno() -> i32 {
        unsafe { *libc::__errno_location() }
    }
    #[cfg(not(target_vendor = "apple"))]
    fn set_errno(value: i32) {
        unsafe {
            *libc::__errno_location() = value;
        }
    }

    fn hex(bytes: &[u8]) -> String {
        use std::fmt::Write;
        let mut result = String::with_capacity(bytes.len() * 2);
        for byte in bytes {
            write!(&mut result, "{byte:02x}").expect("write into String");
        }
        result
    }

    struct Snapshot {
        name: String,
        micros: u64,
        hash: String,
    }

    impl Snapshot {
        fn parse(name: String) -> Option<Self> {
            let body = name.strip_prefix(PREFIX)?.strip_suffix(SUFFIX)?;
            if body.len() != 85
                || body.as_bytes()[20] != b'-'
                || !body.as_bytes()[..20].iter().all(u8::is_ascii_digit)
                || !body.as_bytes()[21..]
                    .iter()
                    .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(c))
            {
                return None;
            }
            let micros = body[..20].parse().ok()?;
            let hash = body[21..].to_owned();
            Some(Self { name, micros, hash })
        }
    }

    pub(crate) struct BackupSet {
        root: Directory,
        namespace: Directory,
        now: u64,
    }

    impl BackupSet {
        pub(crate) fn preserve(
            path: &Path,
            root: Option<&Path>,
            source: &[u8],
        ) -> Result<Self, CoreError> {
            Self::preserve_at(
                path,
                root,
                source,
                Utc::now().timestamp_micros().max(0) as u64,
            )
            .map_err(|_| CoreError::WriteFailed)
        }

        fn preserve_at(
            path: &Path,
            root: Option<&Path>,
            source: &[u8],
            now: u64,
        ) -> io::Result<Self> {
            let fallback = path
                .parent()
                .ok_or_else(invalid)?
                .join(".keelocker-backups");
            let root = Directory::open_path(root.unwrap_or(&fallback))?;
            // Path bytes are hashed, never written to a manifest or a backup filename.
            let namespace = root.child(OsStr::new(&hex(&digest(path.as_os_str().as_bytes()))))?;
            namespace.private()?;
            namespace.publish("original.kdbx", source, None)?;
            let hash = digest(source);
            let hash_hex = hex(&hash);
            let mut duplicate = false;
            // Only reuse the most recent generation, and only within its day.
            // Reaccepting any earlier revision needs a fresh timestamp so it
            // survives rotation as the source of the current save.
            let latest = namespace
                .names()?
                .into_iter()
                .filter_map(Snapshot::parse)
                .max_by(|a, b| a.micros.cmp(&b.micros).then_with(|| a.name.cmp(&b.name)));
            if let Some(snapshot) = &latest {
                if snapshot.hash == hash_hex && snapshot.micros / DAY_MICROS == now / DAY_MICROS {
                    verify_existing(namespace.regular(&snapshot.name)?, Some(hash))?;
                    duplicate = true;
                }
            }
            if !duplicate {
                // Preserve creation order if the wall clock moves backward.
                // Otherwise a freshly accepted source can sort behind the
                // retention window and disappear in this save's rotation.
                let timestamp = match latest {
                    Some(snapshot) => now.max(snapshot.micros.checked_add(1).ok_or_else(invalid)?),
                    None => now,
                };
                namespace.publish(
                    &format!("{PREFIX}{timestamp:020}-{hash_hex}{SUFFIX}"),
                    source,
                    Some(hash),
                )?;
            }
            #[cfg(test)]
            super::super::io::save_faults::checkpoint(
                super::super::io::save_faults::Stage::BackupDirectorySync,
                &fallback,
            )?;
            namespace.sync()?;
            root.sync()?;
            Ok(Self {
                root,
                namespace,
                now,
            })
        }

        /// Best-effort maintenance only after the vault has committed. A pruning
        /// failure cannot turn that committed write into a pre-commit failure.
        pub(crate) fn prune(&self) {
            let _ = self.prune_checked();
        }

        fn prune_checked(&self) -> io::Result<()> {
            let mut snapshots: Vec<_> = self
                .namespace
                .names()?
                .into_iter()
                .filter_map(Snapshot::parse)
                .filter(|s| self.namespace.snapshot_file(s).is_ok())
                .collect();
            snapshots.sort_by(|a, b| b.micros.cmp(&a.micros).then_with(|| b.name.cmp(&a.name)));
            let today = self.now / DAY_MICROS;
            let mut daily = HashSet::new();
            let mut remove = Vec::new();
            for (index, snapshot) in snapshots.into_iter().enumerate() {
                let day = snapshot.micros / DAY_MICROS;
                let keep_daily =
                    day <= today && day >= today.saturating_sub(29) && daily.insert(day);
                if index >= 20 && !keep_daily {
                    remove.push(snapshot);
                }
            }
            for snapshot in remove {
                // A changed/foreign child stops this rotation conservatively.
                self.namespace.remove_snapshot(&snapshot)?;
            }
            self.namespace.sync()?;
            self.root.sync()
        }
    }

    #[cfg(test)]
    mod recovery_fault_tests {
        use super::*;

        #[test]
        fn clock_rollback_keeps_each_new_source_among_latest_generations() {
            let directory = tempfile::tempdir().unwrap();
            let root = directory.path().canonicalize().unwrap();
            let source = root.join("source.kdbx");
            let backup_root = root.join("backups");
            let now = 100 * DAY_MICROS;
            let original = encrypted();
            BackupSet::preserve_at(&source, Some(&backup_root), &original, now).unwrap();
            for index in 1..=25 {
                BackupSet::preserve_at(&source, Some(&backup_root), &encrypted(), now + index)
                    .unwrap()
                    .prune_checked()
                    .unwrap();
            }
            let accepted = encrypted();
            let saved =
                BackupSet::preserve_at(&source, Some(&backup_root), &accepted, now).unwrap();
            saved.prune_checked().unwrap();
            assert!(
                saved
                    .namespace
                    .names()
                    .unwrap()
                    .into_iter()
                    .filter_map(Snapshot::parse)
                    .any(|snapshot| snapshot.hash == hex(&digest(&accepted))),
                "A backward clock must not immediately discard the accepted source"
            );
            let next =
                BackupSet::preserve_at(&source, Some(&backup_root), &encrypted(), now).unwrap();
            next.prune_checked().unwrap();
            assert!(next
                .namespace
                .names()
                .unwrap()
                .into_iter()
                .filter_map(Snapshot::parse)
                .any(|snapshot| snapshot.hash == hex(&digest(&accepted))));
        }

        #[test]
        fn oversized_generations_are_rejected_by_rotation_and_dedup_verification() {
            let temp = tempfile::tempdir().unwrap();
            let path = temp.path().canonicalize().unwrap();
            let directory = Directory::open_path(&path).unwrap();
            let size = super::super::super::resource_limits::MAX_FILE_BYTES + 1;
            let buffer = [0u8; 64 * 1024];
            let mut hash = Sha256::new();
            for _ in 0..size / buffer.len() {
                hash.update(buffer);
            }
            hash.update(&buffer[..size % buffer.len()]);
            let hash: [u8; 32] = hash.finalize().into();
            let name = format!("{PREFIX}{:020}-{}{SUFFIX}", 1, hex(&hash));
            let file = File::create(path.join(&name)).unwrap();
            file.set_len(size as u64).unwrap();
            let snapshot = Snapshot::parse(name.clone()).unwrap();
            assert!(
                directory.snapshot_file(&snapshot).is_err(),
                "Rotation must reject oversized data before hashing it"
            );
            assert!(
                verify_existing(directory.regular(&name).unwrap(), Some(hash)).is_err(),
                "Dedup verification must use the same bounded path"
            );
        }

        fn failing<T>(stage: RecoveryStage, action: impl FnOnce() -> T) -> T {
            struct Reset(Option<RecoveryStage>);
            impl Drop for Reset {
                fn drop(&mut self) {
                    RECOVERY_FAILURE.with(|failure| failure.set(self.0));
                }
            }
            let _reset = Reset(RECOVERY_FAILURE.with(|failure| failure.replace(Some(stage))));
            action()
        }

        fn encrypted() -> Vec<u8> {
            let mut db = keepass::Database::new();
            db.config.kdf_config = keepass::config::KdfConfig::Aes { rounds: 10 };
            let mut bytes = Vec::new();
            db.save(
                &mut bytes,
                keepass::DatabaseKey::new().with_password("synthetic-password"),
            )
            .unwrap();
            bytes
        }

        #[test]
        fn recovery_precommit_failures_remove_temporary_and_preserve_source() {
            for stage in [
                RecoveryStage::Write,
                RecoveryStage::FileSync,
                RecoveryStage::Publish,
            ] {
                let directory = tempfile::tempdir().unwrap();
                let root = directory.path().canonicalize().unwrap();
                let bytes = encrypted();
                let source = root.join("source.kdbx");
                let destination = root.join("copy.kdbx");
                fs::write(&source, &bytes).unwrap();
                assert_eq!(
                    failing(stage, || write_copy(&destination, &bytes)),
                    Err(CoreError::WriteFailed)
                );
                assert_eq!(fs::read(&source).unwrap(), bytes);
                assert_eq!(fs::read_dir(&root).unwrap().count(), 1);
            }
        }

        #[test]
        fn recovery_directory_sync_failure_returns_committed_path_and_exact_copy() {
            let directory = tempfile::tempdir().unwrap();
            let destination = directory.path().canonicalize().unwrap().join("copy.kdbx");
            let bytes = encrypted();
            let result = failing(RecoveryStage::DirectorySync, || {
                write_copy(&destination, &bytes)
            })
            .unwrap();
            assert_eq!(result, (destination.clone(), false));
            assert_eq!(fs::read(&destination).unwrap(), bytes);
            assert_eq!(write_copy(&destination, &bytes), Err(CoreError::Conflict));
            assert_eq!(
                fs::read_dir(destination.parent().unwrap()).unwrap().count(),
                1
            );
        }
    }
}

#[cfg(not(unix))]
pub(crate) struct BackupSet;
#[cfg(not(unix))]
pub(crate) fn recovery_identity(_: &Path) -> Result<PathBuf, CoreError> {
    Err(CoreError::ReadFailed)
}
#[cfg(not(unix))]
pub(crate) fn list(_: &Path, _: Option<&Path>) -> Result<Vec<crate::CoreBackup>, CoreError> {
    Err(CoreError::ReadFailed)
}
#[cfg(not(unix))]
pub(crate) fn read(_: &Path, _: Option<&Path>, _: &str) -> Result<Vec<u8>, CoreError> {
    Err(CoreError::ReadFailed)
}
#[cfg(not(unix))]
pub(crate) fn write_copy(_: &Path, _: &[u8]) -> Result<(PathBuf, bool), CoreError> {
    Err(CoreError::WriteFailed)
}
#[cfg(not(unix))]
impl BackupSet {
    pub(crate) fn preserve(_: &Path, _: Option<&Path>, _: &[u8]) -> Result<Self, CoreError> {
        Err(CoreError::WriteFailed)
    }
    pub(crate) fn prune(&self) {}
}
