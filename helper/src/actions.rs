//! Typed, fail-closed Android targets and their selected-device adapters.

use serde::{Deserialize, Deserializer};

use crate::{
    input::AndroidKey,
    process::{ActionExecutionFailure, CancellationToken, CommandRequest, CommandRunner},
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PhoneTarget {
    NavigateHome,
    NavigateBack,
    RecentApps,
    AppLaunch { package: String },
    ComponentLaunch { package: String, activity: String },
    KeyEvent { key: AndroidKey },
}

#[derive(Deserialize)]
#[serde(untagged)]
enum PhoneTargetWire {
    Named(NamedPhoneTarget),
    AppLaunch(AppLaunchTarget),
    ComponentLaunch(ComponentLaunchTarget),
    KeyEvent(KeyEventTarget),
}

#[derive(Deserialize)]
enum NamedPhoneTarget {
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
struct ComponentLaunchTarget {
    #[serde(rename = "type")]
    target_type: ComponentLaunchType,
    package: String,
    activity: String,
}

#[derive(Deserialize)]
enum ComponentLaunchType {
    #[serde(rename = "android.component.launch")]
    ComponentLaunch,
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
            PhoneTargetWire::ComponentLaunch(ComponentLaunchTarget {
                target_type: ComponentLaunchType::ComponentLaunch,
                package,
                activity,
            }) if !package.contains('\0') && !activity.contains('\0') => {
                Ok(Self::ComponentLaunch { package, activity })
            }
            PhoneTargetWire::ComponentLaunch(_) => {
                Err(serde::de::Error::custom("invalid Android component"))
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
            PhoneTarget::NavigateHome => key_arguments(selected_device, AndroidKey::Home),
            PhoneTarget::NavigateBack => key_arguments(selected_device, AndroidKey::Back),
            PhoneTarget::RecentApps => key_arguments(selected_device, AndroidKey::AppSwitch),
            PhoneTarget::AppLaunch { package } => {
                if !valid_android_package(package) {
                    return Ok(false);
                }
                app_launch_arguments(selected_device, package)
            }
            PhoneTarget::ComponentLaunch { package, activity } => {
                if package.contains('\0') || activity.contains('\0') {
                    return Ok(false);
                }
                component_launch_arguments(selected_device, package, activity)
            }
            PhoneTarget::KeyEvent { key } => key_arguments(selected_device, *key),
        };
        self.runner
            .run_phone_target(CommandRequest::new("adb", arguments), self.cancellation)
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

fn posix_shell_quote(value: &str) -> String {
    let mut quoted = String::with_capacity(value.len() + 2);
    quoted.push('\'');
    for character in value.chars() {
        if character == '\'' {
            quoted.push_str("'\\''");
        } else {
            quoted.push(character);
        }
    }
    quoted.push('\'');
    quoted
}

fn component_launch_arguments(selected_device: &str, package: &str, activity: &str) -> Vec<String> {
    let component = posix_shell_quote(&format!("{package}/{activity}"));
    [
        "-s",
        selected_device,
        "shell",
        "am",
        "start",
        "-n",
        component.as_str(),
    ]
    .into_iter()
    .map(str::to_owned)
    .collect()
}
