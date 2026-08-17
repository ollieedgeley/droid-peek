//! Cancellable lifecycle boundary for the unmodified scrcpy client.
use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::mpsc,
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PhysicalDisplaySize {
    width_mm: u16,
    height_mm: u16,
}

impl PhysicalDisplaySize {
    #[must_use]
    pub const fn new(width_mm: u16, height_mm: u16) -> Option<Self> {
        if width_mm >= 20 && width_mm <= 1_000 && height_mm >= 20 && height_mm <= 1_000 {
            Some(Self {
                width_mm,
                height_mm,
            })
        } else {
            None
        }
    }

    #[must_use]
    pub const fn width_mm(self) -> u16 {
        self.width_mm
    }

    #[must_use]
    pub const fn height_mm(self) -> u16 {
        self.height_mm
    }
}

pub trait PhysicalDisplayProbe {
    fn probe(
        &mut self,
        target: &str,
        cancellation: &CancellationToken,
    ) -> Option<PhysicalDisplaySize>;
}

struct AdbPhysicalDisplayProbe {
    executable: PathBuf,
    poll_interval: Duration,
}

impl AdbPhysicalDisplayProbe {
    fn new(executable: impl AsRef<Path>, poll_interval: Duration) -> Self {
        Self {
            executable: executable.as_ref().to_owned(),
            poll_interval,
        }
    }
}

impl PhysicalDisplayProbe for AdbPhysicalDisplayProbe {
    fn probe(
        &mut self,
        target: &str,
        cancellation: &CancellationToken,
    ) -> Option<PhysicalDisplaySize> {
        const OUTPUT_LIMIT: u64 = 512 * 1024;
        const PROBE_TIMEOUT: Duration = Duration::from_secs(3);

        if cancellation.is_cancelled() {
            return None;
        }
        let mut child = Command::new(&self.executable)
            .args(["-s", target, "shell", "dumpsys", "SurfaceFlinger"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        let stdout = child.stdout.take()?;
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            let mut output = Vec::new();
            let _ = stdout.take(OUTPUT_LIMIT).read_to_end(&mut output);
            let _ = sender.send(output);
        });
        let deadline = Instant::now() + PROBE_TIMEOUT;
        loop {
            if cancellation.is_cancelled() || Instant::now() >= deadline {
                ScrcpySessionRunner::stop_child(&mut child);
                return None;
            }
            match child.try_wait() {
                Ok(Some(_)) => {
                    let output = receiver.recv_timeout(PROBE_TIMEOUT).ok()?;
                    return parse_surface_flinger_display(
                        std::str::from_utf8(output.as_slice()).ok()?,
                    );
                }
                Ok(None) => thread::sleep(self.poll_interval),
                Err(_) => {
                    ScrcpySessionRunner::stop_child(&mut child);
                    return None;
                }
            }
        }
    }
}

fn parse_surface_flinger_display(output: &str) -> Option<PhysicalDisplaySize> {
    output
        .lines()
        .filter(|line| line.contains("activeMode={"))
        .find_map(parse_surface_flinger_mode)
}

fn parse_surface_flinger_mode(line: &str) -> Option<PhysicalDisplaySize> {
    let (width_pixels, height_pixels) = parse_pair(line, "resolution=")?;
    let (xdpi, ydpi) = parse_pair(line, "dpi=")?;
    if !(100.0..=10_000.0).contains(&width_pixels)
        || !(100.0..=10_000.0).contains(&height_pixels)
        || !(40.0..=2_000.0).contains(&xdpi)
        || !(40.0..=2_000.0).contains(&ydpi)
    {
        return None;
    }
    let width_mm = (width_pixels / xdpi * 25.4).round();
    let height_mm = (height_pixels / ydpi * 25.4).round();
    PhysicalDisplaySize::new(width_mm as u16, height_mm as u16)
}

fn parse_pair(line: &str, key: &str) -> Option<(f64, f64)> {
    let value = line.split_once(key)?.1;
    let value = value
        .split(|character: char| character == ',' || character.is_whitespace() || character == '}')
        .next()?;
    let (first, second) = value.split_once('x')?;
    Some((first.parse().ok()?, second.parse().ok()?))
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
        on_started: &mut dyn FnMut(Option<PhysicalDisplaySize>),
    ) -> Result<SessionExit, SessionFailure>;

    fn set_quality(&mut self, _quality: VideoQuality) {}
}

impl<T> SessionRunner for Box<T>
where
    T: SessionRunner + ?Sized,
{
    fn run(
        &mut self,
        target: &str,
        cancellation: &CancellationToken,
        on_started: &mut dyn FnMut(Option<PhysicalDisplaySize>),
    ) -> Result<SessionExit, SessionFailure> {
        (**self).run(target, cancellation, on_started)
    }

    fn set_quality(&mut self, quality: VideoQuality) {
        (**self).set_quality(quality);
    }
}

pub struct UnavailableSessionRunner;

impl SessionRunner for UnavailableSessionRunner {
    fn run(
        &mut self,
        _target: &str,
        _cancellation: &CancellationToken,
        _on_started: &mut dyn FnMut(Option<PhysicalDisplaySize>),
    ) -> Result<SessionExit, SessionFailure> {
        Err(SessionFailure::DependencyUnavailable)
    }
}

