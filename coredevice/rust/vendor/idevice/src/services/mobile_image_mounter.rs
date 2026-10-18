//! iOS Image Mounter Client
//!
//! Provides functionality for mounting disk images on iOS devices, including:
//! - Developer disk images
//! - Personalized images
//! - Cryptex images
//!
//! Handles the complete workflow from uploading images to mounting them with proper signatures.

use tracing::debug;
#[cfg(feature = "tss")]
use tracing::warn;

#[cfg(all(feature = "rsd", feature = "tss"))]
use crate::RsdService;
use crate::{Idevice, IdeviceError, IdeviceService, obf};
#[cfg(feature = "tss")]
use sha2::{Digest, Sha384};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
#[cfg(feature = "tss")]
use tokio::io::{AsyncSeek, AsyncSeekExt};

#[cfg(feature = "tss")]
use crate::tss::TSSRequest;

const IMAGE_UPLOAD_CHUNK_SIZE: usize = 64 * 1024;

fn parse_lookup_image_response(
    response: &plist::Dictionary,
) -> Result<Option<Vec<u8>>, IdeviceError> {
    match response.get("ImagePresent") {
        Some(plist::Value::Boolean(false)) => return Ok(None),
        Some(plist::Value::Boolean(true)) | None => {}
        Some(_) => {
            return Err(IdeviceError::UnexpectedResponse(
                "LookupImage returned a malformed ImagePresent value".into(),
            ));
        }
    }

    let signature = match response.get("ImageSignature") {
        Some(plist::Value::Data(signature)) if !signature.is_empty() => signature.clone(),
        Some(plist::Value::Array(signatures)) if !signatures.is_empty() => {
            let mut parsed = signatures.iter().map(|value| match value {
                plist::Value::Data(signature) if !signature.is_empty() => Ok(signature),
                _ => Err(IdeviceError::UnexpectedResponse(
                    "LookupImage returned a malformed signature array".into(),
                )),
            });
            let first = parsed
                .next()
                .expect("nonempty array checked above")?
                .clone();
            for result in parsed {
                result?;
            }
            first
        }
        Some(plist::Value::Data(_)) => {
            return Err(IdeviceError::UnexpectedResponse(
                "LookupImage returned an empty image signature".into(),
            ));
        }
        Some(plist::Value::Array(_)) => {
            return Err(IdeviceError::UnexpectedResponse(
                "LookupImage returned an empty signature array".into(),
            ));
        }
        Some(_) => {
            return Err(IdeviceError::UnexpectedResponse(
                "LookupImage returned an unsupported image signature type".into(),
            ));
        }
        None => {
            return Err(IdeviceError::UnexpectedResponse(
                "LookupImage omitted both absence and signature data".into(),
            ));
        }
    };
    Ok(Some(signature))
}

fn parse_image_presence_response(response: &plist::Dictionary) -> Result<bool, IdeviceError> {
    match response.get("ImagePresent") {
        Some(plist::Value::Boolean(present)) => Ok(*present),
        Some(_) => Err(IdeviceError::UnexpectedResponse(
            "LookupImage returned a malformed ImagePresent value".into(),
        )),
        None => match response.get("ImageSignature") {
            Some(plist::Value::Data(signature)) if !signature.is_empty() => Ok(true),
            Some(plist::Value::Data(_)) => Err(IdeviceError::UnexpectedResponse(
                "LookupImage returned an empty image signature".into(),
            )),
            Some(plist::Value::Array(signatures))
                if signatures.is_empty()
                    || signatures.iter().all(|value| {
                        matches!(
                            value,
                            plist::Value::Data(signature)
                                if !signature.is_empty()
                        )
                    }) =>
            {
                Ok(true)
            }
            Some(plist::Value::Array(_)) => Err(IdeviceError::UnexpectedResponse(
                "LookupImage returned a malformed signature array".into(),
            )),
            Some(_) => Err(IdeviceError::UnexpectedResponse(
                "LookupImage returned an unsupported image signature type".into(),
            )),
            None => Err(IdeviceError::UnexpectedResponse(
                "LookupImage omitted both absence and signature data".into(),
            )),
        },
    }
}

/// Only a definitive cache miss permits an online TSS fallback. Transport,
/// framing, and device errors must propagate instead of being reinterpreted as
/// permission to contact Apple.
#[cfg(feature = "tss")]
fn should_fetch_manifest_from_tss(error: &IdeviceError) -> bool {
    matches!(error, IdeviceError::NotFound)
}

/// Fills one image chunk, treating EOF before the chunk boundary as corruption.
async fn read_image_chunk_exactly<R>(reader: &mut R, buffer: &mut [u8]) -> Result<(), IdeviceError>
where
    R: AsyncRead + Unpin + ?Sized,
{
    let mut filled = 0;
    while filled < buffer.len() {
        let count = reader.read(&mut buffer[filled..]).await?;
        if count == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "image reader ended before its declared size",
            )
            .into());
        }
        filled += count;
    }
    Ok(())
}

/// Ensures the declared image length consumes the complete reader.
async fn require_image_eof<R>(reader: &mut R) -> Result<(), IdeviceError>
where
    R: AsyncRead + Unpin + ?Sized,
{
    let mut extra = [0_u8; 1];
    if reader.read(&mut extra).await? != 0 {
        return Err(IdeviceError::UnexpectedResponse(
            "image reader exceeds its declared size".into(),
        ));
    }
    Ok(())
}

/// Copies exactly `image_size` bytes while retaining only one upload chunk.
///
/// Partial reads and writes are completed before progress advances. An early
/// EOF or any transport error fails the upload rather than silently sending a
/// truncated image.
async fn stream_image_exactly<R, W, F, Fut>(
    reader: &mut R,
    writer: &mut W,
    image_size: u64,
    mut progress: F,
) -> Result<(), IdeviceError>
where
    R: AsyncRead + Unpin + ?Sized,
    W: AsyncWrite + Unpin + ?Sized,
    F: FnMut(u64, u64) -> Fut,
    Fut: std::future::Future<Output = ()>,
{
    let mut buffer = vec![0; IMAGE_UPLOAD_CHUNK_SIZE];
    let mut sent = 0_u64;

    while sent < image_size {
        let remaining = image_size - sent;
        let chunk_len = usize::try_from(remaining.min(IMAGE_UPLOAD_CHUNK_SIZE as u64))
            .map_err(|_| IdeviceError::IntegerOverflow)?;
        read_image_chunk_exactly(reader, &mut buffer[..chunk_len]).await?;

        writer.write_all(&buffer[..chunk_len]).await?;
        sent += chunk_len as u64;
        progress(sent, image_size).await;
    }

    require_image_eof(reader).await?;
    writer.flush().await?;
    Ok(())
}

