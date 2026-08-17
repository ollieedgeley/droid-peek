use std::{
    fs,
    fs::OpenOptions,
    io::{self, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

use serde::{Deserialize, Serialize};

const PREFERENCES_VERSION: u8 = 1;
const PREFERENCES_FILE_NAME: &str = "render-preferences.json";

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum PreviewSize {
    Small,
    #[default]
    Medium,
    Large,
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
pub struct RenderPreferences {
    pub preview_size: PreviewSize,
    pub video_quality: VideoQuality,
    pub quick_actions: [QuickAction; 3],
}

impl Default for RenderPreferences {
    fn default() -> Self {
        Self {
            preview_size: PreviewSize::Medium,
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
pub struct FileRenderPreferenceStore {
    directory: PathBuf,
}

impl FileRenderPreferenceStore {
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

    pub fn load(&self) -> io::Result<RenderPreferences> {
        let path = self.path();
        let contents = match fs::read(&path) {
            Ok(contents) => contents,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(RenderPreferences::default());
            }
            Err(error) => return Err(error),
        };
        let preferences = serde_json::from_slice::<StoredRenderPreferences>(&contents)
            .ok()
            .filter(|stored| stored.version == PREFERENCES_VERSION)
            .map(StoredRenderPreferences::into_preferences);
        match preferences {
            Some(preferences) => Ok(preferences),
            None => {
                match fs::remove_file(path) {
                    Ok(()) => {}
                    Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                    Err(error) => return Err(error),
                }
                Ok(RenderPreferences::default())
            }
        }
    }

    pub fn save(&self, preferences: &RenderPreferences) -> io::Result<()> {
        fs::create_dir_all(&self.directory)?;
        fs::set_permissions(&self.directory, fs::Permissions::from_mode(0o700))?;

        let temporary_path = self.directory.join(".render-preferences.json.tmp");
        let mut temporary = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temporary_path)?;
        temporary.set_permissions(fs::Permissions::from_mode(0o600))?;
        serde_json::to_writer(&mut temporary, &StoredRenderPreferences::from(*preferences))
            .map_err(io::Error::other)?;
        temporary.write_all(b"\n")?;
        temporary.sync_all()?;
        fs::rename(temporary_path, self.path())
    }
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StoredRenderPreferences {
    version: u8,
    preview_size: PreviewSize,
    video_quality: VideoQuality,
    quick_actions: [QuickAction; 3],
}

impl From<RenderPreferences> for StoredRenderPreferences {
    fn from(preferences: RenderPreferences) -> Self {
        Self {
            version: PREFERENCES_VERSION,
            preview_size: preferences.preview_size,
            video_quality: preferences.video_quality,
            quick_actions: preferences.quick_actions,
        }
    }
}

impl StoredRenderPreferences {
    fn into_preferences(self) -> RenderPreferences {
        RenderPreferences {
            preview_size: self.preview_size,
            video_quality: self.video_quality,
            quick_actions: self.quick_actions,
        }
    }
}
