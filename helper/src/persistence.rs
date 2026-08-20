use std::{
    env, fs,
    io::{self, Write},
    path::{Path, PathBuf},
};

use crate::private_fs::{atomic_replace, remove_file_if_present};
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

    pub fn remove(&self) -> io::Result<()> {
        remove_file_if_present(&self.path())
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
            remove_file_if_present(&path)?;
        }
        Ok(device)
    }

    pub fn save(&self, device: &TrustedDevice) -> io::Result<()> {
        atomic_replace(&self.path(), |temporary| {
            serde_json::to_writer(
                &mut *temporary,
                &StoredTrustedDevice {
                    version: STATE_VERSION,
                    service_name: device.service_name(),
                },
            )
            .map_err(io::Error::other)?;
            temporary.write_all(b"\n")
        })
    }
}

#[must_use]
pub fn default_state_directory() -> Option<PathBuf> {
    env::var_os("XDG_STATE_HOME")
        .filter(|directory| !directory.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            env::var_os("HOME")
                .filter(|directory| !directory.is_empty())
                .map(|home| PathBuf::from(home).join(".local/state"))
        })
        .map(|root| root.join("droid-peek"))
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StoredTrustedDevice<T> {
    version: u8,
    service_name: T,
}