pub struct ScrcpySessionRunner {
    executable: PathBuf,
    v4l2_sink: PathBuf,
    poll_interval: Duration,
    quality: VideoQuality,
    display_probe: Box<dyn PhysicalDisplayProbe + Send>,
    readiness_path: Option<PathBuf>,
}

const SESSION_START_TIMEOUT: Duration = Duration::from_secs(10);

impl ScrcpySessionRunner {
    #[must_use]
    pub fn new(
        executable: impl AsRef<Path>,
        v4l2_sink: impl AsRef<Path>,
        poll_interval: Duration,
    ) -> Self {
        let v4l2_sink = v4l2_sink.as_ref().to_owned();
        let readiness_path = if v4l2_sink.parent() == Some(Path::new("/dev")) {
            v4l2_sink
                .file_name()
                .map(|name| Path::new("/sys/class/video4linux").join(name).join("state"))
        } else {
            None
        };

        Self {
            executable: executable.as_ref().to_owned(),
            v4l2_sink,
            poll_interval,
            quality: VideoQuality::default(),
            readiness_path,
            display_probe: Box::new(AdbPhysicalDisplayProbe::new("adb", poll_interval)),
        }
    }

    #[must_use]
    pub fn with_readiness_path(mut self, readiness_path: impl AsRef<Path>) -> Self {
        self.readiness_path = Some(readiness_path.as_ref().to_owned());
        self
    }

    #[must_use]
    pub fn with_display_probe(mut self, probe: impl PhysicalDisplayProbe + Send + 'static) -> Self {
        self.display_probe = Box::new(probe);
        self
    }

    pub fn set_quality(&mut self, quality: VideoQuality) {
        self.quality = quality;
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
    fn run(
        &mut self,
        target: &str,
        cancellation: &CancellationToken,
        on_started: &mut dyn FnMut(Option<PhysicalDisplaySize>),
    ) -> Result<SessionExit, SessionFailure> {
        if cancellation.is_cancelled() {
            return Ok(SessionExit::Stopped);
        }
        let physical_display = self.display_probe.probe(target, cancellation);

        let [max_size, bit_rate, max_fps] = match self.quality {
            VideoQuality::Low => ["720", "4M", "30"],
            VideoQuality::Medium => ["1080", "8M", "60"],
            VideoQuality::High => ["0", "16M", "60"],
        };
        let mut child = Command::new(&self.executable)
            .arg(format!("--serial={target}"))
            .arg("--no-window")
            .arg("--no-audio")
            .arg("--no-control")
            .arg(format!("--v4l2-sink={}", self.v4l2_sink.display()))
            .arg(format!("--max-size={max_size}"))
            .arg(format!("--video-bit-rate={bit_rate}"))
            .arg(format!("--max-fps={max_fps}"))
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
                    on_started(physical_display);
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
    use std::{fs, os::unix::fs::PermissionsExt, time::Duration};

    use super::{
        AdbPhysicalDisplayProbe, PhysicalDisplayProbe, PhysicalDisplaySize,
        parse_surface_flinger_display,
    };
    use crate::process::CancellationToken;
    use tempfile::tempdir;

    #[test]
    fn parses_active_mode_into_physical_millimeters() {
        let output = r#"
            activeMode={id=2, hwcId=2, resolution=1080x2392, vsyncRate=60.00 Hz, dpi=391.89x386.98, group=0}
            x-dpi                     : 391.89
            y-dpi                     : 386.98
        "#;

        assert_eq!(
            parse_surface_flinger_display(output),
            Some(PhysicalDisplaySize::new(70, 157).expect("valid phone dimensions"))
        );
    }

    #[test]
    fn adb_probe_targets_the_device_and_keeps_only_physical_dimensions() {
        let directory = tempdir().expect("temporary directory");
        let arguments_path = directory.path().join("arguments");
        let executable = directory.path().join("fake-adb");
        fs::write(
            &executable,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\nprintf '%s\\n' 'activeMode={{resolution=1080x2392, dpi=391.89x386.98}}'\n",
                arguments_path.display()
            ),
        )
        .expect("write fake adb");
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700))
            .expect("make fake adb executable");
        let mut probe = AdbPhysicalDisplayProbe::new(executable, Duration::from_millis(1));

        assert_eq!(
            probe.probe("device-target", &CancellationToken::new()),
            Some(PhysicalDisplaySize::new(70, 157).expect("valid phone dimensions"))
        );
        assert_eq!(
            fs::read_to_string(arguments_path).expect("captured adb arguments"),
            "-s\ndevice-target\nshell\ndumpsys\nSurfaceFlinger\n"
        );
    }

    #[test]
    fn rejects_missing_or_implausible_physical_dpi() {
        assert_eq!(
            parse_surface_flinger_display("activeMode={resolution=1080x2392, dpi=0x386.98}"),
            None
        );
        assert_eq!(
            parse_surface_flinger_display("activeMode={resolution=1080x2392, dpi=20x20}"),
            None
        );
    }
}
