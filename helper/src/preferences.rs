use std::{
    fs,
    io::{self, Write},
    path::{Path, PathBuf},
};

use crate::private_fs::{atomic_replace, remove_file_if_present};
use serde::{Deserialize, Serialize};

const PREFERENCES_VERSION: u8 = 5;
const PREVIOUS_PREFERENCES_VERSION: u8 = 4;
const OLDER_PREFERENCES_VERSION: u8 = 3;
const PREFERENCES_FILE_NAME: &str = "preferences.json";
const LEGACY_PREFERENCES_VERSION: u8 = 2;
const LEGACY_PREFERENCES_FILE_NAME: &str = "render-preferences.json";

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(try_from = "u8", into = "u8")]
pub struct PreviewScale(u8);

impl PreviewScale {
    pub const MIN_PERCENT: u8 = 50;
    pub const MAX_PERCENT: u8 = 150;

    #[must_use]
    pub const fn new(percent: u8) -> Option<Self> {
        if percent >= Self::MIN_PERCENT && percent <= Self::MAX_PERCENT {
            Some(Self(percent))
        } else {
            None
        }
    }

    #[must_use]
    pub const fn percent(self) -> u8 {
        self.0
    }
}

impl Default for PreviewScale {
    fn default() -> Self {
        Self(100)
    }
}

impl TryFrom<u8> for PreviewScale {
    type Error = &'static str;

    fn try_from(percent: u8) -> Result<Self, Self::Error> {
        Self::new(percent).ok_or("preview scale must be between 50 and 150 percent")
    }
}

impl From<PreviewScale> for u8 {
    fn from(scale: PreviewScale) -> Self {
        scale.percent()
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum VideoQuality {
    Low,
    Medium,
    #[default]
    High,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum QuickAction {
    Back,
    Home,
    RecentApps,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Preferences {
    pub keep_connected: bool,
    pub android_mode_shortcuts: bool,
    pub command_passthrough: bool,
    pub preview_scale: PreviewScale,
    pub video_quality: VideoQuality,
    pub quick_actions: [QuickAction; 3],
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            keep_connected: false,
            android_mode_shortcuts: false,
            command_passthrough: false,
            preview_scale: PreviewScale::default(),
            video_quality: VideoQuality::High,
            quick_actions: [
                QuickAction::Back,
                QuickAction::Home,
                QuickAction::RecentApps,
            ],
        }
    }
}

#[derive(Clone)]
pub struct FilePreferenceStore {
    directory: PathBuf,
}

impl FilePreferenceStore {
    #[must_use]
    pub fn new(directory: impl AsRef<Path>) -> Self {
        Self {
            directory: directory.as_ref().to_owned(),
        }
    }

    #[must_use]
    pub fn directory(&self) -> &Path {
        &self.directory
    }

    #[must_use]
    pub fn path(&self) -> PathBuf {
        self.directory.join(PREFERENCES_FILE_NAME)
    }

    pub fn load(&self) -> io::Result<Preferences> {
        let path = self.path();
        let contents = match fs::read(&path) {
            Ok(contents) => contents,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return self.load_legacy();
            }
            Err(error) => return Err(error),
        };
        if let Some(preferences) = serde_json::from_slice::<StoredPreferences>(&contents)
            .ok()
            .filter(|stored| stored.version == PREFERENCES_VERSION)
            .map(StoredPreferences::into_preferences)
        {
            return Ok(preferences);
        }

        let migrated_preferences = serde_json::from_slice::<StoredPreferencesV4>(&contents)
            .ok()
            .filter(|stored| stored.version == PREVIOUS_PREFERENCES_VERSION)
            .map(StoredPreferencesV4::into_preferences)
            .or_else(|| {
                serde_json::from_slice::<StoredPreferencesV3>(&contents)
                    .ok()
                    .filter(|stored| stored.version == OLDER_PREFERENCES_VERSION)
                    .map(StoredPreferencesV3::into_preferences)
            });
        let Some(preferences) = migrated_preferences else {
            remove_file_if_present(&path)?;
            return Ok(Preferences::default());
        };

        self.save(&preferences)?;
        Ok(preferences)
    }

    fn load_legacy(&self) -> io::Result<Preferences> {
        let legacy_path = self.directory.join(LEGACY_PREFERENCES_FILE_NAME);
        let contents = match fs::read(&legacy_path) {
            Ok(contents) => contents,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(Preferences::default());
            }
            Err(error) => return Err(error),
        };
        let preferences = serde_json::from_slice::<StoredRenderPreferences>(&contents)
            .ok()
            .filter(|stored| stored.version == LEGACY_PREFERENCES_VERSION)
            .map(StoredRenderPreferences::into_preferences);
        let Some(preferences) = preferences else {
            remove_file_if_present(&legacy_path)?;
            return Ok(Preferences::default());
        };

        self.save(&preferences)?;
        remove_file_if_present(&legacy_path)?;
        Ok(preferences)
    }

