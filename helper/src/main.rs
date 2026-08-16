use std::{
    env, fs,
    fs::{File, OpenOptions},
    io::{self, BufRead},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::Path,
    time::Duration,
};

use omarchy_android_helper::{
    protocol::{Event, ProtocolEngine},
    runtime::{
        AcceptanceEventWriter, ProtocolSink, RuntimePairingBackend, WriterProtocolSink,
        default_runtime_directory,
    },
};

fn main() -> io::Result<()> {
    let stdin = io::stdin();
    let runtime_directory = default_runtime_directory();
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
    let backend =
        RuntimePairingBackend::new(&runtime_directory, Duration::from_secs(120), sink.clone())?;
    let mut engine = ProtocolEngine::new(backend);

    sink.emit_event(&Event::Ready)?;
    for line in stdin.lock().lines() {
        for event in engine.handle_line(&line?) {
            sink.emit_line(&event)?;
        }
        engine.response_emitted();
    }

    Ok(())
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
    fs::create_dir_all(runtime_directory)?;
    fs::set_permissions(runtime_directory, fs::Permissions::from_mode(0o700))?;
    OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(runtime_directory.join("acceptance.log"))
}
