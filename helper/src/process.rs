//! A fakeable boundary around local process execution.
use std::{
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};
use zeroize::{Zeroize, Zeroizing};

/// A command expressed as an executable plus already-separated arguments and
/// optional private standard input.
///
/// It intentionally has no `Debug` implementation so private input cannot be
/// included in logs by accident.
#[derive(Eq, PartialEq)]
pub struct CommandRequest {
    program: String,
    arguments: Vec<String>,
    stdin: Option<Zeroizing<String>>,
}

impl CommandRequest {
    #[must_use]
    pub fn new(program: impl Into<String>, arguments: Vec<String>) -> Self {
        Self {
            program: program.into(),
            arguments,
            stdin: None,
        }
    }

    #[must_use]
    pub fn with_stdin(mut self, stdin: Zeroizing<String>) -> Self {
        self.stdin = Some(stdin);
        self
    }

    #[must_use]
    pub fn program(&self) -> &str {
        &self.program
    }

    #[must_use]
    pub fn arguments(&self) -> &[String] {
        &self.arguments
    }

    #[must_use]
    pub fn stdin(&self) -> Option<&str> {
        self.stdin.as_deref().map(String::as_str)
    }
}

impl Drop for CommandRequest {
    fn drop(&mut self) {
        self.program.zeroize();
        self.arguments.zeroize();
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
    deadline: Option<Instant>,
}

impl CancellationToken {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn child_with_timeout(&self, timeout: Duration) -> Self {
        let now = Instant::now();
        let child_deadline = now.checked_add(timeout).unwrap_or(now);
        Self {
            cancelled: Arc::clone(&self.cancelled),
            deadline: Some(
                self.deadline
                    .map_or(child_deadline, |deadline| deadline.min(child_deadline)),
            ),
        }
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }

    #[must_use]
    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
            || self
                .deadline
                .is_some_and(|deadline| Instant::now() >= deadline)
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

        let mut command = Command::new(&self.executable);
        command
            .args(request.arguments())
            .stdin(if request.stdin().is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut child = command
            .spawn()
            .map_err(|_| CommandFailure::DependencyUnavailable)?;
        if let Some(input) = request.stdin()
            && child
                .stdin
                .take()
                .ok_or(CommandFailure::DependencyUnavailable)?
                .write_all(input.as_bytes())
                .is_err()
        {
            let _ = child.kill();
            let _ = child.wait();
            return Err(CommandFailure::DependencyUnavailable);
        }

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
