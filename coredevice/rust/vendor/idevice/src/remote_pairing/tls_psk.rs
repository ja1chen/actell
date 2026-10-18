// Jackson Coxson
//! Manual TLS 1.2 PSK-AES128-CBC-SHA implementation.
//!
//! This implements just enough of TLS 1.2 to negotiate
//! `TLS_PSK_WITH_AES_128_CBC_SHA` (0x008C) with no certificates or DH.
//! The result is an encrypted stream suitable for CDTunnel.
//! We did this ourselves because rustls won't :(

use aes::cipher::{BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use hmac::{Hmac, Mac};
use sha1::Sha1;
use sha2::Sha256;
use std::pin::Pin;
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};
use tracing::debug;
use zeroize::Zeroizing;

use crate::{IdeviceError, remote_pairing::errors::RemotePairingError};

// TLS 1.2 constants
const TLS_12: [u8; 2] = [0x03, 0x03];
const CT_HANDSHAKE: u8 = 0x16;
const CT_CHANGE_CIPHER_SPEC: u8 = 0x14;
const CT_APPLICATION_DATA: u8 = 0x17;
/// Maximum plaintext bytes per TLS record (RFC 5246 §6.2.1)
const TLS_MAX_PLAINTEXT: usize = 16384;
/// RFC 5246 permits at most 2 KiB of record protection expansion.
const TLS_MAX_CIPHERTEXT: usize = TLS_MAX_PLAINTEXT + 2048;
const TLS_MAX_HANDSHAKE_MESSAGE: usize = 64 * 1024;
const HS_CLIENT_HELLO: u8 = 0x01;
const HS_SERVER_HELLO: u8 = 0x02;
const HS_SERVER_HELLO_DONE: u8 = 0x0E;
const HS_CLIENT_KEY_EXCHANGE: u8 = 0x10;
const HS_FINISHED: u8 = 0x14;
// Offer both; device typically picks AES256-CBC-SHA384
const PSK_CIPHER_SUITES: &[[u8; 2]] = &[
    [0x00, 0xAF], // TLS_PSK_WITH_AES_256_CBC_SHA384 (preferred by iOS)
    [0x00, 0x8C], // TLS_PSK_WITH_AES_128_CBC_SHA (fallback)
];

type HmacSha256 = Hmac<Sha256>;
type HmacSha1 = Hmac<Sha1>;
type HmacSha384 = Hmac<sha2::Sha384>;
type Aes128CbcEnc = cbc::Encryptor<aes::Aes128>;
type Aes128CbcDec = cbc::Decryptor<aes::Aes128>;
type Aes256CbcEnc = cbc::Encryptor<aes::Aes256>;
type Aes256CbcDec = cbc::Decryptor<aes::Aes256>;

/// Selected cipher suite parameters
#[derive(Clone, Copy, Debug)]
enum CipherSuite {
    Aes128CbcSha,    // 0x008C: 16-byte key, 20-byte MAC (SHA1), PRF=SHA256
    Aes256CbcSha384, // 0x00AF: 32-byte key, 48-byte MAC (SHA384), PRF=SHA384
}

impl CipherSuite {
    fn from_bytes(b: [u8; 2]) -> Option<Self> {
        match b {
            [0x00, 0x8C] => Some(Self::Aes128CbcSha),
            [0x00, 0xAF] => Some(Self::Aes256CbcSha384),
            _ => None,
        }
    }
    fn enc_key_len(self) -> usize {
        match self {
            Self::Aes128CbcSha => 16,
            Self::Aes256CbcSha384 => 32,
        }
    }
    fn mac_key_len(self) -> usize {
        match self {
            Self::Aes128CbcSha => 20,
            Self::Aes256CbcSha384 => 48,
        }
    }
}

struct KeyBlock {
    client_mac_key: Zeroizing<Vec<u8>>,
    server_mac_key: Zeroizing<Vec<u8>>,
    client_write_key: Zeroizing<Vec<u8>>,
    server_write_key: Zeroizing<Vec<u8>>,
    suite: CipherSuite,
}

fn hmac_compute(key: &[u8], data: &[u8], suite: CipherSuite) -> Vec<u8> {
    match suite {
        CipherSuite::Aes128CbcSha => {
            // PRF uses SHA256 for P_hash, but record MAC uses SHA1
            let mut mac = HmacSha256::new_from_slice(key).unwrap();
            mac.update(data);
            mac.finalize().into_bytes().to_vec()
        }
        CipherSuite::Aes256CbcSha384 => {
            let mut mac = HmacSha384::new_from_slice(key).unwrap();
            mac.update(data);
            mac.finalize().into_bytes().to_vec()
        }
    }
}

/// TLS 1.2 PRF: P_hash with the suite's PRF hash
fn prf(secret: &[u8], label: &[u8], seed: &[u8], len: usize, suite: CipherSuite) -> Vec<u8> {
    let mut label_seed = label.to_vec();
    label_seed.extend_from_slice(seed);

    let mut a = hmac_compute(secret, &label_seed, suite);
    let mut out = Vec::with_capacity(len);

    while out.len() < len {
        let mut input = a.clone();
        input.extend_from_slice(&label_seed);
        out.extend_from_slice(&hmac_compute(secret, &input, suite));
        a = hmac_compute(secret, &a, suite);
    }
    out.truncate(len);
    out
}

/// PSK premaster secret (RFC 4279 §2)
fn psk_premaster(psk: &[u8]) -> Vec<u8> {
    let psk_len = psk.len() as u16;
    let mut pm = Vec::with_capacity(4 + psk.len() * 2);
    pm.extend_from_slice(&psk_len.to_be_bytes());
    pm.extend(std::iter::repeat_n(0u8, psk.len()));
    pm.extend_from_slice(&psk_len.to_be_bytes());
    pm.extend_from_slice(psk);
    pm
}

fn derive_master_secret(
    psk: &[u8],
    client_random: &[u8; 32],
    server_random: &[u8; 32],
    suite: CipherSuite,
) -> Vec<u8> {
    let premaster = Zeroizing::new(psk_premaster(psk));
    let mut seed = client_random.to_vec();
    seed.extend_from_slice(server_random);
    prf(&premaster, b"master secret", &seed, 48, suite)
}

