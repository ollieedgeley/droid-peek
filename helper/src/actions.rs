//! Typed, fail-closed Android targets and their selected-device adapters.

use serde::{Deserialize, Deserializer};

use crate::process::{CancellationToken, CommandFailure, CommandRequest, CommandRunner};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PhoneTarget {
    BrowserDefault,
    NavigateHome,
    NavigateBack,
    RecentApps,
    AppLaunch { package: String },
}

#[derive(Deserialize)]
#[serde(untagged)]
enum PhoneTargetWire {
    Named(NamedPhoneTarget),
    AppLaunch(AppLaunchTarget),
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
    ) -> Result<bool, CommandFailure> {
        let arguments = match target {
            PhoneTarget::BrowserDefault => vec![
                "-s",
                selected_device,
                "shell",
                "am",
                "start",
                "-W",
                "-a",
                "android.intent.action.MAIN",
                "-c",
                "android.intent.category.APP_BROWSER",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
            PhoneTarget::NavigateHome => key_arguments(selected_device, "KEYCODE_HOME"),
            PhoneTarget::NavigateBack => key_arguments(selected_device, "KEYCODE_BACK"),
            PhoneTarget::RecentApps => key_arguments(selected_device, "KEYCODE_APP_SWITCH"),
            PhoneTarget::AppLaunch { package } => {
                if !valid_android_package(package) {
                    return Ok(false);
                }
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
        };
        self.runner
            .run(CommandRequest::new("adb", arguments), self.cancellation)
            .map(|output| output.succeeded)
    }
}

fn key_arguments(selected_device: &str, keycode: &str) -> Vec<String> {
    ["-s", selected_device, "shell", "input", "keyevent", keycode]
        .into_iter()
        .map(str::to_owned)
        .collect()
}
