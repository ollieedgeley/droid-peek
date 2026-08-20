//! Validated, private configuration for optional scrcpy launch arguments.

use std::{
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
};

use serde::{Deserialize, Serialize};

use crate::private_fs::{atomic_replace, ensure_private_directory, remove_file_if_present};

const SNAPSHOT_NAME: &str = "scrcpy-args.json";
const MAX_ARGUMENTS: usize = 32;
const MAX_ARGUMENT_BYTES: usize = 512;
const MAX_TOTAL_BYTES: usize = MAX_ARGUMENTS * MAX_ARGUMENT_BYTES;
const RESERVED_ARGUMENTS: &[&str] = &[
    "--serial",
    "--select-usb",
    "--select-tcpip",
    "--tcpip",
    "--video-source",
    "--new-display",
    "--display",
    "--v4l2-sink",
    "--no-video",
    "--no-window",
    "--window",
    "--control",
    "--no-control",
    "--no-cleanup",
    "--no-power-on",
    "--max-size",
    "--video-bit-rate",
    "--max-fps",
];
pub fn decode_arguments_envelope(encoded: &str) -> io::Result<Vec<String>> {
    if encoded.is_empty() || encoded.len() > MAX_TOTAL_BYTES * 2 || encoded.len() % 4 == 1 {
        return Err(invalid_snapshot("invalid scrcpy argument envelope"));
    }
    let mut decoded = Vec::with_capacity(encoded.len() * 3 / 4);
    let mut buffer = 0_u32;
    let mut buffered_bits = 0_u8;
    for byte in encoded.bytes() {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'-' => 62,
            b'_' => 63,
            _ => return Err(invalid_snapshot("invalid scrcpy argument envelope")),
        };
        buffer = (buffer << 6) | u32::from(value);
        buffered_bits += 6;
        if buffered_bits >= 8 {
            buffered_bits -= 8;
            decoded.push((buffer >> buffered_bits) as u8);
            buffer &= (1_u32 << buffered_bits) - 1;
        }
    }
    if buffer != 0 {
        return Err(invalid_snapshot("non-canonical scrcpy argument envelope"));
    }
    serde_json::from_slice::<Vec<String>>(&decoded).map_err(invalid_snapshot)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ScrcpyConfigError {
    TooManyArguments,
    TooManyBytes,
    InvalidArgument,
    ReservedArgument,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ScrcpyConfiguration {
    arguments: Vec<String>,
    revision: String,
    screen_off_requested: bool,
}

impl ScrcpyConfiguration {
    pub fn validated(arguments: Vec<String>) -> Result<Self, ScrcpyConfigError> {
        if arguments.len() > MAX_ARGUMENTS {
            return Err(ScrcpyConfigError::TooManyArguments);
        }
        let total_bytes = arguments.iter().map(String::len).sum::<usize>();
        if total_bytes > MAX_TOTAL_BYTES {
            return Err(ScrcpyConfigError::TooManyBytes);
        }
        for argument in &arguments {
            if argument.len() < 3
                || argument.len() > MAX_ARGUMENT_BYTES
                || !argument.starts_with("--")
                || argument
                    .bytes()
                    .any(|byte| matches!(byte, 0 | b'\n' | b'\r'))
            {
                return Err(ScrcpyConfigError::InvalidArgument);
            }
            let name = argument
                .split_once('=')
                .map_or(argument.as_str(), |(name, _)| name);
            if RESERVED_ARGUMENTS.contains(&name) || name.starts_with("--audio") {
                return Err(ScrcpyConfigError::ReservedArgument);
            }
        }
        let revision = revision_for(&arguments);
        let screen_off_requested = arguments
            .iter()
            .any(|argument| argument == "--turn-screen-off");
        Ok(Self {
            arguments,
            revision,
            screen_off_requested,
        })
    }

    #[must_use]
    pub fn empty() -> Self {
        Self::validated(Vec::new()).unwrap_or_else(|_| unreachable!("empty configuration is valid"))
    }

    #[must_use]
    pub fn arguments(&self) -> &[String] {
        &self.arguments
    }

    #[must_use]
    pub fn revision(&self) -> &str {
        &self.revision
    }

    #[must_use]
    pub const fn screen_off_requested(&self) -> bool {
        self.screen_off_requested
    }

    #[must_use]
    pub fn effective_arguments(&self, screen_off_enabled: bool) -> Vec<String> {
        self.arguments
            .iter()
            .filter(|argument| screen_off_enabled || argument.as_str() != "--turn-screen-off")
            .cloned()
            .collect()
    }
}

impl Default for ScrcpyConfiguration {
    fn default() -> Self {
        Self::empty()
    }
}

fn revision_for(arguments: &[String]) -> String {
    // FNV-1a is sufficient here: the revision is an identity token, not an
    // authentication primitive. Length delimiters prevent concatenation aliases.
    let mut hash = 0xcbf29ce484222325_u64;
    for argument in arguments {
        for byte in argument
            .len()
            .to_le_bytes()
            .iter()
            .chain(argument.as_bytes())
        {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x100000001b3);
        }
    }
    format!("{hash:016x}")
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Snapshot {
    arguments: Vec<String>,
    revision: String,
}

pub struct FileScrcpyConfigStore {
    path: PathBuf,
}

impl FileScrcpyConfigStore {
    #[must_use]
    pub fn new(state_directory: impl AsRef<Path>) -> Self {
        Self {
            path: state_directory.as_ref().join(SNAPSHOT_NAME),
        }
    }

    pub fn load(&self) -> io::Result<ScrcpyConfiguration> {
        let file = match fs::File::open(&self.path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(ScrcpyConfiguration::empty());
            }
            Err(error) => return Err(error),
        };
        let mut serialized = String::new();
        match file
            .take((MAX_TOTAL_BYTES * 2) as u64)
            .read_to_string(&mut serialized)
        {
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::InvalidData => {
                remove_file_if_present(&self.path)?;
                return Ok(ScrcpyConfiguration::empty());
            }
            Err(error) => return Err(error),
        }
        if let Some(configuration) = configuration_from_snapshot(&serialized) {
            return Ok(configuration);
        }
        remove_file_if_present(&self.path)?;
        Ok(ScrcpyConfiguration::empty())
    }

    pub fn store(&self, configuration: &ScrcpyConfiguration) -> io::Result<()> {
        let directory = self.path.parent().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "scrcpy snapshot has no parent")
        })?;
        ensure_private_directory(directory)?;
        if configuration.arguments.is_empty() {
            return remove_file_if_present(&self.path);
        }
        let serialized = serde_json::to_vec(&Snapshot {
            arguments: configuration.arguments.clone(),
            revision: configuration.revision.clone(),
        })
        .map_err(io::Error::other)?;
        atomic_replace(&self.path, |file| file.write_all(&serialized))
    }
}

fn configuration_from_snapshot(serialized: &str) -> Option<ScrcpyConfiguration> {
    let snapshot: Snapshot = serde_json::from_str(serialized).ok()?;
    let configuration = ScrcpyConfiguration::validated(snapshot.arguments).ok()?;
    (configuration.revision == snapshot.revision).then_some(configuration)
}

fn invalid_snapshot(error: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error.to_string())
}
