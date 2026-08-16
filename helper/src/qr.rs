use std::{
    fs::{self, File},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use qrcode::{QrCode, render::svg};
use tempfile::{Builder, NamedTempFile};
use zeroize::Zeroizing;

use crate::pairing::{PairingPayloadError, qr_payload};

pub trait EntropySource {
    type Error;

    fn fill(&mut self, bytes: &mut [u8]) -> Result<(), Self::Error>;
}

pub trait Clock {
    fn now(&self) -> Duration;
}

pub trait QrArtifact {
    fn path(&self) -> &Path;
}

pub trait QrRenderer {
    type Artifact: QrArtifact;
    type Error;

    fn render(&mut self, payload: &str) -> Result<Self::Artifact, Self::Error>;
}

#[derive(Debug)]
pub enum QrCeremonyError<E, R> {
    Entropy(E),
    Payload(PairingPayloadError),
    Render(R),
}

#[derive(Debug, Eq, PartialEq)]
pub struct QrSessionPresentation {
    pub artifact_path: PathBuf,
    pub expires_in_seconds: u64,
}

struct ActiveSession<A> {
    _requested_service: Zeroizing<String>,
    _secret: Zeroizing<String>,
    artifact: A,
    expires_at: Duration,
}

pub struct QrCeremony<E, C, R>
where
    R: QrRenderer,
{
    entropy: E,
    clock: C,
    renderer: R,
    lifetime: Duration,
    active: Option<ActiveSession<R::Artifact>>,
}

impl<E, C, R> QrCeremony<E, C, R>
where
    E: EntropySource,
    C: Clock,
    R: QrRenderer,
{
    #[must_use]
    pub fn new(entropy: E, clock: C, renderer: R, lifetime: Duration) -> Self {
        Self {
            entropy,
            clock,
            renderer,
            lifetime,
            active: None,
        }
    }

    pub fn start(&mut self) -> Result<QrSessionPresentation, QrCeremonyError<E::Error, R::Error>> {
        self.active.take();

        let mut service_bytes = Zeroizing::new([0_u8; 10]);
        self.entropy
            .fill(service_bytes.as_mut())
            .map_err(QrCeremonyError::Entropy)?;
        let mut secret_bytes = Zeroizing::new([0_u8; 10]);
        self.entropy
            .fill(secret_bytes.as_mut())
            .map_err(QrCeremonyError::Entropy)?;

        let requested_service = Zeroizing::new(format!(
            "studio-{}",
            encode_qr_random(service_bytes.as_ref())
        ));
        let secret = Zeroizing::new(encode_qr_random(secret_bytes.as_ref()));
        let payload = Zeroizing::new(
            qr_payload(requested_service.as_str(), secret.as_str())
                .map_err(QrCeremonyError::Payload)?,
        );
        let artifact = self
            .renderer
            .render(payload.as_str())
            .map_err(QrCeremonyError::Render)?;
        let artifact_path = artifact.path().to_owned();
        let expires_at = self.clock.now().saturating_add(self.lifetime);

        self.active = Some(ActiveSession {
            _requested_service: requested_service,
            _secret: secret,
            artifact,
            expires_at,
        });

        Ok(QrSessionPresentation {
            artifact_path,
            expires_in_seconds: self.lifetime.as_secs(),
        })
    }

    pub fn cancel(&mut self) -> bool {
        self.active.take().is_some()
    }

    pub fn expire_if_needed(&mut self) -> bool {
        let expired = self
            .active
            .as_ref()
            .is_some_and(|session| self.clock.now() >= session.expires_at);
        if expired {
            self.active.take();
        }
        expired
    }
    pub fn with_pairing_material<T>(
        &mut self,
        use_material: impl FnOnce(&str, &str) -> T,
    ) -> Option<T> {
        self.expire_if_needed();
        self.active.as_ref().map(|session| {
            use_material(
                session._requested_service.as_str(),
                session._secret.as_str(),
            )
        })
    }

    #[must_use]
    pub fn has_active_session(&self) -> bool {
        self.active.is_some()
    }

    #[must_use]
    pub fn artifact_path(&self) -> Option<&Path> {
        self.active.as_ref().map(|session| session.artifact.path())
    }
}

fn encode_qr_random(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut encoded = String::with_capacity(bytes.len());
    for byte in bytes {
        encoded.push(char::from(ALPHABET[usize::from(byte & 0x3f)]));
    }
    encoded
}

pub struct SystemEntropy {
    source: File,
}

impl SystemEntropy {
    pub fn new() -> io::Result<Self> {
        Ok(Self {
            source: File::open("/dev/urandom")?,
        })
    }
}

impl EntropySource for SystemEntropy {
    type Error = io::Error;

    fn fill(&mut self, bytes: &mut [u8]) -> Result<(), Self::Error> {
        self.source.read_exact(bytes)
    }
}

pub struct SystemClock {
    origin: Instant,
}

impl SystemClock {
    #[must_use]
    pub fn new() -> Self {
        Self {
            origin: Instant::now(),
        }
    }
}

impl Default for SystemClock {
    fn default() -> Self {
        Self::new()
    }
}

impl Clock for SystemClock {
    fn now(&self) -> Duration {
        self.origin.elapsed()
    }
}

pub struct RuntimeQrArtifact {
    file: NamedTempFile,
}

impl QrArtifact for RuntimeQrArtifact {
    fn path(&self) -> &Path {
        self.file.path()
    }
}

pub struct RuntimeQrRenderer {
    directory: PathBuf,
}

impl RuntimeQrRenderer {
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self {
            directory: directory.into(),
        }
    }
}

#[derive(Debug)]
pub enum RuntimeQrRenderError {
    Io(io::Error),
    Qr(qrcode::types::QrError),
}

impl From<io::Error> for RuntimeQrRenderError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<qrcode::types::QrError> for RuntimeQrRenderError {
    fn from(error: qrcode::types::QrError) -> Self {
        Self::Qr(error)
    }
}

impl QrRenderer for RuntimeQrRenderer {
    type Artifact = RuntimeQrArtifact;
    type Error = RuntimeQrRenderError;

    fn render(&mut self, payload: &str) -> Result<Self::Artifact, Self::Error> {
        fs::create_dir_all(&self.directory)?;
        set_private_directory_permissions(&self.directory)?;

        let code = QrCode::new(payload.as_bytes())?;
        let svg = Zeroizing::new(code.render::<svg::Color>().min_dimensions(320, 320).build());
        let mut file = Builder::new()
            .prefix("qr-")
            .suffix(".svg")
            .tempfile_in(&self.directory)?;
        file.write_all(svg.as_bytes())?;
        file.flush()?;

        Ok(RuntimeQrArtifact { file })
    }
}

#[cfg(unix)]
fn set_private_directory_permissions(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
}

#[cfg(not(unix))]
fn set_private_directory_permissions(_path: &Path) -> io::Result<()> {
    Ok(())
}
