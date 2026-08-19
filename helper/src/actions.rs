//! Typed, fail-closed Android targets and their selected-device adapters.

use serde::{Deserialize, Deserializer};

use crate::{
    input::AndroidKey,
    process::{ActionExecutionFailure, CancellationToken, CommandRequest, CommandRunner},
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PhoneTarget {
    BrowserDefault,
    NavigateHome,
    NavigateBack,
    RecentApps,
    AppLaunch { package: String },
    KeyEvent { key: AndroidKey },
}

#[derive(Deserialize)]
#[serde(untagged)]
enum PhoneTargetWire {
    Named(NamedPhoneTarget),
    AppLaunch(AppLaunchTarget),
    KeyEvent(KeyEventTarget),
}

#[derive(Deserialize)]
enum NamedPhoneTarget {
    #[serde(rename = "android.browser.default")]
    BrowserDefault,
    #[serde(rename = "android.navigate.home")]
    NavigateHome,
    #[serde(rename = "android.navigate.back")]
    NavigateBack,
    #[serde(rename = "android.recent-apps")]
    RecentApps,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AppLaunchTarget {
    #[serde(rename = "type")]
    target_type: AppLaunchType,
    package: String,
}

#[derive(Deserialize)]
enum AppLaunchType {
    #[serde(rename = "android.app.launch")]
    AppLaunch,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct KeyEventTarget {
    #[serde(rename = "type")]
    target_type: KeyEventType,
    key: AndroidKey,
}

#[derive(Deserialize)]
enum KeyEventType {
    #[serde(rename = "android.keyevent")]
    KeyEvent,
}

impl<'de> Deserialize<'de> for PhoneTarget {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        match PhoneTargetWire::deserialize(deserializer)? {
            PhoneTargetWire::Named(NamedPhoneTarget::BrowserDefault) => Ok(Self::BrowserDefault),
            PhoneTargetWire::Named(NamedPhoneTarget::NavigateHome) => Ok(Self::NavigateHome),
            PhoneTargetWire::Named(NamedPhoneTarget::NavigateBack) => Ok(Self::NavigateBack),
            PhoneTargetWire::Named(NamedPhoneTarget::RecentApps) => Ok(Self::RecentApps),
            PhoneTargetWire::AppLaunch(AppLaunchTarget {
                target_type: AppLaunchType::AppLaunch,
                package,
            }) if valid_android_package(&package) => Ok(Self::AppLaunch { package }),
            PhoneTargetWire::AppLaunch(_) => {
                Err(serde::de::Error::custom("invalid Android package"))
            }
            PhoneTargetWire::KeyEvent(KeyEventTarget {
                target_type: KeyEventType::KeyEvent,
                key,
            }) => Ok(Self::KeyEvent { key }),
        }
    }
}

#[must_use]
pub fn valid_android_package(package: &str) -> bool {
    package.len() <= 255
        && package.split('.').count() >= 2
        && package.split('.').all(|segment| {
            let mut characters = segment.chars();
            characters
                .next()
                .is_some_and(|first| first.is_ascii_alphabetic())
                && characters.all(|character| character.is_ascii_alphanumeric() || character == '_')
        })
}

pub struct AdbActionAdapter<'a> {
    runner: &'a mut dyn CommandRunner,
    cancellation: &'a CancellationToken,
}

impl<'a> AdbActionAdapter<'a> {
    pub fn new(runner: &'a mut dyn CommandRunner, cancellation: &'a CancellationToken) -> Self {
        Self {
            runner,
            cancellation,
        }
    }

    pub fn execute(
        &mut self,
        selected_device: &str,
        target: &PhoneTarget,
    ) -> Result<bool, ActionExecutionFailure> {
        let arguments = match target {
            PhoneTarget::BrowserDefault => {
                return self.launch_default_browser(selected_device);
            }
            PhoneTarget::NavigateHome => key_arguments(selected_device, AndroidKey::Home),
            PhoneTarget::NavigateBack => key_arguments(selected_device, AndroidKey::Back),
            PhoneTarget::RecentApps => key_arguments(selected_device, AndroidKey::AppSwitch),
            PhoneTarget::AppLaunch { package } => {
                if !valid_android_package(package) {
                    return Ok(false);
                }
                app_launch_arguments(selected_device, package)
            }
            PhoneTarget::KeyEvent { key } => key_arguments(selected_device, *key),
        };
        self.runner
            .run_phone_target(CommandRequest::new("adb", arguments), self.cancellation)
            .map(|output| output.succeeded)
    }

    fn launch_default_browser(
        &mut self,
        selected_device: &str,
    ) -> Result<bool, ActionExecutionFailure> {
        let captured = self.runner.run_captured_phone_target(
            CommandRequest::new(
                "adb",
                [
                    "-s",
                    selected_device,
                    "shell",
                    "cmd",
                    "role",
                    "get-role-holders",
                    "android.app.role.BROWSER",
                ]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            ),
            self.cancellation,
        )?;
        if !captured.succeeded {
            return Ok(false);
        }
        let Some(package) = first_valid_role_holder(&captured.stdout) else {
            return Ok(false);
        };
        self.runner
            .run_phone_target(
                CommandRequest::new("adb", app_launch_arguments(selected_device, package)),
                self.cancellation,
            )
            .map(|output| output.succeeded)
    }
}

fn key_arguments(selected_device: &str, key: AndroidKey) -> Vec<String> {
    [
        "-s",
        selected_device,
        "shell",
        "input",
        "keyevent",
        key.keycode(),
    ]
    .into_iter()
    .map(str::to_owned)
    .collect()
}

fn app_launch_arguments(selected_device: &str, package: &str) -> Vec<String> {
    [
        "-s",
        selected_device,
        "shell",
        "monkey",
        "-p",
        package,
        "-c",
        "android.intent.category.LAUNCHER",
        "1",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect()
}

fn first_valid_role_holder(stdout: &str) -> Option<&str> {
    stdout.lines().find_map(|line| {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            return None;
        }
        if valid_android_package(trimmed) {
            return Some(trimmed);
        }
        trimmed
            .split_whitespace()
            .next()
            .filter(|token| valid_android_package(token))
    })
}
