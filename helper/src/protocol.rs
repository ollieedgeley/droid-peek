use zeroize::Zeroizing;

use crate::{
    action_results::validate_request_id,
    actions::{SemanticAction, valid_android_package},
    input::{AndroidKey, DisplayGeometry, NormalizedPoint},
    preferences::Preferences,
};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

pub const PROTOCOL_VERSION: u8 = 10;

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

    fn start_over(&mut self) -> Result<(), FailureReason> {
        Err(FailureReason::Disconnected)
    }

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

    fn semantic_action(
        &mut self,
        _action: SemanticAction,
        _action_argument: Option<&str>,
        _request_id: &str,
        _expires_at_unix_ms: u64,
    ) -> Result<bool, FailureReason> {
        Ok(false)
    }

    fn preferences(&self) -> Preferences {
        Preferences::default()
    }

    fn set_preferences(&mut self, _preferences: Preferences) -> Result<bool, FailureReason> {
        Err(FailureReason::DependencyUnavailable)
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
            Command::StartOver => vec![
                match self.backend.start_over() {
                    Ok(()) => Event::StartOverComplete,
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
            Command::SemanticAction {
                action_id,
                action_argument,
                request_id,
                expires_at_unix_ms,
            } => {
                let action_argument =
                    validate_action_argument(action_id, action_argument.as_deref());
                if validate_request_id(&request_id).is_err() || action_argument.is_none() {
                    return vec![
                        Event::ProtocolError {
                            reason: ProtocolErrorReason::InvalidCommand,
                        }
                        .to_line(),
                    ];
                }
                match self.backend.semantic_action(
                    action_id,
                    action_argument.flatten(),
                    &request_id,
                    expires_at_unix_ms,
                ) {
                    Ok(handled) => vec![
                        Event::ActionResult {
                            action_id,
                            request_id,
                            handled,
                        }
                        .to_line(),
                    ],
                    Err(reason) => vec![
                        Event::ActionResult {
                            action_id,
                            request_id,
                            handled: false,
                        }
                        .to_line(),
                        Event::Failure { reason }.to_line(),
                    ],
                }
            }
            Command::SetPreferences {
                keep_connected,
                preview_scale,
                video_quality,
                quick_actions,
                android_mode_shortcuts,
                command_passthrough,
            } => vec![
                match self.backend.set_preferences(Preferences {
                    keep_connected,
                    preview_scale,
                    video_quality,
                    quick_actions,
                    android_mode_shortcuts,
                    command_passthrough,
                }) {
                    Ok(session_restarted) => Event::PreferencesUpdated {
                        preferences: self.backend.preferences(),
                        session_restarted,
                    },
                    Err(reason) => Event::Failure { reason },
                }
                .to_line(),
            ],
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

fn validate_action_argument(
    action: SemanticAction,
    argument: Option<&str>,
) -> Option<Option<&str>> {
    match action {
        SemanticAction::AndroidLaunchApp => argument
            .filter(|package| valid_android_package(package))
            .map(Some),
        _ => match argument {
            None | Some("") => Some(None),
            Some(_) => None,
        },
    }
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
    StartOver,
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
    SemanticAction {
        #[serde(rename = "actionId")]
        action_id: SemanticAction,
        #[serde(rename = "actionArgument", default)]
        action_argument: Option<String>,
        #[serde(rename = "requestId")]
        request_id: String,
        #[serde(rename = "expiresAtUnixMs")]
        expires_at_unix_ms: u64,
    },
    SetPreferences {
        #[serde(rename = "keepConnected")]
        keep_connected: bool,
        #[serde(rename = "previewScale")]
        preview_scale: crate::preferences::PreviewScale,
        #[serde(rename = "videoQuality")]
        video_quality: crate::preferences::VideoQuality,
        #[serde(rename = "quickActions")]
        quick_actions: [crate::preferences::QuickAction; 3],
        #[serde(rename = "androidModeShortcuts")]
        android_mode_shortcuts: bool,
        #[serde(rename = "commandPassthrough")]
        command_passthrough: bool,
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
        preferences: Preferences,
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
    SessionStarted {
        #[serde(rename = "physicalWidthMm", skip_serializing_if = "Option::is_none")]
        physical_width_mm: Option<u16>,
        #[serde(rename = "physicalHeightMm", skip_serializing_if = "Option::is_none")]
        physical_height_mm: Option<u16>,
    },
    SessionEnded,
    SessionStopped,
    StartOverComplete,
    PreferencesUpdated {
        #[serde(flatten)]
        preferences: Preferences,
        #[serde(rename = "sessionRestarted")]
        session_restarted: bool,
    },
    Failure {
        reason: FailureReason,
    },
    ActionResult {
        #[serde(rename = "actionId")]
        action_id: SemanticAction,
        #[serde(rename = "requestId")]
        request_id: String,
        handled: bool,
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