fn derive_key_block(
    master: &[u8],
    client_random: &[u8; 32],
    server_random: &[u8; 32],
    suite: CipherSuite,
) -> KeyBlock {
    let mut seed = server_random.to_vec();
    seed.extend_from_slice(client_random);
    let mac_len = suite.mac_key_len();
    let key_len = suite.enc_key_len();
    let total = mac_len * 2 + key_len * 2;
    let kb = Zeroizing::new(prf(master, b"key expansion", &seed, total, suite));
    let mut pos = 0;
    let client_mac_key = Zeroizing::new(kb[pos..pos + mac_len].to_vec());
    pos += mac_len;
    let server_mac_key = Zeroizing::new(kb[pos..pos + mac_len].to_vec());
    pos += mac_len;
    let client_write_key = Zeroizing::new(kb[pos..pos + key_len].to_vec());
    pos += key_len;
    let server_write_key = Zeroizing::new(kb[pos..pos + key_len].to_vec());
    KeyBlock {
        client_mac_key,
        server_mac_key,
        client_write_key,
        server_write_key,
        suite,
    }
}

fn compute_mac(mac_key: &[u8], seq: u64, ct: u8, data: &[u8], suite: CipherSuite) -> Vec<u8> {
    let mut buf = Vec::new();
    buf.extend_from_slice(&seq.to_be_bytes());
    buf.extend_from_slice(&[ct, 0x03, 0x03]);
    buf.extend_from_slice(&(data.len() as u16).to_be_bytes());
    buf.extend_from_slice(data);

    match suite {
        CipherSuite::Aes128CbcSha => {
            let mut mac = HmacSha1::new_from_slice(mac_key).unwrap();
            mac.update(&buf);
            mac.finalize().into_bytes().to_vec()
        }
        CipherSuite::Aes256CbcSha384 => {
            let mut mac = HmacSha384::new_from_slice(mac_key).unwrap();
            mac.update(&buf);
            mac.finalize().into_bytes().to_vec()
        }
    }
}

fn verify_mac(
    mac_key: &[u8],
    seq: u64,
    ct: u8,
    data: &[u8],
    received_mac: &[u8],
    suite: CipherSuite,
) -> Result<(), RemotePairingError> {
    let mut input = Vec::new();
    input.extend_from_slice(&seq.to_be_bytes());
    input.extend_from_slice(&[ct, 0x03, 0x03]);
    input.extend_from_slice(&(data.len() as u16).to_be_bytes());
    input.extend_from_slice(data);
    let verified = match suite {
        CipherSuite::Aes128CbcSha => HmacSha1::new_from_slice(mac_key)
            .map(|mut mac| {
                mac.update(&input);
                mac.verify_slice(received_mac).is_ok()
            })
            .unwrap_or(false),
        CipherSuite::Aes256CbcSha384 => HmacSha384::new_from_slice(mac_key)
            .map(|mut mac| {
                mac.update(&input);
                mac.verify_slice(received_mac).is_ok()
            })
            .unwrap_or(false),
    };
    if verified {
        Ok(())
    } else {
        Err(RemotePairingError::TlsPskRecordIntegrityFailed)
    }
}

fn encrypt_record(keys: &KeyBlock, seq: u64, ct: u8, plaintext: &[u8]) -> Vec<u8> {
    let mac = compute_mac(&keys.client_mac_key, seq, ct, plaintext, keys.suite);

    let mut payload = plaintext.to_vec();
    payload.extend_from_slice(&mac);

    // PKCS#7 padding (block size = 16 for both AES-128 and AES-256)
    let pad_len = 16 - (payload.len() % 16);
    payload.extend(std::iter::repeat_n(pad_len as u8 - 1, pad_len));

    let mut iv = [0u8; 16];
    rand::fill(&mut iv);

    let ciphertext = match keys.suite {
        CipherSuite::Aes128CbcSha => {
            let enc = Aes128CbcEnc::new(keys.client_write_key[..16].into(), &iv.into());
            enc.encrypt_padded_vec_mut::<aes::cipher::block_padding::NoPadding>(&payload)
        }
        CipherSuite::Aes256CbcSha384 => {
            let enc = Aes256CbcEnc::new(keys.client_write_key[..32].into(), &iv.into());
            enc.encrypt_padded_vec_mut::<aes::cipher::block_padding::NoPadding>(&payload)
        }
    };

    let mut result = iv.to_vec();
    result.extend_from_slice(&ciphertext);
    result
}

fn decrypt_record(
    keys: &KeyBlock,
    is_server: bool,
    seq: u64,
    ct: u8,
    encrypted: &[u8],
) -> Result<Vec<u8>, IdeviceError> {
    if encrypted.len() <= 16 || !(encrypted.len() - 16).is_multiple_of(16) {
        return Err(RemotePairingError::TlsPskRecordIntegrityFailed.into());
    }

    let iv = &encrypted[..16];
    let ciphertext = &encrypted[16..];
    let read_key = if is_server {
        &keys.server_write_key
    } else {
        &keys.client_write_key
    };
    let mac_key = if is_server {
        &keys.server_mac_key
    } else {
        &keys.client_mac_key
    };

    let decrypted = match keys.suite {
        CipherSuite::Aes128CbcSha => {
            let dec = Aes128CbcDec::new(read_key[..16].into(), iv.into());
            dec.decrypt_padded_vec_mut::<aes::cipher::block_padding::NoPadding>(ciphertext)
                .map_err(|_| RemotePairingError::TlsPskRecordIntegrityFailed)?
        }
        CipherSuite::Aes256CbcSha384 => {
            let dec = Aes256CbcDec::new(read_key[..32].into(), iv.into());
            dec.decrypt_padded_vec_mut::<aes::cipher::block_padding::NoPadding>(ciphertext)
                .map_err(|_| RemotePairingError::TlsPskRecordIntegrityFailed)?
        }
    };

    let unpadded = strip_tls_cbc_padding(&decrypted)?;
    let mac_len = keys.suite.mac_key_len();
    if unpadded.len() < mac_len {
        return Err(RemotePairingError::TlsPskRecordIntegrityFailed.into());
    }

    let plaintext = &unpadded[..unpadded.len() - mac_len];
    let received_mac = &unpadded[unpadded.len() - mac_len..];

    verify_mac(mac_key, seq, ct, plaintext, received_mac, keys.suite)?;

    Ok(plaintext.to_vec())
}

fn strip_tls_cbc_padding(decrypted: &[u8]) -> Result<&[u8], RemotePairingError> {
    let padding_value = decrypted
        .last()
        .copied()
        .ok_or(RemotePairingError::TlsPskRecordIntegrityFailed)?;
    let padding_length = usize::from(padding_value) + 1;
    let content_length = decrypted
        .len()
        .checked_sub(padding_length)
        .ok_or(RemotePairingError::TlsPskRecordIntegrityFailed)?;
    if !decrypted[content_length..]
        .iter()
        .all(|byte| *byte == padding_value)
    {
        return Err(RemotePairingError::TlsPskRecordIntegrityFailed);
    }
    Ok(&decrypted[..content_length])
}