/// Computes SHA-384 over an exact-length image using one bounded buffer.
#[cfg(feature = "tss")]
async fn hash_image_exactly<R>(reader: &mut R, image_size: u64) -> Result<Vec<u8>, IdeviceError>
where
    R: AsyncRead + Unpin + ?Sized,
{
    let mut buffer = vec![0; IMAGE_UPLOAD_CHUNK_SIZE];
    let mut hasher = Sha384::new();
    let mut hashed = 0_u64;

    while hashed < image_size {
        let remaining = image_size - hashed;
        let chunk_len = usize::try_from(remaining.min(IMAGE_UPLOAD_CHUNK_SIZE as u64))
            .map_err(|_| IdeviceError::IntegerOverflow)?;
        read_image_chunk_exactly(reader, &mut buffer[..chunk_len]).await?;

        hasher.update(&buffer[..chunk_len]);
        hashed += chunk_len as u64;
    }

    require_image_eof(reader).await?;
    Ok(hasher.finalize().to_vec())
}

/// Hashes an image and restores the reader to its original position.
#[cfg(feature = "tss")]
async fn hash_image_and_rewind<R>(reader: &mut R, image_size: u64) -> Result<Vec<u8>, IdeviceError>
where
    R: AsyncRead + AsyncSeek + Unpin + ?Sized,
{
    let image_start = reader.stream_position().await?;
    let digest = hash_image_exactly(reader, image_size).await;
    let rewind = reader
        .seek(std::io::SeekFrom::Start(image_start))
        .await
        .map(|_| ());

    match (digest, rewind) {
        (_, Err(error)) => Err(error.into()),
        (Err(error), Ok(())) => Err(error),
        (Ok(digest), Ok(())) => Ok(digest),
    }
}

/// Client for interacting with the iOS mobile image mounter service
///
/// Manages mounted images on the device.
///
/// # Important Note
/// A lockdown client must be established and queried after establishing a mounter client,
/// or the device will stop responding to requests.
#[derive(Debug)]
pub struct ImageMounter {
    /// The underlying device connection with established image mounter service
    idevice: Idevice,
}

impl IdeviceService for ImageMounter {
    /// Returns the image mounter service name as registered with lockdownd
    fn service_name() -> std::borrow::Cow<'static, str> {
        obf!("com.apple.mobile.mobile_image_mounter")
    }

    async fn from_stream(idevice: Idevice) -> Result<Self, crate::IdeviceError> {
        Ok(Self::new(idevice))
    }
}

impl ImageMounter {
    /// Creates a new image mounter client from an existing device connection
    ///
    /// # Arguments
    /// * `idevice` - Pre-established device connection
    pub fn new(idevice: Idevice) -> Self {
        Self { idevice }
    }

    /// Retrieves a list of currently mounted devices
    ///
    /// # Returns
    /// A vector of plist values describing mounted devices
    ///
    /// # Errors
    /// Returns `IdeviceError` if communication fails or response is malformed
    pub async fn copy_devices(&mut self) -> Result<Vec<plist::Value>, IdeviceError> {
        let req = crate::plist!({
            "Command": "CopyDevices"
        });
        self.idevice.send_plist(req).await?;
        let mut res = self.idevice.read_plist().await?;

        match res.remove("EntryList") {
            Some(plist::Value::Array(i)) => Ok(i),
            _ => Err(IdeviceError::UnexpectedResponse(
                "missing EntryList array in CopyDevices response".into(),
            )),
        }
    }

    /// Looks up an image by type and returns its signature
    ///
    /// # Arguments
    /// * `image_type` - The type of image to lookup (e.g., "Developer")
    ///
    /// # Returns
    /// The image signature if found
    ///
    /// # Errors
    /// Returns `IdeviceError::NotFound` if image doesn't exist
    pub async fn lookup_image(
        &mut self,
        image_type: impl Into<&str>,
    ) -> Result<Vec<u8>, IdeviceError> {
        let image_type = image_type.into();
        let res = self.request_lookup_image(image_type).await?;
        match parse_lookup_image_response(&res)? {
            Some(signature) => Ok(signature),
            None => Err(IdeviceError::NotFound),
        }
    }

    /// Reports whether an image type is mounted without requiring signature
    /// material that newer devices may intentionally omit.
    ///
    /// # Errors
    /// Returns `IdeviceError` if the request fails or the device does not
    /// provide an unambiguous presence value.
    pub async fn image_is_present(
        &mut self,
        image_type: impl Into<&str>,
    ) -> Result<bool, IdeviceError> {
        let image_type = image_type.into();
        let res = self.request_lookup_image(image_type).await?;
        parse_image_presence_response(&res)
    }

    async fn request_lookup_image(
        &mut self,
        image_type: &str,
    ) -> Result<plist::Dictionary, IdeviceError> {
        let req = crate::plist!({
            "Command": "LookupImage",
            "ImageType": image_type
        });
        self.idevice.send_plist(req).await?;
        self.idevice.read_plist().await
    }

    /// Uploads an image to the device
    ///
    /// # Arguments
    /// * `image_type` - Type of image being uploaded
    /// * `image` - The image data
    /// * `signature` - Signature for the image
    ///
    /// # Errors
    /// Returns `IdeviceError` if upload fails
    pub async fn upload_image(
        &mut self,
        image_type: impl Into<String>,
        image: &[u8],
        signature: Vec<u8>,
    ) -> Result<(), IdeviceError> {
        self.upload_image_with_progress(image_type, image, signature, |_| async {}, ())
            .await
    }

    /// Uploads an image with progress callbacks
    ///
    /// # Arguments
    /// * `image_type` - Type of image being uploaded
    /// * `image` - The image data
    /// * `signature` - Signature for the image
    /// * `callback` - Progress callback
    /// * `state` - State to pass to callback
    ///
    /// # Type Parameters
    /// * `Fut` - Future type returned by callback
    /// * `S` - Type of state passed to callback
    ///
    /// # Errors
    /// Returns `IdeviceError` if upload fails
    pub async fn upload_image_with_progress<Fut, S>(
        &mut self,
        image_type: impl Into<String>,
        image: &[u8],
        signature: Vec<u8>,
        callback: impl Fn(((usize, usize), S)) -> Fut,
        state: S,
    ) -> Result<(), IdeviceError>
    where
        Fut: std::future::Future<Output = ()>,
        S: Clone,
    {
        let image_size = u64::try_from(image.len()).map_err(|_| IdeviceError::IntegerOverflow)?;
        let mut reader = std::io::Cursor::new(image);
        self.upload_image_reader_with_progress(
            image_type,
            &mut reader,
            image_size,
            signature,
            callback,
            state,
        )
        .await
    }

    /// Uploads exactly `image_size` bytes from an asynchronous reader.
    ///
    /// The reader is consumed incrementally using a fixed 64 KiB buffer, so a
    /// disk image does not need to be resident in memory. It must reach EOF
    /// exactly after `image_size` bytes.
    ///
    /// # Errors
    /// Returns `IdeviceError` if the reader length differs from `image_size`,
    /// reading or writing fails, or the device rejects the upload.
    pub async fn upload_image_reader<R>(
        &mut self,
        image_type: impl Into<String>,
        reader: &mut R,
        image_size: u64,
        signature: Vec<u8>,
    ) -> Result<(), IdeviceError>
    where
        R: AsyncRead + Unpin + ?Sized,
    {
        self.upload_image_reader_with_progress(
            image_type,
            reader,
            image_size,
            signature,
            |_| async {},
            (),
        )
        .await
    }

