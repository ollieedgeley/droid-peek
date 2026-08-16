use zeroize::Zeroizing;

use crate::input::{AndroidKey, DisplayGeometry, NormalizedPoint};
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

    fn has_trusted_device(&self) -> bool {
        false
    }

    fn reconnect_trusted_device(&mut self) -> Result<(), FailureReason> {
        Err(FailureReason::Disconnected)
    }

    fn stop_session(&mut self) {}

    fn pointer_tap(
        &mut self,
        _geometry: DisplayGeometry,
        _point: NormalizedPoint,
    ) -> Result<(), FailureReason> {
        Err(FailureReason::Disconnected)
    }

    fn pointer_swipe(
        &mut self,
        _geometry: DisplayGeometry,
        _start: NormalizedPoint,
        _end: NormalizedPoint,
        _duration_ms: u32,
    ) -> Result<(), FailureReason> {
        Err(FailureReason::Disconnected)
    }

    fn key_input(&mut self, _key: AndroidKey) -> Result<(), FailureReason> {
        Err(FailureReason::Disconnected)
    }

    fn text_input(&mut self, _text: &str) -> Result<(), FailureReason> {
        Err(FailureReason::Disconnected)
    }

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
            Command::ReconnectTrustedDevice => vec![
                match self.backend.reconnect_trusted_device() {
                    Ok(()) => Event::Connecting,
                    Err(reason) => Event::Failure { reason },
                }
                .to_line(),
            ],
            Command::StopSession => {
                self.backend.stop_session();
                vec![Event::SessionStopped.to_line()]
            }
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
                if let Err(reason) = self.backend.submit_manual_code(code.as_str()) {
                    events.push(Event::Failure { reason }.to_line());
                }
                events
            }
            Command::PointerTap {
                x,
                y,
                display_width,
                display_height,
            } => handle_input(
                validate_geometry(display_width, display_height)
                    .zip(validate_point(x, y))
                    .ok_or(InputCommandFailure::Protocol(
                        ProtocolErrorReason::InvalidCommand,
                    ))
                    .and_then(|(geometry, point)| {
                        self.backend
                            .pointer_tap(geometry, point)
                            .map_err(InputCommandFailure::Backend)
                    }),
            ),
            Command::PointerSwipe {
                start_x,
                start_y,
                end_x,
                end_y,
                display_width,
                display_height,
                duration_ms,
            } => handle_input(
                validate_geometry(display_width, display_height)
                    .zip(validate_point(start_x, start_y))
                    .zip(validate_point(end_x, end_y))
                    .filter(|_| (1..=60_000).contains(&duration_ms))
                    .ok_or(InputCommandFailure::Protocol(
                        ProtocolErrorReason::InvalidCommand,
                    ))
                    .and_then(|((geometry, start), end)| {
                        self.backend
                            .pointer_swipe(geometry, start, end, duration_ms)
                            .map_err(InputCommandFailure::Backend)
                    }),
            ),
            Command::KeyInput { key } => handle_input(
                self.backend
                    .key_input(key)
                    .map_err(InputCommandFailure::Backend),
            ),
            Command::TextInput { text } => handle_input(
                validate_text(&text)
                    .ok_or(InputCommandFailure::Protocol(
                        ProtocolErrorReason::InvalidCommand,
                    ))
                    .and_then(|text| {
                        self.backend
                            .text_input(text)
                            .map_err(InputCommandFailure::Backend)
                    }),
            ),
        }
    }
}

enum InputCommandFailure {
    Protocol(ProtocolErrorReason),
    Backend(FailureReason),
}

impl From<ProtocolErrorReason> for InputCommandFailure {
    fn from(reason: ProtocolErrorReason) -> Self {
        Self::Protocol(reason)
    }
}

fn handle_input(result: Result<(), InputCommandFailure>) -> Vec<String> {
    match result {
        Ok(()) => Vec::new(),
        Err(InputCommandFailure::Protocol(reason)) => {
            vec![Event::ProtocolError { reason }.to_line()]
        }
        Err(InputCommandFailure::Backend(reason)) => vec![Event::Failure { reason }.to_line()],
    }
}

fn validate_geometry(width: u32, height: u32) -> Option<DisplayGeometry> {
    DisplayGeometry::new(width, height)
}

fn validate_point(x: f64, y: f64) -> Option<NormalizedPoint> {
    NormalizedPoint::new(x, y)
}

fn validate_text(text: &str) -> Option<&str> {
    (!text.is_empty() && text.len() <= 256 && !text.chars().any(|character| character.is_control()))
        .then_some(text)
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case", deny_unknown_fields)]
enum Command {
    StartQrPairing,
    CancelPairing,
    UseManualCode,
    SubmitManualCode {
        code: String,
    },
    ReconnectTrustedDevice,
    StopSession,
    PointerTap {
        x: f64,
        y: f64,
        #[serde(rename = "displayWidth")]
        display_width: u32,
        #[serde(rename = "displayHeight")]
        display_height: u32,
    },
    PointerSwipe {
        #[serde(rename = "startX")]
        start_x: f64,
        #[serde(rename = "startY")]
        start_y: f64,
        #[serde(rename = "endX")]
        end_x: f64,
        #[serde(rename = "endY")]
        end_y: f64,
        #[serde(rename = "displayWidth")]
        display_width: u32,
        #[serde(rename = "displayHeight")]
        display_height: u32,
        #[serde(rename = "durationMs")]
        duration_ms: u32,
    },
    KeyInput {
        key: AndroidKey,
    },
    TextInput {
        text: String,
    },
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
    Ready {
        #[serde(rename = "hasTrustedDevice")]
        has_trusted_device: bool,
    },
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
    Connecting,
    Connected,
    SessionStarting,
    SessionStarted,
    SessionEnded,
    SessionStopped,
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
