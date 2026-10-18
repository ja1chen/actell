// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Javier Soto. Adapted from Device Hub; see ../DEVICE_HUB_LICENSE.
//! Bounded structural validation for CoreDevice screenshot payloads.

const PNG_SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";
const MAX_PNG_BYTES: usize = 64 * 1024 * 1024;
const MAX_DIMENSION: u32 = 16_384;
const MAX_PIXELS: u64 = 128 * 1024 * 1024;

/// Validated dimensions extracted from a PNG IHDR chunk.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct PngDimensions {
    pub(crate) width: u32,
    pub(crate) height: u32,
}

/// Sanitized PNG validation failure.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct PngError;

/// Validates framing, CRCs, required chunks, dimensions, and a strict size
/// bound without decompressing attacker-controlled image data.
pub(crate) fn validate_png(bytes: &[u8]) -> Result<PngDimensions, PngError> {
    if bytes.len() > MAX_PNG_BYTES || bytes.get(..PNG_SIGNATURE.len()) != Some(PNG_SIGNATURE) {
        return Err(PngError);
    }

    let mut offset = PNG_SIGNATURE.len();
    let mut dimensions = None;
    let mut saw_image_data = false;
    let mut saw_end = false;
    let mut chunk_index = 0_usize;

    while offset < bytes.len() {
        let header_end = offset.checked_add(8).ok_or(PngError)?;
        let header = bytes.get(offset..header_end).ok_or(PngError)?;
        let length = u32::from_be_bytes(header[..4].try_into().map_err(|_| PngError)?) as usize;
        let chunk_type: [u8; 4] = header[4..8].try_into().map_err(|_| PngError)?;
        let data_start = header_end;
        let data_end = data_start.checked_add(length).ok_or(PngError)?;
        let crc_end = data_end.checked_add(4).ok_or(PngError)?;
        let data = bytes.get(data_start..data_end).ok_or(PngError)?;
        let stored_crc = u32::from_be_bytes(
            bytes
                .get(data_end..crc_end)
                .ok_or(PngError)?
                .try_into()
                .map_err(|_| PngError)?,
        );
        let mut hasher = crc32fast::Hasher::new();
        hasher.update(&chunk_type);
        hasher.update(data);
        if hasher.finalize() != stored_crc {
            return Err(PngError);
        }

        match &chunk_type {
            b"IHDR" if chunk_index == 0 && length == 13 => {
                let width = u32::from_be_bytes(data[..4].try_into().map_err(|_| PngError)?);
                let height = u32::from_be_bytes(data[4..8].try_into().map_err(|_| PngError)?);
                if width == 0
                    || height == 0
                    || width > MAX_DIMENSION
                    || height > MAX_DIMENSION
                    || u64::from(width) * u64::from(height) > MAX_PIXELS
                {
                    return Err(PngError);
                }
                dimensions = Some(PngDimensions { width, height });
            }
            b"IHDR" => return Err(PngError),
            b"IDAT" if dimensions.is_some() && !data.is_empty() => saw_image_data = true,
            b"IEND" if length == 0 && dimensions.is_some() && saw_image_data => {
                saw_end = true;
                offset = crc_end;
                break;
            }
            b"IEND" => return Err(PngError),
            _ => {}
        }
        offset = crc_end;
        chunk_index = chunk_index.saturating_add(1);
    }

    if !saw_end || offset != bytes.len() {
        return Err(PngError);
    }
    dimensions.ok_or(PngError)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
        let mut output = Vec::new();
        output.extend_from_slice(&(data.len() as u32).to_be_bytes());
        output.extend_from_slice(kind);
        output.extend_from_slice(data);
        let mut hasher = crc32fast::Hasher::new();
        hasher.update(kind);
        hasher.update(data);
        output.extend_from_slice(&hasher.finalize().to_be_bytes());
        output
    }

    fn png(width: u32, height: u32) -> Vec<u8> {
        let mut output = PNG_SIGNATURE.to_vec();
        let mut ihdr = Vec::new();
        ihdr.extend_from_slice(&width.to_be_bytes());
        ihdr.extend_from_slice(&height.to_be_bytes());
        ihdr.extend_from_slice(&[8, 6, 0, 0, 0]);
        output.extend(chunk(b"IHDR", &ihdr));
        output.extend(chunk(b"IDAT", &[0x78, 0x9C, 0x03, 0x00]));
        output.extend(chunk(b"IEND", &[]));
        output
    }

    #[test]
    fn accepts_a_structurally_valid_png_and_preserves_dimensions() {
        assert_eq!(
            validate_png(&png(1179, 2556)).unwrap(),
            PngDimensions {
                width: 1179,
                height: 2556
            }
        );
    }

    #[test]
    fn rejects_empty_jpeg_truncated_corrupt_and_trailing_payloads() {
        let valid = png(10, 20);
        let mut corrupt = valid.clone();
        corrupt[29] ^= 1;
        let mut trailing = valid.clone();
        trailing.push(0);

        for invalid in [
            Vec::new(),
            b"\xFF\xD8\xFF\xE0jpeg".to_vec(),
            valid[..valid.len() - 1].to_vec(),
            corrupt,
            trailing,
        ] {
            assert_eq!(validate_png(&invalid), Err(PngError));
        }
    }

    #[test]
    fn rejects_zero_or_unbounded_dimensions() {
        for invalid in [
            png(0, 1),
            png(1, 0),
            png(MAX_DIMENSION + 1, 1),
            png(MAX_DIMENSION, MAX_DIMENSION),
        ] {
            assert_eq!(validate_png(&invalid), Err(PngError));
        }
    }
}