    /// Uploads exactly `image_size` bytes from a reader with progress callbacks.
    ///
    /// Existing callbacks keep their chunk-index semantics: the tuple contains
    /// `(current_chunk_index, final_chunk_index)`. The reader must reach EOF
    /// exactly after `image_size` bytes.
    ///
    /// # Errors
    /// Returns `IdeviceError` if the reader length differs from `image_size`,
    /// reading or writing fails, an index cannot be represented on this
    /// platform, or the device rejects the upload.
    pub async fn upload_image_reader_with_progress<R, Fut, S>(
        &mut self,
        image_type: impl Into<String>,
        reader: &mut R,
        image_size: u64,
        signature: Vec<u8>,
        callback: impl Fn(((usize, usize), S)) -> Fut,
        state: S,
    ) -> Result<(), IdeviceError>
    where
        R: AsyncRead + Unpin + ?Sized,
        Fut: std::future::Future<Output = ()>,
        S: Clone,
    {
        let image_type = image_type.into();
        let chunk_count = image_size.div_ceil(IMAGE_UPLOAD_CHUNK_SIZE as u64);
        let final_chunk_index = usize::try_from(chunk_count.saturating_sub(1))
            .map_err(|_| IdeviceError::IntegerOverflow)?;

        let req = crate::plist!({
            "Command": "ReceiveBytes",
            "ImageType": image_type,
            "ImageSize": image_size,
            "ImageSignature": signature,
        });
        self.idevice.send_plist(req).await?;

        let res = self.idevice.read_plist().await?;
        match res.get("Status") {
            Some(plist::Value::String(s)) => {
                if s.as_str() != "ReceiveBytesAck" {
                    tracing::error!("Received bad response to SendBytes: {s:?}");
                    return Err(IdeviceError::UnexpectedResponse(
                        "expected ReceiveBytesAck Status in upload response".into(),
                    ));
                }
            }
            _ => {
                return Err(IdeviceError::UnexpectedResponse(
                    "missing Status in ReceiveBytes response".into(),
                ));
            }
        }

        debug!("Sending image bytes");
        let socket = self
            .idevice
            .socket
            .as_mut()
            .ok_or(IdeviceError::NoEstablishedConnection)?;
        let mut chunk_index = 0;
        stream_image_exactly(reader, socket.as_mut(), image_size, |_sent, _total| {
            let current_chunk_index = chunk_index;
            chunk_index += 1;
            callback(((current_chunk_index, final_chunk_index), state.clone()))
        })
        .await?;

        let res = self.idevice.read_plist().await?;
        match res.get("Status") {
            Some(plist::Value::String(s)) => {
                if s.as_str() != "Complete" {
                    tracing::error!("Image send failure: {s:?}");
                    return Err(IdeviceError::UnexpectedResponse(
                        "expected Complete Status after image upload".into(),
                    ));
                }
            }
            _ => {
                return Err(IdeviceError::UnexpectedResponse(
                    "missing Status after image upload".into(),
                ));
            }
        }

        Ok(())
    }

    /// Mounts an image on the device
    ///
    /// # Arguments
    /// * `image_type` - Type of image to mount
    /// * `signature` - Signature for the image
    /// * `trust_cache` - Optional trust cache data
    /// * `info_plist` - Optional info plist for the image
    ///
    /// # Errors
    /// Returns `IdeviceError` if mounting fails
    pub async fn mount_image(
        &mut self,
        image_type: impl Into<String>,
        signature: Vec<u8>,
        trust_cache: Option<Vec<u8>>,
        info_plist: Option<plist::Value>,
    ) -> Result<(), IdeviceError> {
        let image_type = image_type.into();

        let req = crate::plist!({
            "Command": "MountImage",
            "ImageType": image_type,
            "ImageSignature": signature,
            "ImageTrustCache":? trust_cache,
            "ImageInfoPlist":? info_plist,
        });
        self.idevice.send_plist(req).await?;

        let res = self.idevice.read_plist().await?;

        match res.get("Status") {
            Some(plist::Value::String(s)) => {
                if s.as_str() != "Complete" {
                    tracing::error!("Image send failure: {s:?}");
                    return Err(IdeviceError::UnexpectedResponse(
                        "expected Complete Status in MountImage response".into(),
                    ));
                }
            }
            _ => {
                return Err(IdeviceError::UnexpectedResponse(
                    "missing Status in MountImage response".into(),
                ));
            }
        }

        Ok(())
    }

    /// Unmounts an image at the specified path
    ///
    /// # Arguments
    /// * `mount_path` - Path where image is mounted:
    ///   - `/Developer` for pre-iOS 17 developer images
    ///   - `/System/Developer` for personalized images
    ///
    /// # Errors
    /// Returns `IdeviceError` if unmounting fails
    pub async fn unmount_image(
        &mut self,
        mount_path: impl Into<String>,
    ) -> Result<(), IdeviceError> {
        let mount_path = mount_path.into();
        let req = crate::plist!({
            "Command": "UnmountImage",
            "MountPath": mount_path,
        });
        self.idevice.send_plist(req).await?;

        let res = self.idevice.read_plist().await?;
        match res.get("Status") {
            Some(plist::Value::String(s)) if s.as_str() == "Complete" => Ok(()),
            _ => Err(IdeviceError::UnexpectedResponse(
                "expected Complete Status in UnmountImage response".into(),
            )),
        }
    }

    /// Queries the personalization manifest from the device
    ///
    /// # Important
    /// On failure, the socket must be closed and reestablished.
    ///
    /// # Arguments
    /// * `image_type` - Type of image to query manifest for
    /// * `signature` - Signature of the image
    ///
    /// # Returns
    /// The personalization manifest data
    ///
    /// # Errors
    /// Returns `IdeviceError` if query fails
    pub async fn query_personalization_manifest(
        &mut self,
        image_type: impl Into<String>,
        signature: Vec<u8>,
    ) -> Result<Vec<u8>, IdeviceError> {
        let image_type = image_type.into();

        let req = crate::plist!({
            "Command": "QueryPersonalizationManifest",
            "PersonalizedImageType": image_type.clone(),
            "ImageType": image_type,
            "ImageSignature": signature
        });
        self.idevice.send_plist(req).await?;

        let mut res = self.idevice.read_plist().await?;
        match res.remove("ImageSignature") {
            Some(plist::Value::Data(i)) => Ok(i),
            _ => Err(IdeviceError::NotFound),
        }
    }

