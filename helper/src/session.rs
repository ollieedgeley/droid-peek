//! Cancellable lifecycle boundary for the unmodified scrcpy client.
use std::{
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::Duration,
};

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
}

impl ScrcpySessionRunner {
    #[must_use]
    pub fn new(
        executable: impl AsRef<Path>,
        v4l2_sink: impl AsRef<Path>,
        poll_interval: Duration,
    ) -> Self {
        Self {
            executable: executable.as_ref().to_owned(),
            v4l2_sink: v4l2_sink.as_ref().to_owned(),
            poll_interval,
        }
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

        let mut child = Command::new(&self.executable)
            .arg(format!("--serial={target}"))
            .arg("--no-window")
            .arg("--no-audio")
            .arg("--no-control")
            .arg(format!("--v4l2-sink={}", self.v4l2_sink.display()))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| SessionFailure::DependencyUnavailable)?;
        on_started();

        loop {
            if cancellation.is_cancelled() {
                let _ = child.kill();
                let _ = child.wait();
                return Ok(SessionExit::Stopped);
            }

            match child.try_wait() {
                Ok(Some(status)) if status.success() => return Ok(SessionExit::Ended),
                Ok(Some(_)) => return Err(SessionFailure::Disconnected),
                Ok(None) => thread::sleep(self.poll_interval),
                Err(_) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(SessionFailure::DependencyUnavailable);
                }
            }
        }
    }
}
