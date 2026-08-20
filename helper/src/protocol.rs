use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use crate::{
    actions::PhoneTarget,
    input::{AndroidKey, DisplayGeometry, NormalizedPoint},
    preferences::{Preferences, PreviewScale, QuickAction, VideoQuality},
    scrcpy_config::ScrcpyConfiguration,
};

pub const PROTOCOL_VERSION: u8 = 11;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum FailureReason {
    DependencyUnavailable,
    Unauthorized,
    Disconnected,
    NetworkUnavailable,
    PairingRejected,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ActionFailureCode {
    InvalidTarget,
    TargetFailed,
    TargetTimedOut,
    InvalidDeadline,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ActionOutcome {
    Completed,
    Failed,
    StaleSession,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PhoneTargetFailure {
    ActionOnly(ActionFailureCode),
    Lifecycle(FailureReason),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PairingRequestFailure {
    InvalidState,
    Backend(FailureReason),
}

#[derive(Debug, Eq, PartialEq)]
pub struct QrPresentation {
    pub artifact: PathBuf,
    pub expires_in_seconds: u64,
}

pub trait PairingBackend {
    fn start_qr_pairing(&mut self) -> Result<QrPresentation, PairingRequestFailure>;
    fn cancel_pairing(&mut self);

    fn shutdown(&mut self) {
        self.cancel_pairing();
        self.stop_session();
    }

    fn submit_manual_code(&mut self, code: &str) -> Result<(), PairingRequestFailure>;

    fn has_trusted_device(&self) -> bool {
        false
    }

    fn session_generation(&self) -> u64 {
        0
    }

    fn acknowledge_preview_ready(
        &mut self,
        helper_epoch: &str,
        session_generation: u64,
    ) -> Result<(), FailureReason>;

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

    fn phone_target(
        &mut self,
        _target: PhoneTarget,
        _request_id: &str,
        _expires_at_unix_ms: u64,
    ) -> Result<(), PhoneTargetFailure> {
        Err(PhoneTargetFailure::ActionOnly(
            ActionFailureCode::TargetFailed,
        ))
    }

    fn preferences(&self) -> Preferences {
        Preferences::default()
    }

    fn set_preferences(&mut self, _preferences: Preferences) -> Result<bool, FailureReason> {
        Err(FailureReason::DependencyUnavailable)
    }

    fn scrcpy_configuration(&self) -> ScrcpyConfiguration {
        ScrcpyConfiguration::empty()
    }

    fn set_scrcpy_configuration(
        &mut self,
        _configuration: ScrcpyConfiguration,
        _screen_off_enabled: bool,
    ) -> Result<bool, FailureReason> {
        Err(FailureReason::DependencyUnavailable)
    }

    fn response_emitted(&mut self) {}
}

pub struct ProtocolEngine<B> {
    backend: B,
    helper_epoch: String,
}

impl<B> ProtocolEngine<B> {
    #[must_use]
    pub fn new(backend: B, helper_epoch: impl Into<String>) -> Self {
        Self {
            backend,
            helper_epoch: helper_epoch.into(),
        }
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
    pub fn handle_line(&mut self, line: &str) -> Vec<Event> {
        let command = match parse_command(line) {
            Ok(command) => command,
            Err(reason) => return vec![self.protocol_error(reason)],
        };
        if matches!(
            &command,
            Command::PhoneTarget { request_id, .. } if !valid_request_id(request_id)
        ) {
            return vec![self.protocol_error(ProtocolErrorReason::InvalidCommand)];
        }
        if command.helper_epoch() != Some(self.helper_epoch.as_str()) {
            return vec![self.stale_result(command.request_id())];
        }
        if command.is_session_bound() {
            let generation = self.generation();
            if command.session_generation() != Some(generation.as_str()) {
                if matches!(command, Command::SetScrcpyArgs { .. }) {
                    return vec![Event::ScrcpyArgsStale {
                        helper_epoch: self.helper_epoch.clone(),
                        session_generation: generation,
                        revision: self.backend.scrcpy_configuration().revision().to_owned(),
                    }];
                }
                return vec![self.stale_result(command.request_id())];
            }
        }

        match command {
            Command::StartQrPairing { .. } => vec![match self.backend.start_qr_pairing() {
                Ok(presentation) => Event::QrWaiting {
                    helper_epoch: self.helper_epoch.clone(),
                    artifact: presentation.artifact,
                    expires_in_seconds: presentation.expires_in_seconds,
                },
                Err(PairingRequestFailure::InvalidState) => {
                    self.protocol_error(ProtocolErrorReason::InvalidCommand)
                }
                Err(PairingRequestFailure::Backend(reason)) => self.failure(reason),
            }],
            Command::ReconnectTrustedDevice { .. } => {
                vec![match self.backend.reconnect_trusted_device() {
                    Ok(()) => self.session_event(SessionEvent::Connecting),
                    Err(reason) => self.failure(reason),
                }]
            }
            Command::StopSession { .. } => {
                self.backend.stop_session();
                vec![self.session_event(SessionEvent::Stopped)]
            }
            Command::StartOver { .. } => vec![match self.backend.start_over() {
                Ok(()) => self.session_event(SessionEvent::StartOverComplete),
                Err(reason) => self.failure(reason),
            }],
            Command::CancelPairing { .. } => {
                self.backend.cancel_pairing();
                vec![Event::PairingCancelled {
                    helper_epoch: self.helper_epoch.clone(),
                }]
            }
            Command::UseManualCode { .. } => {
                self.backend.cancel_pairing();
                vec![Event::ManualCodeRequired {
                    helper_epoch: self.helper_epoch.clone(),
                }]
            }
            Command::SubmitManualCode { code, .. } => {
                if code.len() != 6 || !code.bytes().all(|byte| byte.is_ascii_digit()) {
                    return vec![self.protocol_error(ProtocolErrorReason::InvalidCommand)];
                }
                match self.backend.submit_manual_code(code.as_str()) {
                    Ok(()) => vec![Event::Pairing {
                        helper_epoch: self.helper_epoch.clone(),
                        method: PairingMethod::ManualCode,
                    }],
                    Err(PairingRequestFailure::InvalidState) => {
                        vec![self.protocol_error(ProtocolErrorReason::InvalidCommand)]
                    }
                    Err(PairingRequestFailure::Backend(reason)) => vec![
                        Event::Pairing {
                            helper_epoch: self.helper_epoch.clone(),
                            method: PairingMethod::ManualCode,
                        },
                        self.failure(reason),
                    ],
                }
            }
            Command::PreviewReady {
                helper_epoch: Some(helper_epoch),
                session_generation: Some(session_generation),
            } => {
                let Ok(session_generation) = session_generation.parse::<u64>() else {
                    return vec![self.protocol_error(ProtocolErrorReason::InvalidCommand)];
                };
                let _ = self
                    .backend
                    .acknowledge_preview_ready(&helper_epoch, session_generation);
                Vec::new()
            }
            Command::PreviewReady { .. } => Vec::new(),
            Command::PointerTap {
                x,
                y,
                display_width,
                display_height,
                ..
            } => {
                let result = validate_geometry(display_width, display_height)
                    .zip(validate_point(x, y))
                    .ok_or(InputCommandFailure::Protocol(
                        ProtocolErrorReason::InvalidCommand,
                    ))
                    .and_then(|(geometry, point)| {
                        self.backend
                            .pointer_tap(geometry, point)
                            .map_err(InputCommandFailure::Backend)
                    });
                self.handle_input(result)
            }
            Command::PointerSwipe {
                start_x,
                start_y,
                end_x,
                end_y,
                display_width,
                display_height,
                duration_ms,
                ..
            } => {
                let result = validate_geometry(display_width, display_height)
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
                    });
                self.handle_input(result)
            }
            Command::KeyInput { key, .. } => {
                let result = self
                    .backend
                    .key_input(key)
                    .map_err(InputCommandFailure::Backend);
                self.handle_input(result)
            }
            Command::TextInput { text, .. } => {
                let result = validate_text(&text)
                    .ok_or(InputCommandFailure::Protocol(
                        ProtocolErrorReason::InvalidCommand,
                    ))
                    .and_then(|text| {
                        self.backend
                            .text_input(text)
                            .map_err(InputCommandFailure::Backend)
                    });
                self.handle_input(result)
            }
            Command::PhoneTarget {
                target,
                request_id,
                expires_at_unix_ms,
                session_generation,
                ..
            } => {
                let action_generation = session_generation.unwrap_or_else(|| self.generation());
                let Some(target) = target else {
                    return vec![self.action_result(
                        action_generation,
                        Some(request_id),
                        ActionOutcome::Failed,
                        Some(ActionFailureCode::InvalidTarget),
                    )];
                };
                match self
                    .backend
                    .phone_target(target, &request_id, expires_at_unix_ms)
                {
                    Ok(()) => vec![self.action_result(
                        action_generation,
                        Some(request_id),
                        ActionOutcome::Completed,
                        None,
                    )],
                    Err(PhoneTargetFailure::ActionOnly(code)) => vec![self.action_result(
                        action_generation,
                        Some(request_id),
                        ActionOutcome::Failed,
                        Some(code),
                    )],
                    Err(PhoneTargetFailure::Lifecycle(reason)) => vec![
                        self.action_result(
                            action_generation,
                            Some(request_id),
                            ActionOutcome::Failed,
                            Some(ActionFailureCode::TargetFailed),
                        ),
                        self.lifecycle_failure(reason),
                    ],
                }
            }
            Command::SetPreferences {
                keep_connected,
                preview_scale,
                video_quality,
                quick_actions,
                android_mode_shortcuts,
                ..
            } => vec![match self.backend.set_preferences(Preferences {
                keep_connected,
                preview_scale,
                video_quality,
                quick_actions,
                android_mode_shortcuts,
            }) {
                Ok(session_restarted) => Event::PreferencesUpdated {
                    helper_epoch: self.helper_epoch.clone(),
                    session_generation: self.generation(),
                    preferences: self.backend.preferences(),
                    session_restarted,
                },
                Err(reason) => self.failure(reason),
            }],
            Command::SetScrcpyArgs {
                arguments,
                expected_revision,
                new_revision,
                screen_off_enabled,
                ..
            } => {
                let current = self.backend.scrcpy_configuration();
                if current.revision() != expected_revision {
                    return vec![self.protocol_error(ProtocolErrorReason::InvalidCommand)];
                }
                let configuration = match arguments {
                    Some(arguments) => match ScrcpyConfiguration::validated(arguments) {
                        Ok(configuration)
                            if configuration.revision() == new_revision
                                && (!screen_off_enabled
                                    || configuration.screen_off_requested()) =>
                        {
                            configuration
                        }
                        _ => {
                            return vec![self.protocol_error(ProtocolErrorReason::InvalidCommand)];
                        }
                    },
                    None if screen_off_enabled
                        && new_revision == expected_revision
                        && current.screen_off_requested() =>
                    {
                        current
                    }
                    None => {
                        return vec![self.protocol_error(ProtocolErrorReason::InvalidCommand)];
                    }
                };
                vec![match self
                    .backend
                    .set_scrcpy_configuration(configuration.clone(), screen_off_enabled)
                {
                    Ok(session_restarted) => Event::ScrcpyArgsUpdated {
                        helper_epoch: self.helper_epoch.clone(),
                        session_generation: self.generation(),
                        revision: configuration.revision().to_owned(),
                        screen_off_enabled,
                        session_restarted,
                    },
                    Err(reason) => self.failure(reason),
                }]
            }
        }
    }

    fn generation(&self) -> String {
        self.backend.session_generation().to_string()
    }

    fn protocol_error(&self, reason: ProtocolErrorReason) -> Event {
        Event::ProtocolError {
            helper_epoch: self.helper_epoch.clone(),
            reason,
        }
    }

    fn failure(&self, reason: FailureReason) -> Event {
        Event::Failure {
            helper_epoch: self.helper_epoch.clone(),
            reason,
        }
    }

    fn lifecycle_failure(&self, reason: FailureReason) -> Event {
        Event::LifecycleFailure {
            helper_epoch: self.helper_epoch.clone(),
            session_generation: self.generation(),
            reason,
        }
    }

    fn session_event(&self, event: SessionEvent) -> Event {
        let helper_epoch = self.helper_epoch.clone();
        let session_generation = self.generation();
        match event {
            SessionEvent::Connecting => Event::Connecting {
                helper_epoch,
                session_generation,
            },
            SessionEvent::Stopped => Event::SessionStopped {
                helper_epoch,
                session_generation,
            },
            SessionEvent::StartOverComplete => Event::StartOverComplete {
                helper_epoch,
                session_generation,
            },
        }
    }

    fn action_result(
        &self,
        session_generation: String,
        request_id: Option<String>,
        outcome: ActionOutcome,
        notification_code: Option<ActionFailureCode>,
    ) -> Event {
        Event::ActionResult {
            helper_epoch: self.helper_epoch.clone(),
            session_generation,
            request_id,
            outcome,
            notification_code,
        }
    }

    fn stale_result(&self, request_id: Option<String>) -> Event {
        self.action_result(
            self.generation(),
            request_id,
            ActionOutcome::StaleSession,
            None,
        )
    }

    fn handle_input(&self, result: Result<(), InputCommandFailure>) -> Vec<Event> {
        match result {
            Ok(()) => Vec::new(),
            Err(InputCommandFailure::Protocol(reason)) => vec![self.protocol_error(reason)],
            Err(InputCommandFailure::Backend(reason)) => vec![self.lifecycle_failure(reason)],
        }
    }
}

enum SessionEvent {
    Connecting,
    Stopped,
    StartOverComplete,
}

enum InputCommandFailure {
    Protocol(ProtocolErrorReason),
    Backend(FailureReason),
}

fn validate_geometry(width: u32, height: u32) -> Option<DisplayGeometry> {
    DisplayGeometry::new(width, height)
}

fn validate_point(x: f64, y: f64) -> Option<NormalizedPoint> {
    NormalizedPoint::new(x, y)
}

fn validate_text(text: &str) -> Option<&str> {
    (!text.is_empty() && text.len() <= 256 && !text.chars().any(char::is_control)).then_some(text)
}

fn valid_request_id(request_id: &str) -> bool {
    !request_id.is_empty()
        && request_id.len() <= 64
        && request_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case", deny_unknown_fields)]
enum Command {
    StartQrPairing {
        #[serde(rename = "helperEpoch", default)]
        helper_epoch: Option<String>,
    },
    CancelPairing {
        #[serde(rename = "helperEpoch", default)]
        helper_epoch: Option<String>,
    },
    UseManualCode {
        #[serde(rename = "helperEpoch", default)]
        helper_epoch: Option<String>,
    },
    SubmitManualCode {
        #[serde(rename = "helperEpoch", default)]
        helper_epoch: Option<String>,
        #[serde(deserialize_with = "deserialize_zeroizing_string")]
        code: Zeroizing<String>,
    },
    ReconnectTrustedDevice {
        #[serde(rename = "helperEpoch", default)]
        helper_epoch: Option<String>,
    },
    StopSession {
        #[serde(rename = "helperEpoch", default)]
        helper_epoch: Option<String>,
        #[serde(rename = "sessionGeneration", default)]
        session_generation: Option<String>,
    },
    StartOver {
        #[serde(rename = "helperEpoch", default)]
        helper_epoch: Option<String>,
        #[serde(rename = "sessionGeneration", default)]
        session_generation: Option<String>,
    },
    PreviewReady {
        #[serde(rename = "helperEpoch", default)]
        helper_epoch: Option<String>,
        #[serde(rename = "sessionGeneration", default)]
        session_generation: Option<String>,
    },
    PointerTap {
        #[serde(rename = "helperEpoch", default)]
        helper_epoch: Option<String>,
        #[serde(rename = "sessionGeneration", default)]
        session_generation: Option<String>,
        x: f64,
        y: f64,
        #[serde(rename = "displayWidth")]
        display_width: u32,
        #[serde(rename = "displayHeight")]
        display_height: u32,
    },
    PointerSwipe {
        #[serde(rename = "helperEpoch", default)]
        helper_epoch: Option<String>,
        #[serde(rename = "sessionGeneration", default)]
        session_generation: Option<String>,
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
        #[serde(rename = "helperEpoch", default)]
        helper_epoch: Option<String>,
        #[serde(rename = "sessionGeneration", default)]
        session_generation: Option<String>,
        key: AndroidKey,
    },
    TextInput {
        #[serde(rename = "helperEpoch", default)]
        helper_epoch: Option<String>,
        #[serde(rename = "sessionGeneration", default)]
        session_generation: Option<String>,
        text: String,
    },
    PhoneTarget {
        #[serde(rename = "helperEpoch", default)]
        helper_epoch: Option<String>,
        #[serde(rename = "sessionGeneration", default)]
        session_generation: Option<String>,
        #[serde(rename = "requestId")]
        request_id: String,
        #[serde(rename = "expiresAtUnixMs")]
        expires_at_unix_ms: u64,
        #[serde(default, deserialize_with = "deserialize_phone_target")]
        target: Option<PhoneTarget>,
    },
    SetPreferences {
        #[serde(rename = "helperEpoch", default)]
        helper_epoch: Option<String>,
        #[serde(rename = "keepConnected")]
        keep_connected: bool,
        #[serde(rename = "previewScale")]
        preview_scale: PreviewScale,
        #[serde(rename = "videoQuality")]
        video_quality: VideoQuality,
        #[serde(rename = "quickActions")]
        quick_actions: [QuickAction; 3],
        #[serde(rename = "androidModeShortcuts")]
        android_mode_shortcuts: bool,
    },
    SetScrcpyArgs {
        #[serde(rename = "helperEpoch", default)]
        helper_epoch: Option<String>,
        #[serde(rename = "sessionGeneration", default)]
        session_generation: Option<String>,
        #[serde(default)]
        arguments: Option<Vec<String>>,
        #[serde(rename = "expectedRevision")]
        expected_revision: String,
        #[serde(rename = "newRevision")]
        new_revision: String,
        #[serde(rename = "screenOffEnabled")]
        screen_off_enabled: bool,
    },
}

impl Command {
    fn helper_epoch(&self) -> Option<&str> {
        match self {
            Self::StartQrPairing { helper_epoch }
            | Self::CancelPairing { helper_epoch }
            | Self::UseManualCode { helper_epoch }
            | Self::SubmitManualCode { helper_epoch, .. }
            | Self::ReconnectTrustedDevice { helper_epoch }
            | Self::StopSession { helper_epoch, .. }
            | Self::StartOver { helper_epoch, .. }
            | Self::PreviewReady { helper_epoch, .. }
            | Self::PointerTap { helper_epoch, .. }
            | Self::PointerSwipe { helper_epoch, .. }
            | Self::KeyInput { helper_epoch, .. }
            | Self::TextInput { helper_epoch, .. }
            | Self::PhoneTarget { helper_epoch, .. }
            | Self::SetPreferences { helper_epoch, .. }
            | Self::SetScrcpyArgs { helper_epoch, .. } => helper_epoch.as_deref(),
        }
    }

    fn session_generation(&self) -> Option<&str> {
        match self {
            Self::StopSession {
                session_generation, ..
            }
            | Self::StartOver {
                session_generation, ..
            }
            | Self::PreviewReady {
                session_generation, ..
            }
            | Self::PointerTap {
                session_generation, ..
            }
            | Self::PointerSwipe {
                session_generation, ..
            }
            | Self::KeyInput {
                session_generation, ..
            }
            | Self::TextInput {
                session_generation, ..
            }
            | Self::PhoneTarget {
                session_generation, ..
            }
            | Self::SetScrcpyArgs {
                session_generation, ..
            } => session_generation.as_deref(),
            _ => None,
        }
    }

    fn is_session_bound(&self) -> bool {
        matches!(
            self,
            Self::StopSession { .. }
                | Self::StartOver { .. }
                | Self::PointerTap { .. }
                | Self::PreviewReady { .. }
                | Self::PointerSwipe { .. }
                | Self::KeyInput { .. }
                | Self::TextInput { .. }
                | Self::PhoneTarget { .. }
                | Self::SetScrcpyArgs { .. }
        )
    }

    fn request_id(&self) -> Option<String> {
        match self {
            Self::PhoneTarget { request_id, .. } => Some(request_id.clone()),
            _ => None,
        }
    }
}

fn deserialize_phone_target<'de, D>(deserializer: D) -> Result<Option<PhoneTarget>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = serde_json::Value::deserialize(deserializer)?;
    Ok(serde_json::from_value(value).ok())
}

fn deserialize_zeroizing_string<'de, D>(deserializer: D) -> Result<Zeroizing<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    String::deserialize(deserializer).map(Zeroizing::new)
}

fn take_pairing_code(value: &mut serde_json::Value) -> Option<Zeroizing<String>> {
    let object = value.as_object_mut()?;
    match object.remove("code") {
        Some(serde_json::Value::String(code)) => Some(Zeroizing::new(code)),
        Some(other) => {
            object.insert("code".to_owned(), other);
            None
        }
        None => None,
    }
}

fn parse_command(line: &str) -> Result<Command, ProtocolErrorReason> {
    let mut value: serde_json::Value =
        serde_json::from_str(line).map_err(|_| ProtocolErrorReason::InvalidCommand)?;
    let version = match value.get("version").and_then(serde_json::Value::as_u64) {
        Some(version) => version,
        None => {
            drop(take_pairing_code(&mut value));
            return Err(ProtocolErrorReason::InvalidCommand);
        }
    };
    if version != u64::from(PROTOCOL_VERSION) {
        drop(take_pairing_code(&mut value));
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

#[derive(Debug, Eq, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum Event {
    Ready {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
        #[serde(rename = "sessionGeneration")]
        session_generation: String,
        #[serde(rename = "hasTrustedDevice")]
        has_trusted_device: bool,
        preferences: Preferences,
        #[serde(rename = "scrcpyRevision")]
        scrcpy_revision: String,
        #[serde(rename = "screenOffRequested")]
        screen_off_requested: bool,
    },
    QrWaiting {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
        artifact: PathBuf,
        #[serde(rename = "expiresInSeconds")]
        expires_in_seconds: u64,
    },
    Pairing {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
        method: PairingMethod,
    },
    PairingCancelled {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
    },
    QrTimedOut {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
    },
    ManualCodeRequired {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
    },
    Paired {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
        #[serde(rename = "sessionGeneration")]
        session_generation: String,
    },
    Connecting {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
        #[serde(rename = "sessionGeneration")]
        session_generation: String,
    },
    Connected {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
        #[serde(rename = "sessionGeneration")]
        session_generation: String,
    },
    SessionStarting {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
        #[serde(rename = "sessionGeneration")]
        session_generation: String,
    },
    SessionStarted {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
        #[serde(rename = "sessionGeneration")]
        session_generation: String,
        #[serde(rename = "physicalWidthMm", skip_serializing_if = "Option::is_none")]
        physical_width_mm: Option<u16>,
        #[serde(rename = "physicalHeightMm", skip_serializing_if = "Option::is_none")]
        physical_height_mm: Option<u16>,
        #[serde(rename = "screenOffEnabled")]
        screen_off_enabled: bool,
    },
    SessionEnded {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
        #[serde(rename = "sessionGeneration")]
        session_generation: String,
    },
    SessionStopped {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
        #[serde(rename = "sessionGeneration")]
        session_generation: String,
    },
    StartOverComplete {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
        #[serde(rename = "sessionGeneration")]
        session_generation: String,
    },
    PreferencesUpdated {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
        #[serde(rename = "sessionGeneration")]
        session_generation: String,
        preferences: Preferences,
        #[serde(rename = "sessionRestarted")]
        session_restarted: bool,
    },
    ScrcpyArgsUpdated {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
        #[serde(rename = "sessionGeneration")]
        session_generation: String,
        revision: String,
        #[serde(rename = "screenOffEnabled")]
        screen_off_enabled: bool,
        #[serde(rename = "sessionRestarted")]
        session_restarted: bool,
    },
    ScrcpyArgsStale {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
        #[serde(rename = "sessionGeneration")]
        session_generation: String,
        revision: String,
    },
    Failure {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
        reason: FailureReason,
    },
    LifecycleFailure {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
        #[serde(rename = "sessionGeneration")]
        session_generation: String,
        reason: FailureReason,
    },
    ActionResult {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
        #[serde(rename = "sessionGeneration")]
        session_generation: String,
        #[serde(rename = "requestId", skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
        outcome: ActionOutcome,
        #[serde(rename = "notificationCode", skip_serializing_if = "Option::is_none")]
        notification_code: Option<ActionFailureCode>,
    },
    ProtocolError {
        #[serde(rename = "helperEpoch")]
        helper_epoch: String,
        reason: ProtocolErrorReason,
    },
}

impl Event {
    #[must_use]
    #[expect(
        clippy::expect_used,
        reason = "the closed Event enum contains no fallible custom serializers"
    )]
    pub fn to_line(&self) -> String {
        serde_json::to_string(&EventEnvelope {
            version: PROTOCOL_VERSION,
            event: self,
        })
        .expect("protocol events contain only serializable enum values")
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PairingEvent {
    Pairing { method: PairingMethod },
    PairingCancelled,
    QrTimedOut,
    Paired,
    Connected,
    Failure { reason: FailureReason },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum PairingMethod {
    Qr,
    ManualCode,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProtocolErrorReason {
    InvalidCommand,
    VersionMismatch,
}

#[cfg(test)]
mod pairing_code_zeroize_tests {
    use super::{Command, parse_command, take_pairing_code};
    use zeroize::Zeroizing;

    #[test]
    fn parse_command_wraps_manual_code_before_epoch_admission() {
        let command = parse_command(
            r#"{"version":11,"type":"submit-manual-code","helperEpoch":"stale-epoch","code":"482913"}"#,
        )
        .expect("stale helper epoch still deserializes");
        match command {
            Command::SubmitManualCode { code, helper_epoch } => {
                let code: &Zeroizing<String> = &code;
                assert_eq!(code.as_str(), "482913");
                assert_eq!(helper_epoch.as_deref(), Some("stale-epoch"));
            }
            _ => panic!("expected submit-manual-code"),
        }
    }

    #[test]
    fn version_mismatch_takes_pairing_code_out_of_json_value() {
        let mut value = serde_json::json!({
            "version": 10,
            "type": "submit-manual-code",
            "helperEpoch": "73001",
            "code": "482913"
        });
        let code = take_pairing_code(&mut value).expect("code present");
        assert_eq!(code.as_str(), "482913");
        assert!(value.get("code").is_none());
    }
}