    /// Queries the developer mode status of the device
    ///
    /// # Returns
    /// `true` if developer mode is enabled, `false` otherwise
    ///
    /// # Errors
    /// Returns `IdeviceError` if query fails
    pub async fn query_developer_mode_status(&mut self) -> Result<bool, IdeviceError> {
        let req = crate::plist!({
            "Command": "QueryDeveloperModeStatus"
        });
        self.idevice.send_plist(req).await?;

        let res = self.idevice.read_plist().await?;
        match res.get("DeveloperModeStatus") {
            Some(plist::Value::Boolean(status)) => Ok(*status),
            _ => Err(IdeviceError::UnexpectedResponse(
                "missing DeveloperModeStatus boolean in response".into(),
            )),
        }
    }

    /// Queries the nonce value from the device
    ///
    /// # Arguments
    /// * `personalized_image_type` - Optional image type to get nonce for
    ///
    /// # Returns
    /// The nonce value
    ///
    /// # Errors
    /// Returns `IdeviceError` if query fails
    pub async fn query_nonce(
        &mut self,
        personalized_image_type: Option<&str>,
    ) -> Result<Vec<u8>, IdeviceError> {
        let req = crate::plist!({
            "Command": "QueryNonce",
            "PersonalizedImageType":? personalized_image_type,
        });
        self.idevice.send_plist(req).await?;

        let res = self.idevice.read_plist().await?;
        match res.get("PersonalizationNonce") {
            Some(plist::Value::Data(nonce)) => Ok(nonce.clone()),
            _ => Err(IdeviceError::UnexpectedResponse(
                "missing PersonalizationNonce data in response".into(),
            )),
        }
    }

    /// Queries personalization identifiers from the device
    ///
    /// # Arguments
    /// * `image_type` - Optional image type to get identifiers for
    ///
    /// # Returns
    /// Dictionary of personalization identifiers
    ///
    /// # Errors
    /// Returns `IdeviceError` if query fails
    pub async fn query_personalization_identifiers(
        &mut self,
        image_type: Option<&str>,
    ) -> Result<plist::Dictionary, IdeviceError> {
        let req = crate::plist!({
            "Command": "QueryPersonalizationIdentifiers",
            "PersonalizedImageType":? image_type,
        });
        self.idevice.send_plist(req).await?;

        let res = self.idevice.read_plist().await?;
        match res.get("PersonalizationIdentifiers") {
            Some(plist::Value::Dictionary(identifiers)) => Ok(identifiers.clone()),
            _ => Err(IdeviceError::UnexpectedResponse(
                "missing PersonalizationIdentifiers dictionary in response".into(),
            )),
        }
    }

    /// Rolls the personalization nonce on the device
    ///
    /// # Errors
    /// Returns `IdeviceError` if operation fails
    pub async fn roll_personalization_nonce(&mut self) -> Result<(), IdeviceError> {
        let req = crate::plist!({
            "Command": "RollPersonalizationNonce"
        });
        self.idevice.send_plist(req).await?;

        Ok(())
    }

    /// Rolls the cryptex nonce on the device
    ///
    /// # Errors
    /// Returns `IdeviceError` if operation fails
    pub async fn roll_cryptex_nonce(&mut self) -> Result<(), IdeviceError> {
        let req = crate::plist!({
            "Command": "RollCryptexNonce"
        });
        self.idevice.send_plist(req).await?;

        Ok(())
    }

    /// Mounts a developer disk image
    ///
    /// # Arguments
    /// * `image` - The developer disk image data
    /// * `signature` - Signature for the image
    ///
    /// # Errors
    /// Returns `IdeviceError` if mounting fails
    pub async fn mount_developer(
        &mut self,
        image: &[u8],
        signature: Vec<u8>,
    ) -> Result<(), IdeviceError> {
        self.upload_image("Developer", image, signature.clone())
            .await?;
        self.mount_image("Developer", signature, None, None).await?;

        Ok(())
    }

    #[cfg(feature = "tss")]
    /// Mounts a personalized image with automatic manifest handling
    ///
    /// # Arguments
    /// * `provider` - Device connection provider (used for reconnection if needed)
    /// * `image` - The image data
    /// * `trust_cache` - Trust cache data
    /// * `build_manifest` - Build manifest data
    /// * `info_plist` - Optional info plist for the image
    /// * `unique_chip_id` - Device's unique chip ID
    ///
    /// # Errors
    /// Returns `IdeviceError` if mounting fails
    pub async fn mount_personalized(
        &mut self,
        provider: &dyn crate::provider::IdeviceProvider,
        image: Vec<u8>,
        trust_cache: Vec<u8>,
        build_manifest: &[u8],
        info_plist: Option<plist::Value>,
        unique_chip_id: u64,
    ) -> Result<(), IdeviceError> {
        self.mount_personalized_with_callback(
            provider,
            image,
            trust_cache,
            build_manifest,
            info_plist,
            unique_chip_id,
            |_| async {},
            (),
        )
        .await
    }

    #[cfg(feature = "tss")]
    /// Mounts a personalized image with progress callbacks
    ///
    /// # Important
    /// This may close the socket on failure, requiring reconnection.
    ///
    /// # Arguments
    /// * `provider` - Device connection provider
    /// * `image` - The image data
    /// * `trust_cache` - Trust cache data
    /// * `build_manifest` - Build manifest data
    /// * `info_plist` - Optional info plist for the image
    /// * `unique_chip_id` - Device's unique chip ID
    /// * `callback` - Progress callback
    /// * `state` - State to pass to callback
    ///
    /// # Type Parameters
    /// * `Fut` - Future type returned by callback
    /// * `S` - Type of state passed to callback
    ///
    /// # Errors
    /// Returns `IdeviceError` if mounting fails
    #[allow(clippy::too_many_arguments)]
    pub async fn mount_personalized_with_callback<Fut, S>(
        &mut self,
        provider: &dyn crate::provider::IdeviceProvider,
        image: Vec<u8>,
        trust_cache: Vec<u8>,
        build_manifest: &[u8],
        info_plist: Option<plist::Value>,
        unique_chip_id: u64,
        callback: impl Fn(((usize, usize), S)) -> Fut,
        state: S,
    ) -> Result<(), IdeviceError>
    where
        Fut: std::future::Future<Output = ()>,
        S: Clone,
    {
        let image_size = u64::try_from(image.len()).map_err(|_| IdeviceError::IntegerOverflow)?;
        let mut image = std::io::Cursor::new(image);
        self.mount_personalized_reader_with_callback(
            provider,
            &mut image,
            image_size,
            trust_cache,
            build_manifest,
            info_plist,
            unique_chip_id,
            callback,
            state,
        )
        .await
    }

