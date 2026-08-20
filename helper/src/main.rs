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
use zeroize::Zeroize;

use droid_peek_helper::{
    persistence::default_state_directory,
    private_fs::create_private_file,
    protocol::{Event, PairingBackend, ProtocolEngine},
    runtime::{
        AcceptanceEventWriter, ProtocolSink, RuntimePairingBackend, WriterProtocolSink,
        default_runtime_directory,
    },
    scrcpy_config::{FileScrcpyConfigStore, ScrcpyConfiguration, decode_arguments_envelope},
    session::run_scrcpy_guardian,
};

fn main() -> io::Result<()> {
    if run_version_request()? {
        return Ok(());
    }
    if run_scrcpy_guardian(env::args_os().skip(1))? {
        return Ok(());
    }
    if run_store_scrcpy_arguments()? {
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
    let scrcpy_configuration = backend.scrcpy_configuration();
    let mut engine = ProtocolEngine::new(backend, &arguments.helper_epoch);

    sink.emit_event(&Event::Ready {
        helper_epoch: arguments.helper_epoch,
        session_generation: "0".to_owned(),
        has_trusted_device,
        preferences,
        scrcpy_revision: scrcpy_configuration.revision().to_owned(),
        screen_off_requested: scrcpy_configuration.screen_off_requested(),
    })?;
    let result = (|| {
        for line in stdin.lock().lines() {
            let mut line = line?;
            for event in engine.handle_line(&line) {
                sink.emit_event(&event)?;
            }
            line.zeroize();
            engine.response_emitted();
        }
        Ok(())
    })();
    engine.into_backend().shutdown();
    result
}

fn run_version_request() -> io::Result<bool> {
    let mut arguments = env::args_os().skip(1);
    if arguments.next().as_deref() != Some(std::ffi::OsStr::new("--version")) {
        return Ok(false);
    }
    if arguments.next().is_some() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "usage: droid-peek-helper --version",
        ));
    }
    println!("{}", env!("CARGO_PKG_VERSION"));
    Ok(true)
}

fn run_store_scrcpy_arguments() -> io::Result<bool> {
    let mut arguments = env::args_os().skip(1);
    if arguments.next().as_deref() != Some(std::ffi::OsStr::new("store-scrcpy-args")) {
        return Ok(false);
    }
    let encoded = arguments
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or_else(invalid_store_arguments)?;
    if arguments.next().is_some() {
        return Err(invalid_store_arguments());
    }
    let state_directory = default_state_directory().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "XDG_STATE_HOME and HOME are unavailable",
        )
    })?;
    let configuration = ScrcpyConfiguration::validated(decode_arguments_envelope(&encoded)?)
        .map_err(|_| invalid_store_arguments())?;
    FileScrcpyConfigStore::new(state_directory).store(&configuration)?;
    println!("{}", configuration.revision());
    Ok(true)
}

fn invalid_store_arguments() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "usage: droid-peek-helper store-scrcpy-args BASE64URL_JSON",
    )
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
        "usage: droid-peek-helper --helper-epoch DECIMAL [--acceptance-log]",
    )
}

fn open_acceptance_log(runtime_directory: &Path) -> io::Result<File> {
    create_private_file(&runtime_directory.join("acceptance.log"))
}
