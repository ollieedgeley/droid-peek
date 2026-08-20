//! A fakeable boundary around local process execution.
use std::{
    io::{self, Read, Write},
    os::fd::AsRawFd,
    path::{Path, PathBuf},
    process::{Child, ChildStderr, ChildStdout, Command, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

use nix::fcntl::{FcntlArg, OFlag, fcntl};
use zeroize::{Zeroize, Zeroizing};

const MAX_DRAIN_BYTES_PER_POLL: usize = 64 * 1024;
const MAX_CLASSIFIED_OUTPUT_BYTES: usize = 8 * 1024;

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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ActionExecutionFailure {
    DependencyUnavailable,
    Disconnected,
    Unauthorized,
    Cancelled,
}

impl From<CommandFailure> for ActionExecutionFailure {
    fn from(failure: CommandFailure) -> Self {
        match failure {
            CommandFailure::DependencyUnavailable => Self::DependencyUnavailable,
            CommandFailure::Unauthorized => Self::Unauthorized,
            CommandFailure::Cancelled => Self::Cancelled,
        }
    }
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

    fn run_phone_target(
        &mut self,
        request: CommandRequest,
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, ActionExecutionFailure> {
        self.run(request, cancellation)
            .map_err(ActionExecutionFailure::from)
    }
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

    fn run_phone_target(
        &mut self,
        request: CommandRequest,
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, ActionExecutionFailure> {
        (**self).run_phone_target(request, cancellation)
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

    fn run_internal(
        &mut self,
        request: CommandRequest,
        cancellation: &CancellationToken,
        capture_output: bool,
    ) -> Result<(CommandOutput, Option<CapturedStreams>), CommandFailure> {
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
            });
        if capture_output {
            command.stdout(Stdio::piped()).stderr(Stdio::piped());
        } else {
            command.stdout(Stdio::null()).stderr(Stdio::null());
        }

        let mut child = command
            .spawn()
            .map_err(|_| CommandFailure::DependencyUnavailable)?;
        let mut capture = if capture_output {
            match BoundedOutputCapture::start(&mut child) {
                Ok(capture) => Some(capture),
                Err(failure) => {
                    terminate(&mut child);
                    return Err(failure);
                }
            }
        } else {
            None
        };

        if let Some(input) = request.stdin() {
            let Some(mut stdin) = child.stdin.take() else {
                terminate(&mut child);
                return Err(CommandFailure::DependencyUnavailable);
            };
            if stdin.write_all(input.as_bytes()).is_err() {
                terminate(&mut child);
                return Err(CommandFailure::DependencyUnavailable);
            }
        }

        loop {
            if cancellation.is_cancelled() {
                terminate(&mut child);
                return Err(CommandFailure::Cancelled);
            }
            if let Some(capture) = capture.as_mut()
                && let Err(failure) = capture.drain_available()
            {
                terminate(&mut child);
                return Err(failure);
            }

            match child.try_wait() {
                Ok(Some(status)) => {
                    let captured = capture.map(BoundedOutputCapture::finish).transpose()?;
                    let succeeded = status.success();
                    return Ok((CommandOutput { succeeded }, captured));
                }
                Ok(None) => thread::sleep(self.poll_interval),
                Err(_) => {
                    terminate(&mut child);
                    return Err(CommandFailure::DependencyUnavailable);
                }
            }
        }
    }
}

type CapturedStreams = [Zeroizing<Vec<u8>>; 2];

struct BoundedOutputCapture {
    stdout: ChildStdout,
    stderr: ChildStderr,
    stdout_bytes: Zeroizing<Vec<u8>>,
    stderr_bytes: Zeroizing<Vec<u8>>,
}

impl BoundedOutputCapture {
    fn start(child: &mut Child) -> Result<Self, CommandFailure> {
        let stdout = child
            .stdout
            .take()
            .ok_or(CommandFailure::DependencyUnavailable)?;
        let stderr = child
            .stderr
            .take()
            .ok_or(CommandFailure::DependencyUnavailable)?;
        set_nonblocking(&stdout)?;
        set_nonblocking(&stderr)?;
        Ok(Self {
            stdout,
            stderr,
            stdout_bytes: Zeroizing::new(Vec::new()),
            stderr_bytes: Zeroizing::new(Vec::new()),
        })
    }

    fn drain_available(&mut self) -> Result<(), CommandFailure> {
        read_available_bounded(&mut self.stdout, &mut self.stdout_bytes)?;
        read_available_bounded(&mut self.stderr, &mut self.stderr_bytes)
    }

    fn finish(mut self) -> Result<CapturedStreams, CommandFailure> {
        self.drain_available()?;
        Ok([self.stdout_bytes, self.stderr_bytes])
    }
}

fn set_nonblocking(stream: &impl AsRawFd) -> Result<(), CommandFailure> {
    let flags = fcntl(stream.as_raw_fd(), FcntlArg::F_GETFL)
        .map(OFlag::from_bits_truncate)
        .map_err(|_| CommandFailure::DependencyUnavailable)?;
    fcntl(
        stream.as_raw_fd(),
        FcntlArg::F_SETFL(flags | OFlag::O_NONBLOCK),
    )
    .map(|_| ())
    .map_err(|_| CommandFailure::DependencyUnavailable)
}

fn read_available_bounded(
    reader: &mut impl Read,
    captured: &mut Zeroizing<Vec<u8>>,
) -> Result<(), CommandFailure> {
    let mut buffer = Zeroizing::new([0_u8; 1024]);
    let mut drained = 0;
    while drained < MAX_DRAIN_BYTES_PER_POLL {
        let count = match reader.read(&mut buffer[..]) {
            Ok(0) => return Ok(()),
            Ok(count) => count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(()),
            Err(_) => return Err(CommandFailure::DependencyUnavailable),
        };
        drained += count;
        let remaining = MAX_CLASSIFIED_OUTPUT_BYTES.saturating_sub(captured.len());
        captured.extend_from_slice(&buffer[..count.min(remaining)]);
    }
    Ok(())
}

fn classify_action_failure(
    output: &CapturedStreams,
    echoed_fragments: &[String],
) -> Option<ActionExecutionFailure> {
    if output.iter().any(|stream| {
        contains_ascii_case_insensitive(stream, b"error: device unauthorized")
            || contains_ascii_case_insensitive(stream, b"failed to authenticate")
    }) {
        return Some(ActionExecutionFailure::Unauthorized);
    }
    let sanitized = [
        sanitize_echoes(&output[0], echoed_fragments),
        sanitize_echoes(&output[1], echoed_fragments),
    ];
    if sanitized.iter().any(|stream| {
        contains_ascii_case_insensitive(stream, b"device offline")
            || contains_ascii_case_insensitive(stream, b"device not found")
            || contains_ascii_case_insensitive(stream, b"no devices/emulators found")
            || (contains_ascii_case_insensitive(stream, b"device '")
                && contains_ascii_case_insensitive(stream, b"not found"))
    }) {
        return Some(ActionExecutionFailure::Disconnected);
    }
    None
}

fn sanitize_echoes(stream: &[u8], echoed_fragments: &[String]) -> Vec<u8> {
    echoed_fragments
        .iter()
        .fold(stream.to_vec(), |bytes, fragment| {
            let needle = fragment.as_bytes();
            if needle.is_empty() {
                bytes
            } else {
                remove_subslice(&bytes, needle)
            }
        })
}

fn remove_subslice(haystack: &[u8], needle: &[u8]) -> Vec<u8> {
    let mut result = Vec::with_capacity(haystack.len());
    let mut index = 0;
    while index < haystack.len() {
        if haystack[index..].starts_with(needle) {
            index += needle.len();
        } else {
            result.push(haystack[index]);
            index += 1;
        }
    }
    result
}

fn component_echo_fragments(arguments: &[String]) -> Vec<String> {
    let Some(index) = arguments.windows(2).position(|pair| pair[0] == "-n") else {
        return Vec::new();
    };
    let component = posix_shell_unquote(&arguments[index + 1]);
    let mut fragments = Vec::new();
    if !component.is_empty() {
        fragments.push(component.clone());
    }
    if let Some((package, activity)) = component.split_once('/') {
        if !package.is_empty() {
            fragments.push(package.to_owned());
        }
        if !activity.is_empty() {
            fragments.push(activity.to_owned());
        }
    }
    fragments
}

fn posix_shell_unquote(value: &str) -> String {
    let Some(inner) = value
        .strip_prefix('\'')
        .and_then(|value| value.strip_suffix('\''))
    else {
        return value.to_owned();
    };
    inner.replace("'\\''", "'")
}

fn monkey_launch_aborted(output: &CapturedStreams) -> bool {
    output.iter().any(|stream| {
        contains_ascii_case_insensitive(stream, b"no activities found to run, monkey aborted")
    })
}

fn activity_manager_launch_failed(output: &CapturedStreams) -> bool {
    output.iter().any(|stream| {
        contains_ascii_case_insensitive(stream, b"error type 3")
            || contains_ascii_case_insensitive(stream, b"does not exist")
            || contains_ascii_case_insensitive(stream, b"unable to resolve intent")
            || contains_ascii_case_insensitive(stream, b"no activity found")
            || contains_ascii_case_insensitive(stream, b"permission denial")
            || contains_ascii_case_insensitive(stream, b"permission denied")
    })
}

fn contains_ascii_case_insensitive(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window.eq_ignore_ascii_case(needle))
}

fn terminate(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

impl CommandRunner for AdbCommandRunner {
    fn run(
        &mut self,
        request: CommandRequest,
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, CommandFailure> {
        self.run_internal(request, cancellation, false)
            .map(|(output, _)| output)
    }

    fn run_phone_target(
        &mut self,
        request: CommandRequest,
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, ActionExecutionFailure> {
        let echoed_fragments = component_echo_fragments(request.arguments());
        let (output, captured) = self
            .run_internal(request, cancellation, true)
            .map_err(ActionExecutionFailure::from)?;
        if let Some(failure) = captured
            .as_ref()
            .and_then(|output| classify_action_failure(output, &echoed_fragments))
        {
            return Err(failure);
        }
        if captured.as_ref().is_some_and(monkey_launch_aborted) {
            return Ok(CommandOutput { succeeded: false });
        }
        if captured
            .as_ref()
            .is_some_and(activity_manager_launch_failed)
        {
            return Ok(CommandOutput { succeeded: false });
        }
        Ok(output)
    }
}
