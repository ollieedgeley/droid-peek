#![forbid(unsafe_code)]
#![deny(clippy::expect_used, clippy::unwrap_used)]
#![deny(clippy::todo, clippy::unimplemented)]

use std::{
    env,
    fs::File,
    io::{self, BufRead},
    path::Path,
    time::Duration,
};

use omarchy_android_helper::{
    persistence::default_state_directory,
    private_fs::create_private_file,
    protocol::{Event, PairingBackend, ProtocolEngine},
    runtime::{
        AcceptanceEventWriter, ProtocolSink, RuntimePairingBackend, WriterProtocolSink,
        default_runtime_directory,
    },
    session::run_scrcpy_guardian,
};

fn main() -> io::Result<()> {
    if run_scrcpy_guardian(env::args_os().skip(1))? {
        return Ok(());
    }
    let arguments = startup_arguments()?;
    let stdin = io::stdin();
    let runtime_directory = default_runtime_directory()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR is unavailable"))?;
    let state_directory = default_state_directory().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "XDG_STATE_HOME and HOME are unavailable",
        )
    })?;
    let log = if arguments.acceptance_logging {
        Some(open_acceptance_log(&runtime_directory)?)
    } else {
        None
    };
    let writer = match log {
        Some(log) => AcceptanceEventWriter::with_log(io::stdout(), log),
        None => AcceptanceEventWriter::<_, File>::without_log(io::stdout()),
    };
    let sink = WriterProtocolSink::new(writer);
    let backend = RuntimePairingBackend::new(
        &runtime_directory,
        &state_directory,
        Duration::from_secs(120),
        &arguments.helper_epoch,
        sink.clone(),
    )?;
    let has_trusted_device = backend.has_trusted_device();
    let preferences = backend.preferences();
    let mut engine = ProtocolEngine::new(backend, &arguments.helper_epoch);

    sink.emit_event(&Event::Ready {
        helper_epoch: arguments.helper_epoch,
        session_generation: "0".to_owned(),
        has_trusted_device,
        preferences,
    })?;
    let result = (|| {
        for line in stdin.lock().lines() {
            for event in engine.handle_line(&line?) {
                sink.emit_event(&event)?;
            }
            engine.response_emitted();
        }
        Ok(())
    })();
    engine.into_backend().shutdown();
    result
}

struct StartupArguments {
    helper_epoch: String,
    acceptance_logging: bool,
}

fn startup_arguments() -> io::Result<StartupArguments> {
    let mut arguments = env::args_os().skip(1);
    let mut helper_epoch = None;
    let mut acceptance_logging = false;
    while let Some(argument) = arguments.next() {
        if argument == "--acceptance-log" && !acceptance_logging {
            acceptance_logging = true;
        } else if argument == "--helper-epoch" && helper_epoch.is_none() {
            let epoch = arguments.next().and_then(|value| value.into_string().ok());
            helper_epoch = epoch.filter(|value| {
                !value.is_empty()
                    && value.bytes().all(|byte| byte.is_ascii_digit())
                    && value
                        .parse::<u64>()
                        .is_ok_and(|parsed| parsed.to_string() == *value)
            });
            if helper_epoch.is_none() {
                return Err(invalid_arguments());
            }
        } else {
            return Err(invalid_arguments());
        }
    }
    Ok(StartupArguments {
        helper_epoch: helper_epoch.ok_or_else(invalid_arguments)?,
        acceptance_logging,
    })
}

fn invalid_arguments() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "usage: omarchy-android-helper --helper-epoch DECIMAL [--acceptance-log]",
    )
}

fn open_acceptance_log(runtime_directory: &Path) -> io::Result<File> {
    create_private_file(&runtime_directory.join("acceptance.log"))
}