fn verify_server_finished(
    actual: &[u8],
    expected_verify_data: &[u8; 12],
) -> Result<(), RemotePairingError> {
    if actual.len() != 16
        || actual[..4] != [HS_FINISHED, 0, 0, 12]
        || actual[4..] != *expected_verify_data
    {
        return Err(RemotePairingError::TlsPskServerFinishedVerificationFailed);
    }
    Ok(())
}

fn finished_verify_data(
    master: &[u8],
    label: &[u8],
    transcript: &[u8],
    suite: CipherSuite,
) -> [u8; 12] {
    use sha2::Digest;
    let hash: Vec<u8> = match suite {
        CipherSuite::Aes128CbcSha => sha2::Sha256::digest(transcript).to_vec(),
        CipherSuite::Aes256CbcSha384 => sha2::Sha384::digest(transcript).to_vec(),
    };
    prf(master, label, &hash, 12, suite).try_into().unwrap()
}

fn make_record(ct: u8, payload: &[u8]) -> Vec<u8> {
    let mut rec = vec![ct, 0x03, 0x03];
    rec.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    rec.extend_from_slice(payload);
    rec
}

fn make_handshake(msg_type: u8, body: &[u8]) -> Vec<u8> {
    let mut msg = vec![msg_type];
    let len = body.len() as u32;
    msg.extend_from_slice(&len.to_be_bytes()[1..]); // 3-byte length
    msg.extend_from_slice(body);
    msg
}

async fn read_record<S: AsyncRead + Unpin>(stream: &mut S) -> Result<(u8, Vec<u8>), IdeviceError> {
    let mut header = [0u8; 5];
    stream.read_exact(&mut header).await?;
    if header[1..3] != TLS_12 {
        return Err(IdeviceError::UnexpectedResponse(
            "TLS-PSK peer used an unsupported record version".into(),
        ));
    }
    let ct = header[0];
    let len = u16::from_be_bytes([header[3], header[4]]) as usize;
    if len > TLS_MAX_CIPHERTEXT {
        return Err(IdeviceError::UnexpectedResponse(
            "TLS-PSK record exceeds the TLS 1.2 ciphertext limit".into(),
        ));
    }
    let mut payload = vec![0u8; len];
    stream.read_exact(&mut payload).await?;
    Ok((ct, payload))
}

#[derive(Debug)]
struct HandshakeMessage {
    message_type: u8,
    encoded: Vec<u8>,
}

impl HandshakeMessage {
    fn body(&self) -> &[u8] {
        &self.encoded[4..]
    }
}

/// Reassembles handshake messages across arbitrary TLS record boundaries.
#[derive(Default)]
struct HandshakeReassembler {
    pending: Vec<u8>,
}

impl HandshakeReassembler {
    fn push(&mut self, bytes: &[u8]) -> Result<Vec<HandshakeMessage>, IdeviceError> {
        self.pending.extend_from_slice(bytes);
        let mut messages = Vec::new();
        let mut consumed = 0;

        while self.pending.len().saturating_sub(consumed) >= 4 {
            let header = &self.pending[consumed..consumed + 4];
            let body_length = u32::from_be_bytes([0, header[1], header[2], header[3]]) as usize;
            if body_length > TLS_MAX_HANDSHAKE_MESSAGE {
                return Err(IdeviceError::UnexpectedResponse(
                    "TLS-PSK handshake message exceeds the implementation limit".into(),
                ));
            }
            let message_length = 4_usize
                .checked_add(body_length)
                .ok_or(IdeviceError::IntegerOverflow)?;
            if self.pending.len() - consumed < message_length {
                break;
            }
            let end = consumed + message_length;
            messages.push(HandshakeMessage {
                message_type: header[0],
                encoded: self.pending[consumed..end].to_vec(),
            });
            consumed = end;
        }

        if consumed != 0 {
            self.pending.drain(..consumed);
        }
        Ok(messages)
    }

    fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }
}

fn parse_server_hello(body: &[u8]) -> Result<([u8; 32], CipherSuite), IdeviceError> {
    const FIXED_PREFIX: usize = 2 + 32 + 1;
    if body.len() < FIXED_PREFIX || body[..2] != TLS_12 {
        return Err(IdeviceError::UnexpectedResponse(
            "TLS-PSK ServerHello is malformed or not TLS 1.2".into(),
        ));
    }
    let mut server_random = [0; 32];
    server_random.copy_from_slice(&body[2..34]);
    let session_id_length = usize::from(body[34]);
    let parameters_start = FIXED_PREFIX
        .checked_add(session_id_length)
        .ok_or(IdeviceError::IntegerOverflow)?;
    let parameters_end = parameters_start
        .checked_add(3)
        .ok_or(IdeviceError::IntegerOverflow)?;
    if body.len() < parameters_end || body[parameters_start + 2] != 0 {
        return Err(IdeviceError::UnexpectedResponse(
            "TLS-PSK ServerHello parameters are malformed".into(),
        ));
    }
    let selected = [body[parameters_start], body[parameters_start + 1]];
    let suite = CipherSuite::from_bytes(selected).ok_or_else(|| {
        IdeviceError::UnexpectedResponse("TLS-PSK server selected an unsupported cipher".into())
    })?;

    let extensions = &body[parameters_end..];
    if !extensions.is_empty() {
        if extensions.len() < 2 {
            return Err(IdeviceError::UnexpectedResponse(
                "TLS-PSK ServerHello extensions are truncated".into(),
            ));
        }
        let declared = usize::from(u16::from_be_bytes([extensions[0], extensions[1]]));
        if extensions.len() != declared + 2 {
            return Err(IdeviceError::UnexpectedResponse(
                "TLS-PSK ServerHello extensions are malformed".into(),
            ));
        }
    }
    Ok((server_random, suite))
}

fn validate_psk_server_key_exchange(body: &[u8]) -> Result<(), IdeviceError> {
    if body.len() < 2 {
        return Err(IdeviceError::UnexpectedResponse(
            "TLS-PSK ServerKeyExchange is truncated".into(),
        ));
    }
    let hint_length = usize::from(u16::from_be_bytes([body[0], body[1]]));
    if body.len() != hint_length + 2 {
        return Err(IdeviceError::UnexpectedResponse(
            "TLS-PSK ServerKeyExchange has an invalid identity hint".into(),
        ));
    }
    Ok(())
}

