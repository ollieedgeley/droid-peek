//! Cancellable lifecycle boundary for the unmodified scrcpy client.
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
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
}

pub struct UnavailableSessionRunner;

impl SessionRunner for UnavailableSessionRunner {
    fn run(
        &mut self,
        _target: &str,
        _cancellation: &CancellationToken,
        _on_started: &mut dyn FnMut(),
    ) -> Result<SessionExit, SessionFailure> {
        Err(SessionFailure::DependencyUnavailable)
    }
}

pub struct ScrcpySessionRunner {
    executable: PathBuf,
    v4l2_sink: PathBuf,
    poll_interval: Duration,
    quality: VideoQuality,
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
        on_started: &mut dyn FnMut(),
    ) -> Result<SessionExit, SessionFailure> {
        if cancellation.is_cancelled() {
            return Ok(SessionExit::Stopped);
        }

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
    use super::{PhysicalDisplaySize, parse_surface_flinger_display};

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
    fn rejects_missing_or_implausible_physical_dpi() {
        assert_eq!(
            parse_surface_flinger_display(
                "activeMode={resolution=1080x2392, dpi=0x386.98}"
            ),
            None
        );
        assert_eq!(
            parse_surface_flinger_display(
                "activeMode={resolution=1080x2392, dpi=20x20}"
            ),
            None
        );
    }
}