    #[cfg(feature = "tss")]
    /// Mounts a personalized image from a bounded-memory reader.
    ///
    /// The reader must be seekable because personalization hashes the exact
    /// image first, then rewinds to stream the upload.
    ///
    /// # Errors
    /// Returns `IdeviceError` if hashing, seeking, personalization, upload, or
    /// mounting fails.
    #[allow(clippy::too_many_arguments)]
    pub async fn mount_personalized_reader<R>(
        &mut self,
        provider: &dyn crate::provider::IdeviceProvider,
        image: &mut R,
        image_size: u64,
        trust_cache: Vec<u8>,
        build_manifest: &[u8],
        info_plist: Option<plist::Value>,
        unique_chip_id: u64,
    ) -> Result<(), IdeviceError>
    where
        R: AsyncRead + AsyncSeek + Unpin + ?Sized,
    {
        self.mount_personalized_reader_with_callback(
            provider,
            image,
            image_size,
            trust_cache,
            build_manifest,
            info_plist,
            unique_chip_id,
            |_| async {},
            (),
        )
        .await
    }

    #[cfg(feature = "tss")]
    /// Mounts a personalized image from a reader with progress callbacks.
    ///
    /// The reader's current position is treated as the image start. Both the
    /// SHA-384 pass and upload must consume exactly `image_size` bytes and reach
    /// EOF; otherwise the operation fails closed.
    ///
    /// # Errors
    /// Returns `IdeviceError` if hashing, seeking, personalization, upload, or
    /// mounting fails.
    #[allow(clippy::too_many_arguments)]
    pub async fn mount_personalized_reader_with_callback<R, Fut, S>(
        &mut self,
        provider: &dyn crate::provider::IdeviceProvider,
        image: &mut R,
        image_size: u64,
        trust_cache: Vec<u8>,
        build_manifest: &[u8],
        info_plist: Option<plist::Value>,
        unique_chip_id: u64,
        callback: impl Fn(((usize, usize), S)) -> Fut,
        state: S,
    ) -> Result<(), IdeviceError>
    where
        R: AsyncRead + AsyncSeek + Unpin + ?Sized,
        Fut: std::future::Future<Output = ()>,
        S: Clone,
    {
        let image_hash = hash_image_and_rewind(image, image_size).await?;

        // Try to fetch personalization manifest
        let manifest = match self
            .query_personalization_manifest("DeveloperDiskImage", image_hash)
            .await
        {
            Ok(manifest) => manifest,
            Err(e) if should_fetch_manifest_from_tss(&e) => {
                debug!("Device didn't contain a manifest: {e:?}, fetching from TSS");

                // On failure, the socket closes. Open a new one.
                self.idevice = Self::connect(provider).await?.idevice;

                // Get manifest from TSS
                let manifest_dict: plist::Dictionary = plist::from_bytes(build_manifest)?;
                self.get_manifest_from_tss(&manifest_dict, unique_chip_id)
                    .await?
            }
            Err(error) => return Err(error),
        };

        debug!("Uploading image");
        self.upload_image_reader_with_progress(
            "Personalized",
            image,
            image_size,
            manifest.clone(),
            callback,
            state,
        )
        .await?;

        debug!("Mounting image");
        self.mount_image("Personalized", manifest, Some(trust_cache), info_plist)
            .await?;

        Ok(())
    }

    /// Mounts a personalized image with automatic manifest handling
    ///
    /// # Arguments
    /// * `provider` - Device connection provider (used for reconnection if needed)
    /// * `image` - The image data
    /// * `trust_cache` - Trust cache data
    /// * `build_manifest` - Build manifest data
    /// * `info_plist` - Optional info plist for the image
    /// * `unique_chip_id` - Device's unique chip ID
    ///
    /// # Errors
    /// Returns `IdeviceError` if mounting fails
    #[cfg(all(feature = "tss", feature = "rsd"))]
    #[allow(clippy::too_many_arguments)]
    pub async fn mount_personalized_rsd(
        &mut self,
        provider: &mut impl crate::provider::RsdProvider,
        handshake: &mut crate::rsd::RsdHandshake,
        image: Vec<u8>,
        trust_cache: Vec<u8>,
        build_manifest: &[u8],
        info_plist: Option<plist::Value>,
        unique_chip_id: u64,
    ) -> Result<(), IdeviceError> {
        self.mount_personalized_with_callback_rsd(
            provider,
            handshake,
            image,
            trust_cache,
            build_manifest,
            info_plist,
            unique_chip_id,
            |_| async {},
            (),
        )
        .await
    }

    /// Mounts a personalized image with progress callbacks
    ///
    /// # Important
    /// This may close the socket on failure, requiring reconnection.
    ///
    /// # Arguments
    /// * `provider` - Device connection provider
    /// * `image` - The image data
    /// * `trust_cache` - Trust cache data
    /// * `build_manifest` - Build manifest data
    /// * `info_plist` - Optional info plist for the image
    /// * `unique_chip_id` - Device's unique chip ID
    /// * `callback` - Progress callback
    /// * `state` - State to pass to callback
    ///
    /// # Type Parameters
    /// * `Fut` - Future type returned by callback
    /// * `S` - Type of state passed to callback
    ///
    /// # Errors
    /// Returns `IdeviceError` if mounting fails
    #[cfg(all(feature = "tss", feature = "rsd"))]
    #[allow(clippy::too_many_arguments)]
    pub async fn mount_personalized_with_callback_rsd<Fut, S>(
        &mut self,
        provider: &mut impl crate::provider::RsdProvider,
        handshake: &mut crate::rsd::RsdHandshake,
        image: Vec<u8>,
        trust_cache: Vec<u8>,
        build_manifest: &[u8],
        info_plist: Option<plist::Value>,
        unique_chip_id: u64,
        callback: impl Fn(((usize, usize), S)) -> Fut,
        state: S,
    ) -> Result<(), IdeviceError>
    where
        Fut: std::future::Future<Output = ()>,
        S: Clone,
    {
        let image_size = u64::try_from(image.len()).map_err(|_| IdeviceError::IntegerOverflow)?;
        let mut image = std::io::Cursor::new(image);
        self.mount_personalized_reader_with_callback_rsd(
            provider,
            handshake,
            &mut image,
            image_size,
            trust_cache,
            build_manifest,
            info_plist,
            unique_chip_id,
            callback,
            state,
        )
        .await
    }

    /// Mounts a personalized image from a bounded-memory reader over RSD.
    ///
    /// The reader must be seekable because personalization hashes the exact
    /// image first, then rewinds to stream the upload.
    ///
    /// # Errors
    /// Returns `IdeviceError` if hashing, seeking, personalization, upload, or
    /// mounting fails.
    #[cfg(all(feature = "tss", feature = "rsd"))]
    #[allow(clippy::too_many_arguments)]
    pub async fn mount_personalized_reader_rsd<R>(
        &mut self,
        provider: &mut impl crate::provider::RsdProvider,
        handshake: &mut crate::rsd::RsdHandshake,
        image: &mut R,
        image_size: u64,
        trust_cache: Vec<u8>,
        build_manifest: &[u8],
        info_plist: Option<plist::Value>,
        unique_chip_id: u64,
    ) -> Result<(), IdeviceError>
    where
        R: AsyncRead + AsyncSeek + Unpin + ?Sized,
    {
        self.mount_personalized_reader_with_callback_rsd(
            provider,
            handshake,
            image,
            image_size,
            trust_cache,
            build_manifest,
            info_plist,
            unique_chip_id,
            |_| async {},
            (),
        )
        .await
    }