/// Perform TLS 1.2 PSK handshake and return an encrypted stream.
pub async fn tls_psk_handshake<S: AsyncRead + AsyncWrite + Unpin + Send>(
    mut stream: S,
    psk: &[u8],
) -> Result<TlsPskStream<S>, IdeviceError> {
    let mut client_random = [0u8; 32];
    rand::fill(&mut client_random);
    let mut transcript = Vec::new();

    // 1. ClientHello
    let mut ch_body = Vec::new();
    ch_body.extend_from_slice(&TLS_12);
    ch_body.extend_from_slice(&client_random);
    ch_body.push(0x00); // session_id len = 0
    let suites_len = (PSK_CIPHER_SUITES.len() * 2) as u16;
    ch_body.extend_from_slice(&suites_len.to_be_bytes());
    for suite in PSK_CIPHER_SUITES {
        ch_body.extend_from_slice(suite);
    }
    ch_body.extend_from_slice(&[0x01, 0x00]); // compression: null
    let ch = make_handshake(HS_CLIENT_HELLO, &ch_body);
    transcript.extend_from_slice(&ch);
    stream.write_all(&make_record(CT_HANDSHAKE, &ch)).await?;
    debug!("Sent ClientHello");

    // 2. Read ServerHello, optional ServerKeyExchange (PSK hint), ServerHelloDone.
    // Handshake messages may be split or coalesced at arbitrary record boundaries.
    let mut reassembler = HandshakeReassembler::default();
    let mut negotiated = None;
    let mut saw_key_exchange = false;
    let mut server_flight_complete = false;
    loop {
        let (ct, payload) = read_record(&mut stream).await?;
        if ct == 21 {
            // TLS Alert
            let level = payload.first().copied().unwrap_or(0);
            let desc = payload.get(1).copied().unwrap_or(0);
            return Err(IdeviceError::InternalError(format!(
                "TLS Alert: level={level} desc={desc} ({})",
                match desc {
                    0 => "close_notify",
                    10 => "unexpected_message",
                    20 => "bad_record_mac",
                    40 => "handshake_failure",
                    47 => "illegal_parameter",
                    70 => "protocol_version",
                    71 => "insufficient_security",
                    80 => "internal_error",
                    _ => "unknown",
                }
            )));
        }
        if ct != CT_HANDSHAKE {
            return Err(IdeviceError::InternalError(format!(
                "Expected handshake, got ct={ct}"
            )));
        }
        transcript.extend_from_slice(&payload);

        for message in reassembler.push(&payload)? {
            if server_flight_complete {
                return Err(IdeviceError::UnexpectedResponse(
                    "TLS-PSK server sent handshake data after ServerHelloDone".into(),
                ));
            }
            match message.message_type {
                HS_SERVER_HELLO => {
                    if negotiated.is_some() || saw_key_exchange {
                        return Err(IdeviceError::UnexpectedResponse(
                            "TLS-PSK server sent an out-of-order ServerHello".into(),
                        ));
                    }
                    let parsed = parse_server_hello(message.body())?;
                    debug!("Got authenticated-shape ServerHello");
                    negotiated = Some(parsed);
                }
                0x0C => {
                    if negotiated.is_none() || saw_key_exchange {
                        return Err(IdeviceError::UnexpectedResponse(
                            "TLS-PSK server sent an out-of-order ServerKeyExchange".into(),
                        ));
                    }
                    validate_psk_server_key_exchange(message.body())?;
                    saw_key_exchange = true;
                }
                HS_SERVER_HELLO_DONE => {
                    if negotiated.is_none() || !message.body().is_empty() {
                        return Err(IdeviceError::UnexpectedResponse(
                            "TLS-PSK ServerHelloDone is malformed or out of order".into(),
                        ));
                    }
                    debug!("Got ServerHelloDone");
                    server_flight_complete = true;
                }
                _ => {
                    return Err(IdeviceError::UnexpectedResponse(
                        "TLS-PSK server sent an unexpected handshake message".into(),
                    ));
                }
            }
        }
        if server_flight_complete {
            if !reassembler.is_empty() {
                return Err(IdeviceError::UnexpectedResponse(
                    "TLS-PSK server flight ended with a partial handshake message".into(),
                ));
            }
            break;
        }
    }

    // 3. Determine cipher suite and derive keys
    let (server_random, suite) = negotiated.ok_or_else(|| {
        IdeviceError::UnexpectedResponse("TLS-PSK server omitted ServerHello".into())
    })?;
    debug!("Using cipher suite: {suite:?}");

    let master = Zeroizing::new(derive_master_secret(
        psk,
        &client_random,
        &server_random,
        suite,
    ));
    let keys = derive_key_block(&master, &client_random, &server_random, suite);

    // 4. ClientKeyExchange (empty PSK identity)
    let cke = make_handshake(HS_CLIENT_KEY_EXCHANGE, &[0x00, 0x00]);
    transcript.extend_from_slice(&cke);
    stream.write_all(&make_record(CT_HANDSHAKE, &cke)).await?;
    debug!("Sent ClientKeyExchange");

    // 5. ChangeCipherSpec
    stream
        .write_all(&make_record(CT_CHANGE_CIPHER_SPEC, &[0x01]))
        .await?;
    debug!("Sent ChangeCipherSpec");

    // 6. Client Finished (encrypted)
    let vd = finished_verify_data(&master, b"client finished", &transcript, suite);
    let fin = make_handshake(HS_FINISHED, &vd);
    transcript.extend_from_slice(&fin);
    let enc_fin = encrypt_record(&keys, 0, CT_HANDSHAKE, &fin);
    stream
        .write_all(&make_record(CT_HANDSHAKE, &enc_fin))
        .await?;
    stream.flush().await?;
    debug!("Sent encrypted Finished");

    // 7. Read server ChangeCipherSpec + Finished
    let mut server_seq: u64 = 0;
    let mut received_change_cipher_spec = false;
    loop {
        let (ct, payload) = read_record(&mut stream).await?;
        if ct == 21 {
            let level = payload.first().copied().unwrap_or(0);
            let desc = payload.get(1).copied().unwrap_or(0);
            return Err(IdeviceError::InternalError(format!(
                "TLS Alert after Finished: level={level} desc={desc}"
            )));
        }
        match ct {
            CT_CHANGE_CIPHER_SPEC => {
                if received_change_cipher_spec || payload != [0x01] {
                    return Err(IdeviceError::UnexpectedResponse(
                        "TLS-PSK server sent an invalid ChangeCipherSpec".into(),
                    ));
                }
                received_change_cipher_spec = true;
                debug!("Got server ChangeCipherSpec");
            }
            CT_HANDSHAKE if received_change_cipher_spec => {
                let plaintext = decrypt_record(&keys, true, server_seq, CT_HANDSHAKE, &payload)?;
                server_seq = server_seq
                    .checked_add(1)
                    .ok_or(IdeviceError::IntegerOverflow)?;
                let server_vd =
                    finished_verify_data(&master, b"server finished", &transcript, suite);
                verify_server_finished(&plaintext, &server_vd)?;
                debug!("Server Finished verified!");
                break;
            }
            _ => {
                return Err(IdeviceError::UnexpectedResponse(
                    "TLS-PSK server sent an out-of-order Finished flight".into(),
                ));
            }
        }
    }

    debug!("TLS-PSK handshake complete");

    Ok(TlsPskStream {
        inner: stream,
        keys,
        write_seq: 1, // seq 0 was used for client Finished
        read_seq: server_seq,
        read_buf: Vec::new(),
        pending_record: Vec::new(),
        pending_record_total: 0,
        pending_write: None,
    })
}

