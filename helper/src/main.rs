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
};

fn main() -> io::Result<()> {
    let stdin = io::stdin();
    let runtime_directory = default_runtime_directory()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR is unavailable"))?;
    let state_directory = default_state_directory().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "XDG_STATE_HOME and HOME are unavailable",
        )
    })?;
    let log = if acceptance_logging_enabled()? {
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
        sink.clone(),
    )?;
    let has_trusted_device = backend.has_trusted_device();
    let preferences = backend.preferences();
    let mut engine = ProtocolEngine::new(backend);

    sink.emit_event(&Event::Ready {
        has_trusted_device,
        preferences,
    })?;
    let result = (|| {
        for line in stdin.lock().lines() {
            for event in engine.handle_line(&line?) {
                sink.emit_line(&event)?;
            }
            engine.response_emitted();
        }
        Ok(())
    })();
    engine.into_backend().shutdown();
    result
}

fn acceptance_logging_enabled() -> io::Result<bool> {
    let mut arguments = env::args_os().skip(1);
    match (arguments.next(), arguments.next()) {
        (None, None) => Ok(false),
        (Some(argument), None) if argument == "--acceptance-log" => Ok(true),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "usage: omarchy-android-helper [--acceptance-log]",
        )),
    }
}

fn open_acceptance_log(runtime_directory: &Path) -> io::Result<File> {
    create_private_file(&runtime_directory.join("acceptance.log"))
}