    /// Mounts a personalized image from a reader over RSD with progress
    /// callbacks.
    ///
    /// The reader's current position is treated as the image start. Both the
    /// SHA-384 pass and upload must consume exactly `image_size` bytes and reach
    /// EOF; otherwise the operation fails closed.
    ///
    /// # Errors
    /// Returns `IdeviceError` if hashing, seeking, personalization, upload, or
    /// mounting fails.
    #[cfg(all(feature = "tss", feature = "rsd"))]
    #[allow(clippy::too_many_arguments)]
    pub async fn mount_personalized_reader_with_callback_rsd<R, Fut, S>(
        &mut self,
        provider: &mut impl crate::provider::RsdProvider,
        handshake: &mut crate::rsd::RsdHandshake,
        image: &mut R,
        image_size: u64,
        trust_cache: Vec<u8>,
        build_manifest: &[u8],
        info_plist: Option<plist::Value>,
        unique_chip_id: u64,
        callback: impl Fn(((usize, usize), S)) -> Fut,
        state: S,
    ) -> Result<(), IdeviceError>
    where
        R: AsyncRead + AsyncSeek + Unpin + ?Sized,
        Fut: std::future::Future<Output = ()>,
        S: Clone,
    {
        let image_hash = hash_image_and_rewind(image, image_size).await?;

        // Try to fetch personalization manifest
        let manifest = match self
            .query_personalization_manifest("DeveloperDiskImage", image_hash)
            .await
        {
            Ok(manifest) => manifest,
            Err(e) if should_fetch_manifest_from_tss(&e) => {
                debug!("Device didn't contain a manifest: {e:?}, fetching from TSS");

                // On failure, the socket closes. Open a new one.
                self.idevice = Self::connect_rsd(provider, handshake).await?.idevice;

                // Get manifest from TSS
                let manifest_dict: plist::Dictionary = plist::from_bytes(build_manifest)?;
                self.get_manifest_from_tss(&manifest_dict, unique_chip_id)
                    .await?
            }
            Err(error) => return Err(error),
        };

        debug!("Uploading image");
        self.upload_image_reader_with_progress(
            "Personalized",
            image,
            image_size,
            manifest.clone(),
            callback,
            state,
        )
        .await?;

        debug!("Mounting image");
        self.mount_image("Personalized", manifest, Some(trust_cache), info_plist)
            .await?;

        Ok(())
    }

    #[cfg(feature = "tss")]
    /// Retrieves a personalization manifest from Apple's TSS server
    ///
    /// # Arguments
    /// * `build_manifest` - Build manifest dictionary
    /// * `unique_chip_id` - Device's unique chip ID
    ///
    /// # Returns
    /// The manifest data
    ///
    /// # Errors
    /// Returns `IdeviceError` if manifest retrieval fails
    pub async fn get_manifest_from_tss(
        &mut self,
        build_manifest: &plist::Dictionary,
        unique_chip_id: u64,
    ) -> Result<Vec<u8>, IdeviceError> {
        let mut request = TSSRequest::new();

        let personalization_identifiers = self.query_personalization_identifiers(None).await?;
        request.add_ap_personalization_identifiers(&personalization_identifiers);

        let board_id = match personalization_identifiers.get("BoardId") {
            Some(plist::Value::Integer(b)) => match b.as_unsigned() {
                Some(b) => b,
                None => {
                    return Err(IdeviceError::UnexpectedResponse(
                        "BoardId is not an unsigned integer".into(),
                    ));
                }
            },
            _ => {
                return Err(IdeviceError::UnexpectedResponse(
                    "missing BoardId in personalization identifiers".into(),
                ));
            }
        };
        let chip_id = match personalization_identifiers.get("ChipID") {
            Some(plist::Value::Integer(b)) => match b.as_unsigned() {
                Some(b) => b,
                None => {
                    return Err(IdeviceError::UnexpectedResponse(
                        "ChipID is not an unsigned integer".into(),
                    ));
                }
            },
            _ => {
                return Err(IdeviceError::UnexpectedResponse(
                    "missing ChipID in personalization identifiers".into(),
                ));
            }
        };

        request.set_ap_img4_ticket(true);
        request.set_bb_ticket(true);
        let ap_nonce = self.query_nonce(Some("DeveloperDiskImage")).await?;
        request.add_common_tags(
            board_id,
            chip_id,
            unique_chip_id,
            Some(ap_nonce),
            Some(vec![0; 20]),
        );

        let build_identity =
            crate::tss::select_build_identity(build_manifest, board_id, chip_id, None)?;

        let parameters = crate::plist!(dict {
            "ApProductionMode": true,
            "ApSecurityMode": true,
            "ApSupportsImg4": true
        });

        let ddi_rules: &[plist::Value] = build_identity
            .get("Manifest")
            .and_then(|m| m.as_dictionary())
            .and_then(|m| m.get("LoadableTrustCache"))
            .and_then(|c| c.as_dictionary())
            .and_then(|c| c.get("Info"))
            .and_then(|i| i.as_dictionary())
            .and_then(|i| i.get("RestoreRequestRules"))
            .and_then(|r| r.as_array())
            .map(|v| v.as_slice())
            .unwrap_or(&[]);

        request.populate_from_manifest(build_identity, &parameters, Some(ddi_rules))?;

        let res = request.send().await?;
        let res = match res {
            plist::Value::Dictionary(r) => r,
            _ => {
                warn!("Apple returned a non-dictionary plist");
                return Err(IdeviceError::UnexpectedResponse(
                    "TSS response is not a dictionary".into(),
                ));
            }
        };

        crate::tss::extract_img4_ticket(&res)
    }
}

#[cfg(feature = "rsd")]
impl crate::RsdService for ImageMounter {
    fn rsd_service_name() -> std::borrow::Cow<'static, str> {
        crate::obf!("com.apple.mobile.mobile_image_mounter.shim.remote")
    }
    async fn from_stream(stream: Box<dyn crate::ReadWrite>) -> Result<Self, crate::IdeviceError> {
        let mut idevice = crate::Idevice::new(stream, "");
        idevice.rsd_checkin().await?;
        Ok(Self::new(idevice))
    }
}

#[cfg(test)]
mod tests {
    use std::{
        io,
        pin::Pin,
        sync::{Arc, Mutex},
        task::{Context, Poll},
    };

    use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

    use super::{
        IMAGE_UPLOAD_CHUNK_SIZE, parse_image_presence_response, parse_lookup_image_response,
        stream_image_exactly,
    };
    #[cfg(feature = "tss")]
    use super::{hash_image_and_rewind, hash_image_exactly, should_fetch_manifest_from_tss};
    use crate::IdeviceError;
    #[cfg(feature = "tss")]
    use sha2::{Digest, Sha384};

