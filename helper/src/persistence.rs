use std::{
    env, fs,
    fs::OpenOptions,
    io::{self, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

use serde::{Deserialize, Serialize};

const STATE_VERSION: u8 = 1;
const STATE_FILE_NAME: &str = "trusted-device.json";

#[derive(Clone, Eq, PartialEq)]
pub struct TrustedDevice {
    service_name: String,
}

impl TrustedDevice {
    pub fn new(service_name: impl Into<String>) -> Result<Self, InvalidTrustedDevice> {
        let service_name = service_name.into();
        let valid = service_name.starts_with("adb-")
            && service_name.len() <= 255
            && service_name
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'));
        if !valid {
            return Err(InvalidTrustedDevice);
        }
        Ok(Self { service_name })
    }

    #[must_use]
    pub fn service_name(&self) -> &str {
        &self.service_name
    }
}

#[derive(Debug)]
pub struct InvalidTrustedDevice;

#[derive(Clone)]
pub struct FileTrustedDeviceStore {
    directory: PathBuf,
}

impl FileTrustedDeviceStore {
    #[must_use]
    pub fn new(directory: impl AsRef<Path>) -> Self {
        Self {
            directory: directory.as_ref().to_owned(),
        }
    }

    #[must_use]
    pub fn directory(&self) -> &Path {
        &self.directory
    }

    #[must_use]
    pub fn path(&self) -> PathBuf {
        self.directory.join(STATE_FILE_NAME)
    }

    pub fn load(&self) -> io::Result<Option<TrustedDevice>> {
        let path = self.path();
        let contents = match fs::read(&path) {
            Ok(contents) => contents,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        let record = serde_json::from_slice::<StoredTrustedDevice<String>>(&contents).ok();
        let device = record.and_then(|record| {
            (record.version == STATE_VERSION)
                .then(|| TrustedDevice::new(record.service_name).ok())
                .flatten()
        });
        if device.is_none() {
            match fs::remove_file(path) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
        }
        Ok(device)
    }

    pub fn save(&self, device: &TrustedDevice) -> io::Result<()> {
        fs::create_dir_all(&self.directory)?;
        fs::set_permissions(&self.directory, fs::Permissions::from_mode(0o700))?;

        let temporary_path = self.directory.join(".trusted-device.json.tmp");
        let mut temporary = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temporary_path)?;
        temporary.set_permissions(fs::Permissions::from_mode(0o600))?;
        serde_json::to_writer(
            &mut temporary,
            &StoredTrustedDevice {
                version: STATE_VERSION,
                service_name: device.service_name(),
            },
        )
        .map_err(io::Error::other)?;
        temporary.write_all(b"\n")?;
        temporary.sync_all()?;
        fs::rename(temporary_path, self.path())
    }
}

#[must_use]
pub fn default_state_directory() -> Option<PathBuf> {
    env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state")))
        .map(|root| root.join("omarchy-android"))
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StoredTrustedDevice<T> {
    version: u8,
    service_name: T,
}
