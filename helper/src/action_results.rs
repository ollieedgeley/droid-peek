use crate::private_fs::ensure_private_directory;
use std::{
    fs::{self, OpenOptions},
    io::{self, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
};

const RESULT_DIRECTORY: &str = "action-results";
const MAX_REQUEST_ID_LENGTH: usize = 64;

#[derive(Debug)]
pub struct ActionResultStore {
    directory: PathBuf,
}

impl ActionResultStore {
    pub fn new(runtime_directory: impl AsRef<Path>) -> io::Result<Self> {
        let runtime_directory = runtime_directory.as_ref();
        ensure_private_directory(runtime_directory)?;
        let directory = runtime_directory.join(RESULT_DIRECTORY);
        ensure_private_directory(&directory)?;

        for entry in fs::read_dir(&directory)? {
            let entry = entry?;
            let file_type = entry.file_type()?;
            if file_type.is_file() || file_type.is_symlink() {
                fs::remove_file(entry.path())?;
            } else {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "action result directory contains a non-file entry",
                ));
            }
        }

        Ok(Self { directory })
    }

    pub fn publish(&self, request_id: &str, handled: bool) -> io::Result<()> {
        validate_request_id(request_id)?;

        let result_path = self.directory.join(request_id);
        if result_path.exists() {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "action result already exists",
            ));
        }

        let temporary_path = self.directory.join(format!(".{request_id}.tmp"));
        let publish = (|| {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temporary_path)?;
            file.write_all(if handled { b"true\n" } else { b"false\n" })?;
            file.sync_data()?;
            fs::rename(&temporary_path, &result_path)
        })();

        if publish.is_err() {
            let _ = fs::remove_file(&temporary_path);
        }
        publish
    }
}

pub fn validate_request_id(request_id: &str) -> io::Result<()> {
    if request_id.is_empty()
        || request_id.len() > MAX_REQUEST_ID_LENGTH
        || !request_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid action request id",
        ));
    }
    Ok(())
}
