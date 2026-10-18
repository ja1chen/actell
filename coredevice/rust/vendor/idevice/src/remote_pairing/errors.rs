// Jackson Coxson

/// Errors specific to remote pairing operations
#[derive(thiserror::Error, Debug)]
#[non_exhaustive]
pub enum RemotePairingError {
    #[error("Unknown TLV: {0}")]
    UnknownTlv(u8),
    #[error("Malformed TLV")]
    MalformedTlv,
    #[error("Pairing rejected: {0}")]
    PairingRejected(String),
    #[cfg(feature = "remote_pairing")]
    #[error("Base64 decode error")]
    Base64DecodeError(#[from] base64::DecodeError),
    #[error("Pair verify failed")]
    PairVerifyFailed,
    #[error("Pair verify completion failed")]
    PairVerifyCompletionFailed,
    #[error("Pair verify M2 payload is malformed")]
    PairVerifyM2Malformed,
    #[error("Pair verify M2 decryption failed")]
    PairVerifyM2DecryptionFailed,
    #[error("Pair verify M2 identifier does not match the stored peer")]
    PairVerifyM2IdentifierMismatch,
    #[error("Pair verify M2 signature authentication failed")]
    PairVerifyM2SignatureFailed,
    #[error("Peer pairing identity is malformed: {0}")]
    PeerIdentityMalformed(&'static str),
    #[error("Peer pairing identity authentication failed")]
    PeerAuthenticationFailed,
    #[error("Pairing record persistence failed")]
    PairRecordPersistenceFailed,
    #[error("TLS-PSK server Finished verification failed")]
    TlsPskServerFinishedVerificationFailed,
    #[error("TLS-PSK record integrity verification failed")]
    TlsPskRecordIntegrityFailed,
    #[error("SRP auth failed")]
    SrpAuthFailed,
    #[cfg(feature = "remote_pairing")]
    #[error("Chacha encryption error")]
    ChachaEncryption(chacha20poly1305::Error),
}

impl RemotePairingError {
    pub fn sub_code(&self) -> i32 {
        match self {
            Self::UnknownTlv(_) => 1,
            Self::MalformedTlv => 2,
            Self::PairingRejected(_) => 3,
            #[cfg(feature = "remote_pairing")]
            Self::Base64DecodeError(_) => 4,
            Self::PairVerifyFailed => 5,
            Self::SrpAuthFailed => 6,
            #[cfg(feature = "remote_pairing")]
            Self::ChachaEncryption(_) => 7,
            Self::PeerIdentityMalformed(_) => 8,
            Self::PeerAuthenticationFailed => 9,
            Self::PairRecordPersistenceFailed => 10,
            Self::TlsPskServerFinishedVerificationFailed => 11,
            Self::TlsPskRecordIntegrityFailed => 12,
            Self::PairVerifyCompletionFailed => 13,
            Self::PairVerifyM2Malformed => 14,
            Self::PairVerifyM2DecryptionFailed => 15,
            Self::PairVerifyM2IdentifierMismatch => 16,
            Self::PairVerifyM2SignatureFailed => 17,
        }
    }
}