/// A TLS record that has been accepted from the `AsyncWrite` caller but has not
/// yet been completely forwarded to the underlying transport.
struct PendingWrite {
    record: Vec<u8>,
    offset: usize,
}

impl PendingWrite {
    fn remaining(&self) -> &[u8] {
        &self.record[self.offset..]
    }
}

/// An encrypted TLS-PSK stream implementing AsyncRead + AsyncWrite.
pub struct TlsPskStream<S> {
    inner: S,
    keys: KeyBlock,
    write_seq: u64,
    read_seq: u64,
    /// Decrypted plaintext buffered for reads
    read_buf: Vec<u8>,
    /// Partial inbound TLS record being assembled
    pending_record: Vec<u8>,
    /// Expected total bytes for the current inbound record (5 + body_len), 0 if unknown
    pending_record_total: usize,
    /// Accepted outbound TLS record waiting to be flushed
    pending_write: Option<PendingWrite>,
}

impl<S> std::fmt::Debug for TlsPskStream<S> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TlsPskStream")
            .field("write_seq", &self.write_seq)
            .field("read_seq", &self.read_seq)
            .finish()
    }
}

impl<S: AsyncRead + AsyncWrite + Unpin + Send> TlsPskStream<S> {
    /// Encrypt and send application data, splitting into multiple TLS records if needed.
    pub async fn write_app_data(&mut self, data: &[u8]) -> Result<(), IdeviceError> {
        self.write_all(data).await?;
        self.flush().await?;
        Ok(())
    }

    /// Read and decrypt application data.
    pub async fn read_app_data(&mut self) -> Result<Vec<u8>, IdeviceError> {
        let (ct, payload) = read_record(&mut self.inner).await?;
        if ct != CT_APPLICATION_DATA {
            return Err(IdeviceError::InternalError(format!(
                "Expected application data, got ct={ct}"
            )));
        }
        let plaintext = decrypt_record(
            &self.keys,
            true,
            self.read_seq,
            CT_APPLICATION_DATA,
            &payload,
        )?;
        self.read_seq += 1;
        Ok(plaintext)
    }
}

// AsyncRead: assemble complete TLS records across multiple poll_read calls
impl<S: AsyncRead + AsyncWrite + Unpin> AsyncRead for TlsPskStream<S> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let this = self.get_mut();

        // 1. Serve from decrypted buffer first
        if !this.read_buf.is_empty() {
            let n = buf.remaining().min(this.read_buf.len());
            buf.put_slice(&this.read_buf[..n]);
            this.read_buf.drain(..n);
            return Poll::Ready(Ok(()));
        }

        // 2. Continue assembling a TLS record
        loop {
            // If we have the header (5 bytes), compute total needed
            if this.pending_record.len() >= 5 && this.pending_record_total == 0 {
                let body_len =
                    u16::from_be_bytes([this.pending_record[3], this.pending_record[4]]) as usize;
                this.pending_record_total = 5 + body_len;
            }

            // If we have a complete record, decrypt it
            if this.pending_record_total > 0
                && this.pending_record.len() >= this.pending_record_total
            {
                let ct = this.pending_record[0];
                let body = this.pending_record[5..this.pending_record_total].to_vec();
                this.pending_record.drain(..this.pending_record_total);
                this.pending_record_total = 0;

                match decrypt_record(&this.keys, true, this.read_seq, ct, &body) {
                    Ok(plaintext) => {
                        this.read_seq += 1;
                        let n = buf.remaining().min(plaintext.len());
                        buf.put_slice(&plaintext[..n]);
                        if n < plaintext.len() {
                            this.read_buf.extend_from_slice(&plaintext[n..]);
                        }
                        return Poll::Ready(Ok(()));
                    }
                    Err(e) => {
                        tracing::warn!(
                            "TLS decrypt failed (ct={ct}, seq={}, body_len={}): {e}",
                            this.read_seq,
                            body.len()
                        );
                        return Poll::Ready(Err(std::io::Error::other(format!(
                            "TLS decrypt: {e}"
                        ))));
                    }
                }
            }

            // Need more data from the underlying stream
            let mut tmp = [0u8; 16384];
            let mut tmp_buf = ReadBuf::new(&mut tmp);
            match Pin::new(&mut this.inner).poll_read(cx, &mut tmp_buf) {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                Poll::Ready(Ok(())) => {
                    let n = tmp_buf.filled().len();
                    if n == 0 {
                        return Poll::Ready(Ok(())); // EOF
                    }
                    this.pending_record.extend_from_slice(&tmp[..n]);
                    // Loop back to check if we now have a complete record
                }
            }
        }
    }
}

/// Drives an already-accepted TLS record to the underlying transport.
///
/// The caller's plaintext was acknowledged before this state was entered, so a
/// pending transport must never cause the plaintext to be encrypted again.
fn poll_pending_write<S: AsyncWrite + Unpin>(
    inner: &mut S,
    pending_write: &mut Option<PendingWrite>,
    cx: &mut Context<'_>,
) -> Poll<std::io::Result<()>> {
    loop {
        let Some(write) = pending_write.as_mut() else {
            return Poll::Ready(Ok(()));
        };

        if write.remaining().is_empty() {
            *pending_write = None;
            return Poll::Ready(Ok(()));
        }

        let remaining_length = write.remaining().len();
        match Pin::new(&mut *inner).poll_write(cx, write.remaining()) {
            Poll::Ready(Ok(0)) => {
                return Poll::Ready(Err(std::io::Error::new(
                    std::io::ErrorKind::WriteZero,
                    "underlying TLS transport accepted zero bytes",
                )));
            }
            Poll::Ready(Ok(written)) if written <= remaining_length => {
                write.offset += written;
            }
            Poll::Ready(Ok(_)) => {
                return Poll::Ready(Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "underlying TLS transport reported an invalid write length",
                )));
            }
            Poll::Ready(Err(error)) => return Poll::Ready(Err(error)),
            Poll::Pending => return Poll::Pending,
        }
    }
}

