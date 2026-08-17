//! Android input translation over the existing, fakeable ADB process boundary.

use crate::process::{CancellationToken, CommandFailure, CommandRequest, CommandRunner};
use serde::Deserialize;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DisplayGeometry {
    width: u32,
    height: u32,
}

impl DisplayGeometry {
    #[must_use]
    pub fn new(width: u32, height: u32) -> Option<Self> {
        (width > 0 && height > 0).then_some(Self { width, height })
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct NormalizedPoint {
    x: f64,
    y: f64,
}

impl NormalizedPoint {
    #[must_use]
    pub fn new(x: f64, y: f64) -> Option<Self> {
        (x.is_finite() && y.is_finite() && (0.0..=1.0).contains(&x) && (0.0..=1.0).contains(&y))
            .then_some(Self { x, y })
    }

    #[must_use]
    pub fn to_pixels(self, geometry: DisplayGeometry) -> (u32, u32) {
        (
            (self.x * f64::from(geometry.width - 1)).round() as u32,
            (self.y * f64::from(geometry.height - 1)).round() as u32,
        )
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum AndroidKey {
    Back,
    Home,
    AppSwitch,
    Enter,
    Delete,
    Escape,
    ArrowUp,
    ArrowDown,
    ArrowLeft,
    ArrowRight,
    Tab,
    Space,
}

impl AndroidKey {
    fn keycode(self) -> &'static str {
        match self {
            Self::Back => "KEYCODE_BACK",
            Self::Home => "KEYCODE_HOME",
            Self::AppSwitch => "KEYCODE_APP_SWITCH",
            Self::Enter => "KEYCODE_ENTER",
            Self::Delete => "KEYCODE_DEL",
            Self::Escape => "KEYCODE_ESCAPE",
            Self::ArrowUp => "KEYCODE_DPAD_UP",
            Self::ArrowDown => "KEYCODE_DPAD_DOWN",
            Self::ArrowLeft => "KEYCODE_DPAD_LEFT",
            Self::ArrowRight => "KEYCODE_DPAD_RIGHT",
            Self::Tab => "KEYCODE_TAB",
            Self::Space => "KEYCODE_SPACE",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InputFailure {
    DependencyUnavailable,
    Disconnected,
    Cancelled,
}

pub struct AdbInputAdapter<'a> {
    runner: &'a mut dyn CommandRunner,
    cancellation: &'a CancellationToken,
}

impl<'a> AdbInputAdapter<'a> {
    pub fn new(runner: &'a mut dyn CommandRunner, cancellation: &'a CancellationToken) -> Self {
        Self {
            runner,
            cancellation,
        }
    }

    pub fn tap(
        &mut self,
        target: &str,
        geometry: DisplayGeometry,
        point: NormalizedPoint,
    ) -> Result<(), InputFailure> {
        let (x, y) = point.to_pixels(geometry);
        self.run(target, ["tap".to_owned(), x.to_string(), y.to_string()])
    }

    pub fn swipe(
        &mut self,
        target: &str,
        geometry: DisplayGeometry,
        start: NormalizedPoint,
        end: NormalizedPoint,
        duration_ms: u32,
    ) -> Result<(), InputFailure> {
        let (start_x, start_y) = start.to_pixels(geometry);
        let (end_x, end_y) = end.to_pixels(geometry);
        self.run(
            target,
            [
                "swipe".to_owned(),
                start_x.to_string(),
                start_y.to_string(),
                end_x.to_string(),
                end_y.to_string(),
                duration_ms.to_string(),
            ],
        )
    }

    pub fn key(&mut self, target: &str, key: AndroidKey) -> Result<(), InputFailure> {
        self.run(target, ["keyevent".to_owned(), key.keycode().to_owned()])
    }

    pub fn text(&mut self, target: &str, text: &str) -> Result<(), InputFailure> {
        let mut remainder = text;
        while let Some(index) = remainder.find("%s") {
            let split = index + 1;
            self.run_text_fragment(target, &remainder[..split])?;
            remainder = &remainder[split..];
        }
        if !remainder.is_empty() || text.is_empty() {
            self.run_text_fragment(target, remainder)?;
        }
        Ok(())
    }

    fn run_text_fragment(&mut self, target: &str, text: &str) -> Result<(), InputFailure> {
        let encoded = text.replace(' ', "%s");
        let quoted = format!("'{}'", encoded.replace('\'', "'\\''"));
        self.run(target, ["text".to_owned(), quoted])
    }

    fn run<const N: usize>(
        &mut self,
        target: &str,
        input_arguments: [String; N],
    ) -> Result<(), InputFailure> {
        let mut arguments = Vec::with_capacity(N + 4);
        arguments.extend([
            "-s".to_owned(),
            target.to_owned(),
            "shell".to_owned(),
            "input".to_owned(),
        ]);
        arguments.extend(input_arguments);
        let output = self
            .runner
            .run(CommandRequest::new("adb", arguments), self.cancellation)
            .map_err(|failure| match failure {
                CommandFailure::DependencyUnavailable => InputFailure::DependencyUnavailable,
                CommandFailure::Unauthorized => InputFailure::Disconnected,
                CommandFailure::Cancelled => InputFailure::Cancelled,
            })?;
        if output.succeeded {
            Ok(())
        } else {
            Err(InputFailure::Disconnected)
        }
    }
}
