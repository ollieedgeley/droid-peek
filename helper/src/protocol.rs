use zeroize::Zeroizing;

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

pub const PROTOCOL_VERSION: u8 = 1;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum FailureReason {
    DependencyUnavailable,
    Unauthorized,
    Disconnected,
    NetworkUnavailable,
    PairingRejected,
}

#[derive(Debug, Eq, PartialEq)]
pub struct QrPresentation {
    pub artifact: PathBuf,
    pub expires_in_seconds: u64,
}

pub trait PairingBackend {
    fn start_qr_pairing(&mut self) -> Result<QrPresentation, FailureReason>;
    fn cancel_pairing(&mut self);
    fn submit_manual_code(&mut self, code: &str) -> Result<(), FailureReason>;

    fn response_emitted(&mut self) {}
}

pub struct ProtocolEngine<B> {
    backend: B,
}

impl<B> ProtocolEngine<B> {
    #[must_use]
    pub fn new(backend: B) -> Self {
        Self { backend }
    }

    #[must_use]
    pub fn into_backend(self) -> B {
        self.backend
    }

    /// Notifies the backend only after the caller has written the synchronous
    /// command response, preserving protocol event order for background work.
    pub fn response_emitted(&mut self)
    where
        B: PairingBackend,
    {
        self.backend.response_emitted();
    }
}

impl<B: PairingBackend> ProtocolEngine<B> {
    #[must_use]
    pub fn handle_line(&mut self, line: &str) -> Vec<String> {
        let command = match parse_command(line) {
            Ok(command) => command,
            Err(reason) => return vec![Event::ProtocolError { reason }.to_line()],
        };

        match command {
            Command::StartQrPairing => vec![
                match self.backend.start_qr_pairing() {
                    Ok(presentation) => Event::QrWaiting {
                        artifact: presentation.artifact,
                        expires_in_seconds: presentation.expires_in_seconds,
                    },
                    Err(reason) => Event::Failure { reason },
                }
                .to_line(),
            ],
            Command::CancelPairing => {
                self.backend.cancel_pairing();
                vec![Event::PairingCancelled.to_line()]
            }
            Command::UseManualCode => {
                self.backend.cancel_pairing();
                vec![Event::ManualCodeRequired.to_line()]
            }
            Command::SubmitManualCode { code } => {
                let code = Zeroizing::new(code);
                let mut events = vec![
                    Event::Pairing {
                        method: PairingMethod::ManualCode,
                    }
                    .to_line(),
                ];
                if let Err(reason) = self.backend.submit_manual_code(&code) {
                    events.push(Event::Failure { reason }.to_line());
                }
                events
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case", deny_unknown_fields)]
enum Command {
    StartQrPairing,
    CancelPairing,
    UseManualCode,
    SubmitManualCode { code: String },
}

fn parse_command(line: &str) -> Result<Command, ProtocolErrorReason> {
    let mut value: serde_json::Value =
        serde_json::from_str(line).map_err(|_| ProtocolErrorReason::InvalidCommand)?;
    let version = value
        .get("version")
        .and_then(serde_json::Value::as_u64)
        .ok_or(ProtocolErrorReason::InvalidCommand)?;

    if version != u64::from(PROTOCOL_VERSION) {
        return Err(ProtocolErrorReason::VersionMismatch);
    }

    value
        .as_object_mut()
        .ok_or(ProtocolErrorReason::InvalidCommand)?
        .remove("version");
    serde_json::from_value(value).map_err(|_| ProtocolErrorReason::InvalidCommand)
}

#[derive(Serialize)]
struct EventEnvelope<'a> {
    version: u8,
    #[serde(flatten)]
    event: &'a Event,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum Event {
    Ready,
    QrWaiting {
        artifact: PathBuf,
        #[serde(rename = "expiresInSeconds")]
        expires_in_seconds: u64,
    },
    Pairing {
        method: PairingMethod,
    },
    PairingCancelled,
    QrTimedOut,
    ManualCodeRequired,
    Paired,
    Failure {
        reason: FailureReason,
    },
    ProtocolError {
        reason: ProtocolErrorReason,
    },
}

impl Event {
    #[must_use]
    pub fn to_line(&self) -> String {
        serde_json::to_string(&EventEnvelope {
            version: PROTOCOL_VERSION,
            event: self,
        })
        .expect("protocol events contain only serializable enum values")
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum PairingMethod {
    Qr,
    ManualCode,
}

#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProtocolErrorReason {
    InvalidCommand,
    VersionMismatch,
}
