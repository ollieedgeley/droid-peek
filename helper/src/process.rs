//! A fakeable boundary around local process execution.
use std::{
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
};

/// A command expressed as an executable plus already-separated arguments.
///
/// It intentionally has no `Debug` implementation: pairing secrets can appear
/// in argument lists and must never be included in logs by accident.
#[derive(Clone, Eq, PartialEq)]
pub struct CommandRequest {
    program: String,
    arguments: Vec<String>,
}

impl CommandRequest {
    #[must_use]
    pub fn new(program: impl Into<String>, arguments: Vec<String>) -> Self {
        Self {
            program: program.into(),
            arguments,
        }
    }

    #[must_use]
    pub fn program(&self) -> &str {
        &self.program
    }

    #[must_use]
    pub fn arguments(&self) -> &[String] {
        &self.arguments
    }
}

/// The only process result the pairing flow currently needs.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CommandOutput {
    pub succeeded: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CommandFailure {
    DependencyUnavailable,
    Unauthorized,
    Cancelled,
}
#[derive(Clone, Default)]
pub struct CancellationToken {
    cancelled: Arc<AtomicBool>,
}

impl CancellationToken {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }

    #[must_use]
    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }
}

/// Executes a command. Production and test implementations share this boundary.
pub trait CommandRunner {
    fn run(
        &mut self,
        request: CommandRequest,
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, CommandFailure>;
}

impl<T> CommandRunner for Box<T>
where
    T: CommandRunner + ?Sized,
{
    fn run(
        &mut self,
        request: CommandRequest,
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, CommandFailure> {
        (**self).run(request, cancellation)
    }
}

/// Runs the system ADB executable without exposing its output or command line.
pub struct AdbCommandRunner {
    executable: PathBuf,
    poll_interval: Duration,
}

impl AdbCommandRunner {
    #[must_use]
    pub fn new(executable: impl AsRef<Path>, poll_interval: Duration) -> Self {
        Self {
            executable: executable.as_ref().to_owned(),
            poll_interval,
        }
    }
}

impl CommandRunner for AdbCommandRunner {
    fn run(
        &mut self,
        request: CommandRequest,
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, CommandFailure> {
        if request.program() != "adb" {
            return Err(CommandFailure::DependencyUnavailable);
        }
        if cancellation.is_cancelled() {
            return Err(CommandFailure::Cancelled);
        }

        let mut child = Command::new(&self.executable)
            .args(request.arguments())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| CommandFailure::DependencyUnavailable)?;

        loop {
            if cancellation.is_cancelled() {
                let _ = child.kill();
                let _ = child.wait();
                return Err(CommandFailure::Cancelled);
            }

            match child.try_wait() {
                Ok(Some(status)) => {
                    return Ok(CommandOutput {
                        succeeded: status.success(),
                    });
                }
                Ok(None) => thread::sleep(self.poll_interval),
                Err(_) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(CommandFailure::DependencyUnavailable);
                }
            }
        }
    }
}
