use std::{
    fs::{self, File},
    io::{self, Write},
    os::unix::fs::PermissionsExt,
    path::Path,
};

pub fn ensure_private_directory(path: &Path) -> io::Result<()> {
    fs::create_dir_all(path)?;
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "private path is not a directory",
        ));
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
}

pub(crate) fn remove_file_if_present(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn temporary_file(directory: &Path) -> io::Result<tempfile::NamedTempFile> {
    ensure_private_directory(directory)?;
    let temporary = tempfile::Builder::new()
        .prefix(".omarchy-android-")
        .tempfile_in(directory)?;
    temporary
        .as_file()
        .set_permissions(fs::Permissions::from_mode(0o600))?;
    Ok(temporary)
}

pub fn atomic_replace(
    path: &Path,
    write: impl FnOnce(&mut File) -> io::Result<()>,
) -> io::Result<()> {
    let directory = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "private file has no parent"))?;
    let mut temporary = temporary_file(directory)?;
    write(temporary.as_file_mut())?;
    temporary.as_file_mut().flush()?;
    temporary.as_file().sync_all()?;
    temporary.persist(path).map_err(|error| error.error)?;
    File::open(directory)?.sync_all()
}

pub fn create_private_file(path: &Path) -> io::Result<File> {
    let directory = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "private file has no parent"))?;
    let file = temporary_file(directory)?
        .persist(path)
        .map_err(|error| error.error)?;
    File::open(directory)?.sync_all()?;
    Ok(file)
}

#[cfg(test)]
mod tests {
    use std::{fs, io::Write, os::unix::fs::symlink};

    use super::{atomic_replace, create_private_file, ensure_private_directory};

    #[test]
    fn private_directory_rejects_a_symlink() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let target = directory.path().join("target");
        fs::create_dir(&target).expect("target directory");
        let private = directory.path().join("private");
        symlink(&target, &private).expect("directory symlink");

        assert_eq!(
            ensure_private_directory(&private)
                .expect_err("symlink must be rejected")
                .kind(),
            std::io::ErrorKind::InvalidData
        );
    }

    #[test]
    fn private_file_replacement_never_follows_an_existing_symlink() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let victim = directory.path().join("victim");
        fs::write(&victim, "untouched").expect("victim file");
        let destination = directory.path().join("private");
        symlink(&victim, &destination).expect("file symlink");

        atomic_replace(&destination, |file| file.write_all(b"replacement"))
            .expect("atomic replacement");
        assert_eq!(
            fs::read_to_string(&victim).expect("victim contents"),
            "untouched"
        );
        assert_eq!(
            fs::read_to_string(&destination).expect("replacement contents"),
            "replacement"
        );

        let mut file = create_private_file(&destination).expect("private file");
        file.write_all(b"new").expect("write private file");
        drop(file);
        assert_eq!(
            fs::read_to_string(&victim).expect("victim contents"),
            "untouched"
        );
        assert_eq!(
            fs::read_to_string(&destination).expect("private contents"),
            "new"
        );
    }
}
