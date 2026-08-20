//! Cancellable lifecycle boundary for the unmodified scrcpy client.
use nix::{
    sys::{prctl, signal::Signal},
    unistd,
};
use std::{
    ffi::{OsStr, OsString},
    fs::{self, File, Metadata, OpenOptions},
    io,
    os::unix::{
        fs::{FileTypeExt, MetadataExt},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{self, Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

use crate::preferences::VideoQuality;
use crate::process::CancellationToken;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionExit {
    Ended,
    Stopped,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionFailure {
    DependencyUnavailable,
    Disconnected,
}

/// Runs one mirroring session until scrcpy exits or cancellation is requested.
///
/// The target and sink path remain separated process arguments and neither
/// subprocess output nor raw endpoints cross the protocol/logging boundary.
pub trait SessionRunner {
    fn run(
        &mut self,
        target: &str,
        cancellation: &CancellationToken,
        on_started: &mut dyn FnMut(),
    ) -> Result<SessionExit, SessionFailure>;

    fn set_quality(&mut self, _quality: VideoQuality) {}

    fn set_scrcpy_arguments(&mut self, _arguments: Vec<String>) {}
}

impl<T> SessionRunner for Box<T>
where
    T: SessionRunner + ?Sized,
{
    fn run(
        &mut self,
        target: &str,
        cancellation: &CancellationToken,
        on_started: &mut dyn FnMut(),
    ) -> Result<SessionExit, SessionFailure> {
        (**self).run(target, cancellation, on_started)
    }

    fn set_quality(&mut self, quality: VideoQuality) {
        (**self).set_quality(quality);
    }

    fn set_scrcpy_arguments(&mut self, arguments: Vec<String>) {
        (**self).set_scrcpy_arguments(arguments);
    }
}

const PRODUCTION_V4L2_SINK: &str = "/dev/video42";
const PRODUCTION_V4L2_CARD: &str = "Droid Peek";
const PRODUCTION_V4L2_SYSFS: &str = "/sys/class/video4linux/video42";
const SESSION_START_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct SinkMetadata {
    is_symlink: bool,
    is_character_device: bool,
    device: u64,
    inode: u64,
    rdev: u64,
}

impl SinkMetadata {
    fn from_metadata(metadata: &Metadata) -> Self {
        let file_type = metadata.file_type();
        Self {
            is_symlink: file_type.is_symlink(),
            is_character_device: file_type.is_char_device(),
            device: metadata.dev(),
            inode: metadata.ino(),
            rdev: metadata.rdev(),
        }
    }
}

fn sysfs_attribute_value(contents: &str) -> Option<&str> {
    let value = contents.strip_suffix('\n').unwrap_or(contents);
    (!value.contains('\n') && !value.contains('\r')).then_some(value)
}

fn parse_sysfs_device(contents: &str) -> Option<(u64, u64)> {
    let (major, minor) = sysfs_attribute_value(contents)?.split_once(':')?;
    Some((major.parse().ok()?, minor.parse().ok()?))
}

// Decode Linux dev_t using the kernel/glibc layout without an FFI dependency.
fn linux_device_numbers(device: u64) -> (u64, u64) {
    (
        ((device >> 8) & 0xfff) | ((device >> 32) & 0xffff_f000),
        (device & 0xff) | ((device >> 12) & 0xffff_ff00),
    )
}

fn validate_capture_sink_identity(
    before_open: SinkMetadata,
    opened: SinkMetadata,
    after_open: SinkMetadata,
    sysfs_device: &str,
    sysfs_name: &str,
) -> bool {
    !before_open.is_symlink
        && before_open.is_character_device
        && before_open == opened
        && opened == after_open
        && parse_sysfs_device(sysfs_device) == Some(linux_device_numbers(opened.rdev))
        && sysfs_attribute_value(sysfs_name) == Some(PRODUCTION_V4L2_CARD)
}

#[doc(hidden)]
pub fn run_scrcpy_guardian(mut arguments: impl Iterator<Item = OsString>) -> io::Result<bool> {
    if arguments.next().as_deref() != Some(std::ffi::OsStr::new("--scrcpy-guardian")) {
        return Ok(false);
    }
    let expected_parent = arguments
        .next()
        .and_then(|value| value.into_string().ok())
        .and_then(|value| value.parse::<i32>().ok())
        .filter(|parent| *parent > 1)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid guardian parent"))?;
    prctl::set_pdeathsig(Signal::SIGKILL).map_err(io::Error::other)?;
    if unistd::getppid().as_raw() != expected_parent {
        return Err(io::Error::other(
            "helper parent exited before scrcpy startup",
        ));
    }
    let error = Command::new("scrcpy").args(arguments).exec();
    Err(error)
}

pub struct ScrcpySessionRunner {
    executable: PathBuf,
    argument_prefix: Vec<OsString>,
    v4l2_sink: PathBuf,
    poll_interval: Duration,
    quality: VideoQuality,
    scrcpy_arguments: Vec<OsString>,
    readiness_path: Option<PathBuf>,
    validate_production_identity: bool,
}

impl ScrcpySessionRunner {
    #[must_use]
    pub fn new(executable: impl AsRef<Path>, poll_interval: Duration) -> Self {
        Self::configured(
            executable,
            Path::new(PRODUCTION_V4L2_SINK),
            poll_interval,
            true,
        )
    }

    #[must_use]
    pub fn new_guarded(helper_executable: impl AsRef<Path>, poll_interval: Duration) -> Self {
        let mut runner = Self::new(helper_executable, poll_interval);
        runner.argument_prefix = vec![
            OsString::from("--scrcpy-guardian"),
            OsString::from(process::id().to_string()),
        ];
        runner
    }

    /// Constructs a runner with an isolated sink for fake process tests.
    ///
    /// This constructor does not validate the injected sink as the production
    /// Droid Peek video device.
    #[doc(hidden)]
    #[must_use]
    pub fn new_with_test_sink(
        executable: impl AsRef<Path>,
        v4l2_sink: impl AsRef<Path>,
        poll_interval: Duration,
    ) -> Self {
        Self::configured(executable, v4l2_sink, poll_interval, false)
    }

    fn configured(
        executable: impl AsRef<Path>,
        v4l2_sink: impl AsRef<Path>,
        poll_interval: Duration,
        validate_production_identity: bool,
    ) -> Self {
        Self {
            executable: executable.as_ref().to_owned(),
            argument_prefix: Vec::new(),
            v4l2_sink: v4l2_sink.as_ref().to_owned(),
            poll_interval,
            quality: VideoQuality::default(),
            scrcpy_arguments: Vec::new(),
            readiness_path: validate_production_identity
                .then(|| Path::new(PRODUCTION_V4L2_SYSFS).join("state")),
            validate_production_identity,
        }
    }

    #[must_use]
    pub fn with_readiness_path(mut self, readiness_path: impl AsRef<Path>) -> Self {
        self.readiness_path = Some(readiness_path.as_ref().to_owned());
        self
    }

    pub fn set_quality(&mut self, quality: VideoQuality) {
        self.quality = quality;
    }

    pub fn set_scrcpy_arguments(&mut self, arguments: Vec<String>) {
        self.scrcpy_arguments = arguments.into_iter().map(OsString::from).collect();
    }

    fn open_capture_sink(&self) -> io::Result<File> {
        if !self.validate_production_identity {
            return OpenOptions::new().write(true).open(&self.v4l2_sink);
        }

        let before_open = SinkMetadata::from_metadata(&fs::symlink_metadata(&self.v4l2_sink)?);
        if before_open.is_symlink || !before_open.is_character_device {
            return Err(io::Error::other(
                "capture sink is not a direct character device",
            ));
        }
        let sink = OpenOptions::new().write(true).open(&self.v4l2_sink)?;
        let opened = SinkMetadata::from_metadata(&sink.metadata()?);
        let after_open = SinkMetadata::from_metadata(&fs::symlink_metadata(&self.v4l2_sink)?);
        let sysfs_device = fs::read_to_string(Path::new(PRODUCTION_V4L2_SYSFS).join("dev"))?;
        let sysfs_name = fs::read_to_string(Path::new(PRODUCTION_V4L2_SYSFS).join("name"))?;

        if validate_capture_sink_identity(
            before_open,
            opened,
            after_open,
            &sysfs_device,
            &sysfs_name,
        ) {
            Ok(sink)
        } else {
            Err(io::Error::other(
                "capture sink does not match the Droid Peek video device",
            ))
        }
    }

    fn sink_is_capture_ready(&self) -> bool {
        self.readiness_path.as_ref().is_none_or(|path| {
            fs::read_to_string(path).is_ok_and(|state| state.trim() == "capture")
        })
    }

    fn stop_child(child: &mut Child) {
        let _ = child.kill();
        let _ = child.wait();
    }
}

impl SessionRunner for ScrcpySessionRunner {
    fn set_quality(&mut self, quality: VideoQuality) {
        ScrcpySessionRunner::set_quality(self, quality);
    }

    fn set_scrcpy_arguments(&mut self, arguments: Vec<String>) {
        ScrcpySessionRunner::set_scrcpy_arguments(self, arguments);
    }

    fn run(
        &mut self,
        target: &str,
        cancellation: &CancellationToken,
        on_started: &mut dyn FnMut(),
    ) -> Result<SessionExit, SessionFailure> {
        if cancellation.is_cancelled() {
            return Ok(SessionExit::Stopped);
        }
        self.open_capture_sink()
            .map_err(|_| SessionFailure::DependencyUnavailable)?;

        let [max_size, bit_rate, max_fps] = match self.quality {
            VideoQuality::Low => ["720", "4M", "30"],
            VideoQuality::Medium => ["1080", "8M", "60"],
            VideoQuality::High => ["0", "16M", "60"],
        };
        let requires_control = self.scrcpy_arguments.iter().any(|argument| {
            argument == OsStr::new("--keep-active")
                || argument == OsStr::new("--stay-awake")
                || argument == OsStr::new("--turn-screen-off")
        });
        let mut command = Command::new(&self.executable);
        command
            .args(&self.argument_prefix)
            .arg(format!("--serial={target}"))
            .arg("--no-window")
            .arg("--no-audio");
        if !requires_control {
            command.arg("--no-control");
        }
        let mut child = command
            .arg(format!("--v4l2-sink={}", self.v4l2_sink.display()))
            .arg(format!("--max-size={max_size}"))
            .arg(format!("--video-bit-rate={bit_rate}"))
            .arg(format!("--max-fps={max_fps}"))
            .args(&self.scrcpy_arguments)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| SessionFailure::DependencyUnavailable)?;
        let start_deadline = Instant::now() + SESSION_START_TIMEOUT;
        loop {
            if cancellation.is_cancelled() {
                Self::stop_child(&mut child);
                return Ok(SessionExit::Stopped);
            }

            match child.try_wait() {
                Ok(Some(status)) if status.success() => return Ok(SessionExit::Ended),
                Ok(Some(_)) => return Err(SessionFailure::Disconnected),
                Ok(None) if self.sink_is_capture_ready() => {
                    on_started();
                    break;
                }
                Ok(None) if Instant::now() >= start_deadline => {
                    Self::stop_child(&mut child);
                    return Err(SessionFailure::Disconnected);
                }
                Ok(None) => thread::sleep(self.poll_interval),
                Err(_) => {
                    Self::stop_child(&mut child);
                    return Err(SessionFailure::DependencyUnavailable);
                }
            }
        }

        loop {
            if cancellation.is_cancelled() {
                Self::stop_child(&mut child);
                return Ok(SessionExit::Stopped);
            }

            match child.try_wait() {
                Ok(Some(status)) if status.success() => return Ok(SessionExit::Ended),
                Ok(Some(_)) => return Err(SessionFailure::Disconnected),
                Ok(None) => thread::sleep(self.poll_interval),
                Err(_) => {
                    Self::stop_child(&mut child);
                    return Err(SessionFailure::DependencyUnavailable);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{path::Path, time::Duration};

    use super::{
        PRODUCTION_V4L2_CARD, PRODUCTION_V4L2_SINK, PRODUCTION_V4L2_SYSFS, ScrcpySessionRunner,
        SinkMetadata, validate_capture_sink_identity,
    };

    #[test]
    fn production_runner_is_bound_to_the_fixed_capture_identity() {
        let runner = ScrcpySessionRunner::new("scrcpy", Duration::from_millis(25));
        let expected_readiness_path = Path::new(PRODUCTION_V4L2_SYSFS).join("state");

        assert_eq!(runner.v4l2_sink.as_path(), Path::new(PRODUCTION_V4L2_SINK));
        assert_eq!(
            runner.readiness_path.as_deref(),
            Some(expected_readiness_path.as_path())
        );
        assert!(runner.validate_production_identity);
        assert_eq!(PRODUCTION_V4L2_CARD, "Droid Peek");
    }

    fn valid_sink_metadata() -> SinkMetadata {
        SinkMetadata {
            is_symlink: false,
            is_character_device: true,
            device: 9,
            inode: 42,
            rdev: (81 << 8) | 42,
        }
    }

    #[test]
    fn strict_capture_identity_accepts_the_fixed_device_and_card() {
        let metadata = valid_sink_metadata();

        assert!(validate_capture_sink_identity(
            metadata,
            metadata,
            metadata,
            "81:42\n",
            "Droid Peek\n",
        ));
    }

    #[test]
    fn strict_capture_identity_rejects_ordinary_files_and_symlinks() {
        let metadata = valid_sink_metadata();

        assert!(!validate_capture_sink_identity(
            SinkMetadata {
                is_character_device: false,
                ..metadata
            },
            metadata,
            metadata,
            "81:42\n",
            "Droid Peek\n",
        ));
        assert!(!validate_capture_sink_identity(
            SinkMetadata {
                is_symlink: true,
                ..metadata
            },
            metadata,
            metadata,
            "81:42\n",
            "Droid Peek\n",
        ));
    }

    #[test]
    fn strict_capture_identity_rejects_device_replacement_during_open() {
        let metadata = valid_sink_metadata();

        assert!(!validate_capture_sink_identity(
            metadata,
            SinkMetadata {
                inode: metadata.inode + 1,
                ..metadata
            },
            metadata,
            "81:42\n",
            "Droid Peek\n",
        ));
        assert!(!validate_capture_sink_identity(
            metadata,
            metadata,
            SinkMetadata {
                rdev: metadata.rdev + 1,
                ..metadata
            },
            "81:42\n",
            "Droid Peek\n",
        ));
    }

    #[test]
    fn strict_capture_identity_rejects_wrong_sysfs_device_or_card() {
        let metadata = valid_sink_metadata();

        assert!(!validate_capture_sink_identity(
            metadata,
            metadata,
            metadata,
            "81:41\n",
            "Droid Peek\n",
        ));
        assert!(!validate_capture_sink_identity(
            metadata,
            metadata,
            metadata,
            "81:42\n",
            "Droid Peek Backup\n",
        ));
    }
}