impl<S: AsyncRead + AsyncWrite + Unpin> AsyncWrite for TlsPskStream<S> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        data: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        let this = self.get_mut();

        // A pending record belongs to an earlier, already-acknowledged write.
        // Finish it before accepting any bytes from this invocation.
        match poll_pending_write(&mut this.inner, &mut this.pending_write, cx) {
            Poll::Ready(Ok(())) => {}
            Poll::Ready(Err(error)) => return Poll::Ready(Err(error)),
            Poll::Pending => return Poll::Pending,
        }

        if data.is_empty() {
            return Poll::Ready(Ok(0));
        }

        // Clamp to TLS max record size to avoid oversized records
        let chunk = &data[..data.len().min(TLS_MAX_PLAINTEXT)];

        // Copying the plaintext into this encrypted record is the acceptance
        // boundary. From here on, the caller may advance by `chunk.len()`.
        let encrypted = encrypt_record(&this.keys, this.write_seq, CT_APPLICATION_DATA, chunk);
        let record = make_record(CT_APPLICATION_DATA, &encrypted);
        this.write_seq += 1;
        this.pending_write = Some(PendingWrite { record, offset: 0 });

        // Opportunistically forward once. Even if the transport is pending,
        // the plaintext has been accepted into the bounded record buffer.
        let write = this
            .pending_write
            .as_mut()
            .expect("pending write was just initialized");
        let remaining_length = write.remaining().len();
        match Pin::new(&mut this.inner).poll_write(cx, write.remaining()) {
            Poll::Ready(Ok(0)) => {
                this.pending_write = None;
                this.write_seq -= 1;
                Poll::Ready(Err(std::io::Error::new(
                    std::io::ErrorKind::WriteZero,
                    "underlying TLS transport accepted zero bytes",
                )))
            }
            Poll::Ready(Ok(written)) if written <= remaining_length => {
                write.offset += written;
                if write.remaining().is_empty() {
                    this.pending_write = None;
                }
                Poll::Ready(Ok(chunk.len()))
            }
            Poll::Ready(Ok(_)) => {
                this.pending_write = None;
                this.write_seq -= 1;
                Poll::Ready(Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "underlying TLS transport reported an invalid write length",
                )))
            }
            Poll::Ready(Err(error)) => {
                this.pending_write = None;
                this.write_seq -= 1;
                Poll::Ready(Err(error))
            }
            Poll::Pending => Poll::Ready(Ok(chunk.len())),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        let this = self.get_mut();

        match poll_pending_write(&mut this.inner, &mut this.pending_write, cx) {
            Poll::Ready(Ok(())) => {}
            Poll::Ready(Err(error)) => return Poll::Ready(Err(error)),
            Poll::Pending => return Poll::Pending,
        }

        Pin::new(&mut this.inner).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        let this = self.get_mut();

        match poll_pending_write(&mut this.inner, &mut this.pending_write, cx) {
            Poll::Ready(Ok(())) => {}
            Poll::Ready(Err(error)) => return Poll::Ready(Err(error)),
            Poll::Pending => return Poll::Pending,
        }

        match Pin::new(&mut this.inner).poll_flush(cx) {
            Poll::Ready(Ok(())) => {}
            Poll::Ready(Err(error)) => return Poll::Ready(Err(error)),
            Poll::Pending => return Poll::Pending,
        }

        Pin::new(&mut this.inner).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    use std::time::Duration;
    use tokio::io::AsyncWriteExt;

    fn valid_server_hello_body() -> Vec<u8> {
        let mut body = TLS_12.to_vec();
        body.extend_from_slice(&[0x42; 32]);
        body.push(0);
        body.extend_from_slice(&[0x00, 0xAF]);
        body.push(0);
        body
    }

    #[test]
    fn handshake_reassembler_handles_every_record_boundary() {
        let first = make_handshake(HS_SERVER_HELLO, &valid_server_hello_body());
        let second = make_handshake(HS_SERVER_HELLO_DONE, &[]);
        let encoded = [first.clone(), second.clone()].concat();

        for split in 0..=encoded.len() {
            let mut reassembler = HandshakeReassembler::default();
            let mut messages = reassembler.push(&encoded[..split]).unwrap();
            messages.extend(reassembler.push(&encoded[split..]).unwrap());

            assert_eq!(messages.len(), 2, "split={split}");
            assert_eq!(messages[0].encoded, first, "split={split}");
            assert_eq!(messages[1].encoded, second, "split={split}");
            assert!(reassembler.is_empty(), "split={split}");
        }
    }

    #[test]
    fn handshake_reassembler_does_not_treat_a_body_pattern_as_hello_done() {
        let body = [0, 4, HS_SERVER_HELLO_DONE, 0, 0, 0];
        let encoded = make_handshake(0x0C, &body);
        let mut reassembler = HandshakeReassembler::default();

        let messages = reassembler.push(&encoded).unwrap();

        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].message_type, 0x0C);
        assert!(validate_psk_server_key_exchange(messages[0].body()).is_ok());
    }

    #[test]
    fn server_hello_validation_rejects_version_compression_and_extension_truncation() {
        assert!(parse_server_hello(&valid_server_hello_body()).is_ok());

        let mut wrong_version = valid_server_hello_body();
        wrong_version[..2].copy_from_slice(&[3, 1]);
        assert!(parse_server_hello(&wrong_version).is_err());

        let mut compression = valid_server_hello_body();
        *compression.last_mut().unwrap() = 1;
        assert!(parse_server_hello(&compression).is_err());

        let mut truncated_extensions = valid_server_hello_body();
        truncated_extensions.push(0);
        assert!(parse_server_hello(&truncated_extensions).is_err());
    }

    #[tokio::test]
    async fn record_reader_rejects_wrong_versions_and_oversized_ciphertext_before_allocating() {
        let mut wrong_version = std::io::Cursor::new([CT_HANDSHAKE, 3, 1, 0, 0]);
        assert!(read_record(&mut wrong_version).await.is_err());

        let oversized = u16::try_from(TLS_MAX_CIPHERTEXT + 1).unwrap();
        let mut oversized_header = vec![CT_HANDSHAKE, TLS_12[0], TLS_12[1]];
        oversized_header.extend_from_slice(&oversized.to_be_bytes());
        let mut oversized_record = std::io::Cursor::new(oversized_header);
        assert!(read_record(&mut oversized_record).await.is_err());
    }

    #[derive(Debug, Default)]
    struct AdversarialWriterState {
        bytes: Vec<u8>,
        flush_offsets: Vec<usize>,
        shutdown_offsets: Vec<usize>,
    }

    /// An in-memory transport that returns `Pending` before every bounded write.
    ///
    /// This models a socket whose readiness disappears at every possible record
    /// boundary while retaining the exact bytes accepted by the transport.
    struct AdversarialWriter {
        state: Arc<Mutex<AdversarialWriterState>>,
        max_write: usize,
        return_pending: bool,
        return_flush_pending: bool,
        return_shutdown_pending: bool,
    }

    impl AdversarialWriter {
        fn new(max_write: usize) -> (Self, Arc<Mutex<AdversarialWriterState>>) {
            Self::with_initial_pending(max_write, true)
        }

        fn with_initial_pending(
            max_write: usize,
            return_pending: bool,
        ) -> (Self, Arc<Mutex<AdversarialWriterState>>) {
            let state = Arc::new(Mutex::new(AdversarialWriterState::default()));
            (
                Self {
                    state: Arc::clone(&state),
                    max_write,
                    return_pending,
                    return_flush_pending: true,
                    return_shutdown_pending: true,
                },
                state,
            )
        }
    }

    impl AsyncRead for AdversarialWriter {
        fn poll_read(
            self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            _buf: &mut ReadBuf<'_>,
        ) -> Poll<std::io::Result<()>> {
            Poll::Pending
        }
    }

    impl AsyncWrite for AdversarialWriter {
        fn poll_write(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            data: &[u8],
        ) -> Poll<std::io::Result<usize>> {
            if self.return_pending {
                self.return_pending = false;
                cx.waker().wake_by_ref();
                return Poll::Pending;
            }

            self.return_pending = true;
            let written = data.len().min(self.max_write);
            self.state
                .lock()
                .expect("adversarial writer state poisoned")
                .bytes
                .extend_from_slice(&data[..written]);
            Poll::Ready(Ok(written))
        }

        fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
            if self.return_flush_pending {
                self.return_flush_pending = false;
                cx.waker().wake_by_ref();
                return Poll::Pending;
            }
            self.return_flush_pending = true;
            let bytes_written = self
                .state
                .lock()
                .expect("adversarial writer state poisoned")
                .bytes
                .len();
            self.state
                .lock()
                .expect("adversarial writer state poisoned")
                .flush_offsets
                .push(bytes_written);
            Poll::Ready(Ok(()))
        }

        fn poll_shutdown(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
        ) -> Poll<std::io::Result<()>> {
            if self.return_shutdown_pending {
                self.return_shutdown_pending = false;
                cx.waker().wake_by_ref();
                return Poll::Pending;
            }
            self.return_shutdown_pending = true;
            let bytes_written = self
                .state
                .lock()
                .expect("adversarial writer state poisoned")
                .bytes
                .len();
            self.state
                .lock()
                .expect("adversarial writer state poisoned")
                .shutdown_offsets
                .push(bytes_written);
            Poll::Ready(Ok(()))
        }
    }

    fn test_keys() -> KeyBlock {
        let suite = CipherSuite::Aes128CbcSha;
        KeyBlock {
            client_mac_key: Zeroizing::new(vec![0x11; suite.mac_key_len()]),
            server_mac_key: Zeroizing::new(vec![0x22; suite.mac_key_len()]),
            client_write_key: Zeroizing::new(vec![0x33; suite.enc_key_len()]),
            server_write_key: Zeroizing::new(vec![0x44; suite.enc_key_len()]),
            suite,
        }
    }

    fn test_stream(inner: AdversarialWriter) -> TlsPskStream<AdversarialWriter> {
        TlsPskStream {
            inner,
            keys: test_keys(),
            write_seq: 1,
            read_seq: 0,
            read_buf: Vec::new(),
            pending_record: Vec::new(),
            pending_record_total: 0,
            pending_write: None,
        }
    }

    fn captured_records(bytes: &[u8]) -> Vec<(u8, &[u8])> {
        let mut records = Vec::new();
        let mut remaining = bytes;
        while !remaining.is_empty() {
            assert!(remaining.len() >= 5, "truncated TLS record header");
            let payload_length = usize::from(u16::from_be_bytes([remaining[3], remaining[4]]));
            let record_length = 5 + payload_length;
            assert!(
                remaining.len() >= record_length,
                "truncated TLS record payload"
            );
            records.push((remaining[0], &remaining[5..record_length]));
            remaining = &remaining[record_length..];
        }
        records
    }

    #[tokio::test]
    async fn pending_underlying_write_emits_plaintext_exactly_once() {
        let (writer, state) = AdversarialWriter::new(7);
        let mut stream = test_stream(writer);
        let plaintext = b"one logical application write";

        let consumed = tokio::time::timeout(Duration::from_millis(250), stream.write(plaintext))
            .await
            .expect("poll_write never acknowledged the pending logical write")
            .expect("TLS write failed");
        assert_eq!(consumed, plaintext.len());
        stream.flush().await.expect("TLS flush failed");

        let bytes = state
            .lock()
            .expect("adversarial writer state poisoned")
            .bytes
            .clone();
        let records = captured_records(&bytes);
        assert_eq!(records.len(), 1, "one plaintext write must emit one record");
        assert_eq!(records[0].0, CT_APPLICATION_DATA);
        assert_eq!(
            decrypt_record(&test_keys(), false, 1, records[0].0, records[0].1)
                .expect("captured TLS record did not authenticate"),
            plaintext
        );
    }

    #[tokio::test]
    async fn partial_underlying_write_acknowledges_the_buffered_plaintext_once() {
        let (writer, state) = AdversarialWriter::with_initial_pending(1, false);
        let mut stream = test_stream(writer);
        let plaintext = b"partial transport write";

        assert_eq!(stream.write(plaintext).await.unwrap(), plaintext.len());
        assert_eq!(
            state
                .lock()
                .expect("adversarial writer state poisoned")
                .bytes
                .len(),
            1,
            "the first transport poll must be a real partial write"
        );
        stream.flush().await.unwrap();

        let bytes = state
            .lock()
            .expect("adversarial writer state poisoned")
            .bytes
            .clone();
        let records = captured_records(&bytes);
        assert_eq!(records.len(), 1);
        assert_eq!(
            decrypt_record(&test_keys(), false, 1, records[0].0, records[0].1).unwrap(),
            plaintext
        );
    }

    #[tokio::test]
    async fn flush_reaches_transport_only_after_the_complete_record() {
        let (writer, state) = AdversarialWriter::new(3);
        let mut stream = test_stream(writer);

        assert_eq!(stream.write(b"flush ordering").await.unwrap(), 14);
        stream.flush().await.unwrap();

        let state = state.lock().expect("adversarial writer state poisoned");
        assert_eq!(state.flush_offsets, [state.bytes.len()]);
        assert_eq!(captured_records(&state.bytes).len(), 1);
    }

    #[tokio::test]
    async fn back_to_back_writes_preserve_consumption_order_without_loss() {
        let (writer, state) = AdversarialWriter::new(5);
        let mut stream = test_stream(writer);
        let first = b"first application message";
        let second = b"second application message";

        assert_eq!(stream.write(first).await.unwrap(), first.len());
        assert_eq!(stream.write(second).await.unwrap(), second.len());
        stream.flush().await.unwrap();

        let bytes = state
            .lock()
            .expect("adversarial writer state poisoned")
            .bytes
            .clone();
        let records = captured_records(&bytes);
        assert_eq!(records.len(), 2);
        assert_eq!(
            decrypt_record(&test_keys(), false, 1, records[0].0, records[0].1).unwrap(),
            first
        );
        assert_eq!(
            decrypt_record(&test_keys(), false, 2, records[1].0, records[1].1).unwrap(),
            second
        );
    }

    #[tokio::test]
    async fn poll_write_reports_only_the_plaintext_chunk_it_accepted() {
        let (writer, state) = AdversarialWriter::new(11);
        let mut stream = test_stream(writer);
        let plaintext = vec![0x5A; TLS_MAX_PLAINTEXT + 23];

        let first_consumed = stream.write(&plaintext).await.unwrap();
        assert_eq!(first_consumed, TLS_MAX_PLAINTEXT);
        let second_consumed = stream.write(&plaintext[first_consumed..]).await.unwrap();
        assert_eq!(second_consumed, 23);
        stream.flush().await.unwrap();

        let bytes = state
            .lock()
            .expect("adversarial writer state poisoned")
            .bytes
            .clone();
        let records = captured_records(&bytes);
        assert_eq!(records.len(), 2);
        let mut decrypted =
            decrypt_record(&test_keys(), false, 1, records[0].0, records[0].1).unwrap();
        decrypted
            .extend(decrypt_record(&test_keys(), false, 2, records[1].0, records[1].1).unwrap());
        assert_eq!(decrypted, plaintext);
    }

    #[tokio::test]
    async fn shutdown_drains_the_accepted_record_before_closing_transport() {
        let (writer, state) = AdversarialWriter::new(2);
        let mut stream = test_stream(writer);
        let plaintext = b"last message before shutdown";

        assert_eq!(stream.write(plaintext).await.unwrap(), plaintext.len());
        stream.shutdown().await.unwrap();

        let state = state.lock().expect("adversarial writer state poisoned");
        assert_eq!(state.shutdown_offsets, [state.bytes.len()]);
        let records = captured_records(&state.bytes);
        assert_eq!(records.len(), 1);
        assert_eq!(
            decrypt_record(&test_keys(), false, 1, records[0].0, records[0].1).unwrap(),
            plaintext
        );
    }

    #[tokio::test]
    async fn record_level_helper_preserves_pending_async_write_order() {
        let (writer, state) = AdversarialWriter::new(4);
        let mut stream = test_stream(writer);
        let first = b"async-write record";
        let second = b"record-level helper";

        assert_eq!(stream.write(first).await.unwrap(), first.len());
        stream.write_app_data(second).await.unwrap();

        let bytes = state
            .lock()
            .expect("adversarial writer state poisoned")
            .bytes
            .clone();
        let records = captured_records(&bytes);
        assert_eq!(records.len(), 2);
        assert_eq!(
            decrypt_record(&test_keys(), false, 1, records[0].0, records[0].1).unwrap(),
            first
        );
        assert_eq!(
            decrypt_record(&test_keys(), false, 2, records[1].0, records[1].1).unwrap(),
            second
        );
    }

    #[test]
    fn server_finished_mismatch_fails_closed() {
        let expected = [0x44; 12];
        let mut actual = make_handshake(HS_FINISHED, &expected);
        actual[15] ^= 1;

        let error = verify_server_finished(&actual, &expected).unwrap_err();

        assert!(matches!(
            error,
            RemotePairingError::TlsPskServerFinishedVerificationFailed
        ));
    }

    #[test]
    fn malformed_server_finished_fails_closed() {
        let expected = [0x44; 12];

        for actual in [
            vec![],
            vec![HS_FINISHED, 0, 0, 11],
            make_handshake(HS_SERVER_HELLO_DONE, &expected),
        ] {
            assert!(matches!(
                verify_server_finished(&actual, &expected),
                Err(RemotePairingError::TlsPskServerFinishedVerificationFailed)
            ));
        }
    }

    #[test]
    fn tls_cbc_padding_validates_every_byte_and_full_length() {
        assert!(strip_tls_cbc_padding(&[0]).unwrap().is_empty());
        assert_eq!(strip_tls_cbc_padding(&[0xAA, 0]).unwrap(), &[0xAA]);

        let sixteen = vec![15; 16];
        assert!(strip_tls_cbc_padding(&sixteen).unwrap().is_empty());

        let two_hundred_fifty_six = vec![255; 256];
        assert!(
            strip_tls_cbc_padding(&two_hundred_fifty_six)
                .unwrap()
                .is_empty()
        );

        assert!(strip_tls_cbc_padding(&[]).is_err());
        assert!(strip_tls_cbc_padding(&[255]).is_err());
        assert!(strip_tls_cbc_padding(&[1, 0, 1]).is_err());
    }

    #[test]
    fn tls_cbc_padding_parser_never_panics_on_hostile_lengths() {
        for length in 0..=512 {
            for padding_value in 0..=u8::MAX {
                let mut bytes = vec![0_u8; length];
                if let Some(last) = bytes.last_mut() {
                    *last = padding_value;
                }
                assert!(
                    std::panic::catch_unwind(|| strip_tls_cbc_padding(&bytes)).is_ok(),
                    "length={length} padding={padding_value}"
                );
            }
        }
    }

    #[test]
    fn malformed_ciphertext_is_typed_for_both_cipher_suites() {
        for suite in [CipherSuite::Aes128CbcSha, CipherSuite::Aes256CbcSha384] {
            let keys = KeyBlock {
                client_mac_key: Zeroizing::new(vec![0; suite.mac_key_len()]),
                server_mac_key: Zeroizing::new(vec![0; suite.mac_key_len()]),
                client_write_key: Zeroizing::new(vec![0; suite.enc_key_len()]),
                server_write_key: Zeroizing::new(vec![0; suite.enc_key_len()]),
                suite,
            };

            let error = decrypt_record(&keys, true, 0, CT_HANDSHAKE, &[0; 17]).unwrap_err();

            assert!(matches!(
                error,
                IdeviceError::RemotePairing(RemotePairingError::TlsPskRecordIntegrityFailed)
            ));
        }
    }
}