    pub fn save(&self, preferences: &Preferences) -> io::Result<()> {
        atomic_replace(&self.path(), |temporary| {
            serde_json::to_writer(&mut *temporary, &StoredPreferences::from(*preferences))
                .map_err(io::Error::other)?;
            temporary.write_all(b"\n")
        })
    }
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StoredPreferences {
    version: u8,
    keep_connected: bool,
    android_mode_shortcuts: bool,
    command_passthrough: bool,
    preview_scale: PreviewScale,
    video_quality: VideoQuality,
    quick_actions: [QuickAction; 3],
}

impl From<Preferences> for StoredPreferences {
    fn from(preferences: Preferences) -> Self {
        Self {
            version: PREFERENCES_VERSION,
            keep_connected: preferences.keep_connected,
            android_mode_shortcuts: preferences.android_mode_shortcuts,
            command_passthrough: preferences.command_passthrough,
            preview_scale: preferences.preview_scale,
            video_quality: preferences.video_quality,
            quick_actions: preferences.quick_actions,
        }
    }
}

impl StoredPreferences {
    fn into_preferences(self) -> Preferences {
        Preferences {
            keep_connected: self.keep_connected,
            android_mode_shortcuts: self.android_mode_shortcuts,
            command_passthrough: self.command_passthrough,
            preview_scale: self.preview_scale,
            video_quality: self.video_quality,
            quick_actions: self.quick_actions,
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StoredPreferencesV4 {
    version: u8,
    keep_connected: bool,
    android_mode_shortcuts: bool,
    preview_scale: PreviewScale,
    video_quality: VideoQuality,
    quick_actions: [QuickAction; 3],
}

impl StoredPreferencesV4 {
    fn into_preferences(self) -> Preferences {
        Preferences {
            keep_connected: self.keep_connected,
            android_mode_shortcuts: self.android_mode_shortcuts,
            command_passthrough: false,
            preview_scale: self.preview_scale,
            video_quality: self.video_quality,
            quick_actions: self.quick_actions,
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StoredPreferencesV3 {
    version: u8,
    keep_connected: bool,
    preview_scale: PreviewScale,
    video_quality: VideoQuality,
    quick_actions: [QuickAction; 3],
}

impl StoredPreferencesV3 {
    fn into_preferences(self) -> Preferences {
        Preferences {
            keep_connected: self.keep_connected,
            preview_scale: self.preview_scale,
            video_quality: self.video_quality,
            quick_actions: self.quick_actions,
            android_mode_shortcuts: false,
            command_passthrough: false,
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StoredRenderPreferences {
    version: u8,
    preview_scale: PreviewScale,
    video_quality: VideoQuality,
    quick_actions: [QuickAction; 3],
}

impl StoredRenderPreferences {
    fn into_preferences(self) -> Preferences {
        Preferences {
            keep_connected: false,
            preview_scale: self.preview_scale,
            video_quality: self.video_quality,
            quick_actions: self.quick_actions,
            android_mode_shortcuts: false,
            command_passthrough: false,
        }
    }
}