    #[test]
    fn lookup_image_distinguishes_absence_from_malformed_responses() {
        let absent = plist::Dictionary::from_iter([(
            String::from("ImagePresent"),
            plist::Value::Boolean(false),
        )]);
        assert_eq!(parse_lookup_image_response(&absent).unwrap(), None);

        for signature in [
            plist::Value::Data(vec![1, 2, 3]),
            plist::Value::Array(vec![plist::Value::Data(vec![4, 5, 6])]),
            plist::Value::Array(vec![
                plist::Value::Data(vec![7, 8]),
                plist::Value::Data(vec![9, 10]),
            ]),
        ] {
            let response =
                plist::Dictionary::from_iter([(String::from("ImageSignature"), signature)]);
            assert!(parse_lookup_image_response(&response).unwrap().is_some());
        }

        for malformed in [
            plist::Dictionary::new(),
            plist::Dictionary::from_iter([(
                String::from("ImagePresent"),
                plist::Value::String("false".into()),
            )]),
            plist::Dictionary::from_iter([(
                String::from("ImageSignature"),
                plist::Value::Data(Vec::new()),
            )]),
            plist::Dictionary::from_iter([(
                String::from("ImageSignature"),
                plist::Value::Array(Vec::new()),
            )]),
            plist::Dictionary::from_iter([(
                String::from("ImageSignature"),
                plist::Value::Array(vec![plist::Value::String("not data".into())]),
            )]),
        ] {
            assert!(matches!(
                parse_lookup_image_response(&malformed),
                Err(IdeviceError::UnexpectedResponse(_))
            ));
        }
    }

    #[test]
    fn lookup_image_malformed_signatures_retain_a_safe_shape_category() {
        for (signature, expected_reason) in [
            (
                plist::Value::Data(Vec::new()),
                "LookupImage returned an empty image signature",
            ),
            (
                plist::Value::Array(Vec::new()),
                "LookupImage returned an empty signature array",
            ),
            (
                plist::Value::String("not data".into()),
                "LookupImage returned an unsupported image signature type",
            ),
        ] {
            let response =
                plist::Dictionary::from_iter([(String::from("ImageSignature"), signature)]);

            let error = parse_lookup_image_response(&response).unwrap_err();
            let IdeviceError::UnexpectedResponse(reason) = error else {
                panic!("unexpected error category: {error:?}");
            };
            assert_eq!(reason, expected_reason);
        }
    }

    #[test]
    fn image_presence_does_not_require_signature_material() {
        let present_without_signature = plist::Dictionary::from_iter([
            (String::from("ImagePresent"), plist::Value::Boolean(true)),
            (
                String::from("ImageSignature"),
                plist::Value::Array(Vec::new()),
            ),
        ]);
        let absent = plist::Dictionary::from_iter([(
            String::from("ImagePresent"),
            plist::Value::Boolean(false),
        )]);
        let legacy_present = plist::Dictionary::from_iter([(
            String::from("ImageSignature"),
            plist::Value::Data(vec![1, 2, 3]),
        )]);
        let remote_shim_present = plist::Dictionary::from_iter([(
            String::from("ImageSignature"),
            plist::Value::Array(Vec::new()),
        )]);

        assert!(parse_image_presence_response(&present_without_signature).unwrap());
        assert!(!parse_image_presence_response(&absent).unwrap());
        assert!(parse_image_presence_response(&legacy_present).unwrap());
        assert!(parse_image_presence_response(&remote_shim_present).unwrap());
    }

    #[test]
    fn image_presence_rejects_malformed_nonempty_signature_arrays() {
        for signatures in [
            vec![plist::Value::String("not data".into())],
            vec![plist::Value::Data(Vec::new())],
            vec![
                plist::Value::Data(vec![1, 2, 3]),
                plist::Value::String("not data".into()),
            ],
        ] {
            let response = plist::Dictionary::from_iter([(
                String::from("ImageSignature"),
                plist::Value::Array(signatures),
            )]);

            assert!(matches!(
                parse_image_presence_response(&response),
                Err(IdeviceError::UnexpectedResponse(_))
            ));
        }
    }

    #[test]
    fn image_presence_rejects_an_empty_legacy_signature() {
        let response = plist::Dictionary::from_iter([(
            String::from("ImageSignature"),
            plist::Value::Data(Vec::new()),
        )]);

        assert!(matches!(
            parse_image_presence_response(&response),
            Err(IdeviceError::UnexpectedResponse(_))
        ));
    }

    #[test]
    #[cfg(feature = "tss")]
    fn tss_fallback_requires_a_definitive_device_cache_miss() {
        assert!(should_fetch_manifest_from_tss(&IdeviceError::NotFound));
        assert!(!should_fetch_manifest_from_tss(
            &IdeviceError::NoEstablishedConnection
        ));
        assert!(!should_fetch_manifest_from_tss(
            &IdeviceError::UnexpectedResponse("malformed device response".into())
        ));
        assert!(!should_fetch_manifest_from_tss(&IdeviceError::Socket(
            io::Error::new(io::ErrorKind::ConnectionReset, "injected transport failure")
        )));
    }

    #[derive(Debug)]
    struct ChunkedReader {
        bytes: Vec<u8>,
        position: usize,
        max_read: usize,
        fail_at: Option<usize>,
        max_requested: usize,
    }

    impl ChunkedReader {
        fn new(bytes: Vec<u8>, max_read: usize) -> Self {
            Self {
                bytes,
                position: 0,
                max_read,
                fail_at: None,
                max_requested: 0,
            }
        }

        fn failing(bytes: Vec<u8>, max_read: usize, fail_at: usize) -> Self {
            Self {
                fail_at: Some(fail_at),
                ..Self::new(bytes, max_read)
            }
        }
    }

    impl AsyncRead for ChunkedReader {
        fn poll_read(
            mut self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            buffer: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            self.max_requested = self.max_requested.max(buffer.remaining());
            if self.fail_at.is_some_and(|fail_at| self.position >= fail_at) {
                return Poll::Ready(Err(io::Error::new(
                    io::ErrorKind::ConnectionReset,
                    "injected read failure",
                )));
            }
            if self.position == self.bytes.len() {
                return Poll::Ready(Ok(()));
            }

            let count = self
                .max_read
                .min(buffer.remaining())
                .min(self.bytes.len() - self.position);
            let end = self.position + count;
            buffer.put_slice(&self.bytes[self.position..end]);
            self.position = end;
            Poll::Ready(Ok(()))
        }
    }

    #[derive(Debug)]
    struct PartialWriter {
        bytes: Vec<u8>,
        max_write: usize,
        fail_at: Option<usize>,
    }

    impl PartialWriter {
        fn new(max_write: usize) -> Self {
            Self {
                bytes: Vec::new(),
                max_write,
                fail_at: None,
            }
        }

        fn failing(max_write: usize, fail_at: usize) -> Self {
            Self {
                fail_at: Some(fail_at),
                ..Self::new(max_write)
            }
        }
    }

    impl AsyncWrite for PartialWriter {
        fn poll_write(
            mut self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            bytes: &[u8],
        ) -> Poll<io::Result<usize>> {
            if self
                .fail_at
                .is_some_and(|fail_at| self.bytes.len() >= fail_at)
            {
                return Poll::Ready(Err(io::Error::new(
                    io::ErrorKind::BrokenPipe,
                    "injected write failure",
                )));
            }

            let remaining_before_failure = self
                .fail_at
                .map_or(usize::MAX, |fail_at| fail_at - self.bytes.len());
            let count = bytes
                .len()
                .min(self.max_write)
                .min(remaining_before_failure);
            if count == 0 {
                return Poll::Ready(Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "injected zero-length write",
                )));
            }
            self.bytes.extend_from_slice(&bytes[..count]);
            Poll::Ready(Ok(count))
        }

        fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }

        fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }
    }

    #[tokio::test]
    async fn streams_exact_bytes_with_bounded_reads_and_partial_writes() {
        let bytes: Vec<u8> = (0..IMAGE_UPLOAD_CHUNK_SIZE * 2 + 17)
            .map(|index| (index % 251) as u8)
            .collect();
        let mut reader = ChunkedReader::new(bytes.clone(), 1_021);
        let mut writer = PartialWriter::new(997);
        let progress = Arc::new(Mutex::new(Vec::new()));
        let progress_for_callback = Arc::clone(&progress);

        stream_image_exactly(
            &mut reader,
            &mut writer,
            bytes.len() as u64,
            move |sent, total| {
                let progress = Arc::clone(&progress_for_callback);
                async move {
                    progress.lock().unwrap().push((sent, total));
                }
            },
        )
        .await
        .unwrap();

        assert_eq!(writer.bytes, bytes);
        assert!(reader.max_requested <= IMAGE_UPLOAD_CHUNK_SIZE);
        assert_eq!(
            *progress.lock().unwrap(),
            vec![
                (
                    IMAGE_UPLOAD_CHUNK_SIZE as u64,
                    (IMAGE_UPLOAD_CHUNK_SIZE * 2 + 17) as u64,
                ),
                (
                    (IMAGE_UPLOAD_CHUNK_SIZE * 2) as u64,
                    (IMAGE_UPLOAD_CHUNK_SIZE * 2 + 17) as u64,
                ),
                (
                    (IMAGE_UPLOAD_CHUNK_SIZE * 2 + 17) as u64,
                    (IMAGE_UPLOAD_CHUNK_SIZE * 2 + 17) as u64,
                ),
            ]
        );
    }

    #[tokio::test]
    async fn rejects_a_reader_that_ends_before_the_declared_size() {
        let mut reader = ChunkedReader::new(vec![1, 2, 3], 2);
        let mut writer = PartialWriter::new(2);

        let error = stream_image_exactly(&mut reader, &mut writer, 4, |_, _| async {})
            .await
            .unwrap_err();

        assert!(
            matches!(error, IdeviceError::Socket(ref source) if source.kind() == io::ErrorKind::UnexpectedEof)
        );
        assert!(writer.bytes.is_empty());
    }

    #[tokio::test]
    async fn rejects_a_reader_that_exceeds_the_declared_size() {
        let mut reader = ChunkedReader::new(vec![1, 2, 3, 4], 2);
        let mut writer = PartialWriter::new(2);

        let error = stream_image_exactly(&mut reader, &mut writer, 3, |_, _| async {})
            .await
            .unwrap_err();

        assert!(
            matches!(error, IdeviceError::UnexpectedResponse(ref message) if message == "image reader exceeds its declared size")
        );
        assert_eq!(writer.bytes, vec![1, 2, 3]);
    }

    #[tokio::test]
    async fn propagates_reader_and_writer_failures() {
        let mut reader = ChunkedReader::failing(vec![0; 32], 4, 8);
        let mut writer = PartialWriter::new(4);
        let read_error = stream_image_exactly(&mut reader, &mut writer, 32, |_, _| async {})
            .await
            .unwrap_err();
        assert!(
            matches!(read_error, IdeviceError::Socket(ref source) if source.kind() == io::ErrorKind::ConnectionReset)
        );

        let mut reader = ChunkedReader::new(vec![0; 32], 4);
        let mut writer = PartialWriter::failing(4, 8);
        let write_error = stream_image_exactly(&mut reader, &mut writer, 32, |_, _| async {})
            .await
            .unwrap_err();
        assert!(
            matches!(write_error, IdeviceError::Socket(ref source) if source.kind() == io::ErrorKind::BrokenPipe)
        );
    }

    #[tokio::test]
    async fn boundary_sizes_never_overread_or_panic() {
        for size in [
            0,
            1,
            IMAGE_UPLOAD_CHUNK_SIZE - 1,
            IMAGE_UPLOAD_CHUNK_SIZE,
            IMAGE_UPLOAD_CHUNK_SIZE + 1,
            IMAGE_UPLOAD_CHUNK_SIZE * 2 + 1,
        ] {
            let bytes: Vec<u8> = (0..size).map(|index| (index % 251) as u8).collect();
            let mut reader = ChunkedReader::new(bytes.clone(), 257);
            let mut writer = PartialWriter::new(509);

            stream_image_exactly(&mut reader, &mut writer, size as u64, |_, _| async {})
                .await
                .unwrap();

            assert_eq!(writer.bytes, bytes);
            assert!(reader.max_requested <= IMAGE_UPLOAD_CHUNK_SIZE);
        }
    }

    #[tokio::test]
    #[cfg(feature = "tss")]
    async fn hashes_a_partial_reader_without_loading_the_whole_image() {
        let bytes: Vec<u8> = (0..IMAGE_UPLOAD_CHUNK_SIZE * 2 + 17)
            .map(|index| (index % 251) as u8)
            .collect();
        let expected = Sha384::digest(&bytes);
        let mut reader = ChunkedReader::new(bytes.clone(), 1_021);

        let actual = hash_image_exactly(&mut reader, bytes.len() as u64)
            .await
            .unwrap();

        assert_eq!(actual.as_slice(), expected.as_slice());
        assert!(reader.max_requested <= IMAGE_UPLOAD_CHUNK_SIZE);
    }

    #[tokio::test]
    #[cfg(feature = "tss")]
    async fn hashing_restores_the_reader_to_its_original_position() {
        let prefix = b"prefix";
        let image = b"developer-disk-image";
        let mut bytes = prefix.to_vec();
        bytes.extend_from_slice(image);
        let mut reader = std::io::Cursor::new(bytes);
        reader.set_position(prefix.len() as u64);

        let actual = hash_image_and_rewind(&mut reader, image.len() as u64)
            .await
            .unwrap();

        assert_eq!(actual, Sha384::digest(image).to_vec());
        assert_eq!(reader.position(), prefix.len() as u64);
    }
}
