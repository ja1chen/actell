//! Ticket Signature Server (TSS) Client
//!
//! Provides functionality for interacting with Apple's TSS service to:
//! - Request personalized firmware components
//! - Apply restore request rules for device-specific parameters
//! - Handle cryptographic signing operations

use plist::Value;
use plist_macro::plist_to_xml_bytes;
use tracing::{debug, warn};

use crate::IdeviceError;

/// TSS client version string sent in requests
const TSS_CLIENT_VERSION_STRING: &str = "libauthinstall-1033.0.2";
/// Apple's TSS endpoint URL
const TSS_CONTROLLER_ACTION_URL: &str = "https://gs.apple.com/TSS/controller?action=2";
const TSS_SUCCESS_PREFIX: &str = "STATUS=0&MESSAGE=SUCCESS&REQUEST_STRING=";

/// Validates the TSS response envelope before parsing its plist payload.
fn parse_tss_response(response: &[u8]) -> Result<plist::Value, IdeviceError> {
    let response = std::str::from_utf8(response)
        .map_err(|_| IdeviceError::UnexpectedResponse("TSS response is not valid UTF-8".into()))?;
    let payload = response.strip_prefix(TSS_SUCCESS_PREFIX).ok_or_else(|| {
        IdeviceError::UnexpectedResponse("TSS response has an invalid success envelope".into())
    })?;
    if payload.is_empty() {
        return Err(IdeviceError::UnexpectedResponse(
            "TSS response has an empty plist payload".into(),
        ));
    }

    let value = plist::from_bytes(payload.as_bytes()).map_err(|_| {
        IdeviceError::UnexpectedResponse("TSS response contains a malformed plist".into())
    })?;
    if !matches!(value, plist::Value::Dictionary(_)) {
        return Err(IdeviceError::UnexpectedResponse(
            "TSS response plist is not a dictionary".into(),
        ));
    }
    Ok(value)
}

/// Rejects unsuccessful HTTP responses before interpreting their bodies.
fn parse_tss_http_response(status: u16, response: &[u8]) -> Result<plist::Value, IdeviceError> {
    if !(200..300).contains(&status) {
        return Err(IdeviceError::Http(format!(
            "TSS request failed with HTTP status {status}"
        )));
    }
    parse_tss_response(response)
}

/// Represents a TSS request to Apple's signing server
pub struct TSSRequest {
    /// The underlying plist dictionary containing request parameters
    inner: plist::Dictionary,
}

impl std::fmt::Debug for TSSRequest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("TSSRequest { inner: <redacted> }")
    }
}

impl TSSRequest {
    /// Creates a new TSS request with default headers
    ///
    /// Initializes with:
    /// - Host platform info
    /// - Client version string
    /// - Random UUID for request identification
    pub fn new() -> Self {
        let inner = plist_macro::plist!(dict {
            "@HostPlatformInfo": "mac",
            "@VersionInfo": TSS_CLIENT_VERSION_STRING,
            "@UUID": uuid::Uuid::new_v4().to_string().to_uppercase()
        });
        Self { inner }
    }

    /// Inserts a key-value pair into the TSS request
    ///
    /// # Arguments
    /// * `key` - The parameter name
    /// * `val` - The parameter value (will be converted to plist::Value)
    pub fn insert(&mut self, key: impl Into<String>, val: impl Into<Value>) {
        let key = key.into();
        let val = val.into();
        self.inner.insert(key, val);
    }

    /// Sends the TSS request to Apple's servers
    ///
    /// # Returns
    /// The parsed plist response from Apple
    ///
    /// # Errors
    /// Returns `IdeviceError` if:
    /// - The request fails
    /// - The response is malformed
    /// - Apple returns a non-success status
    ///
    /// # Example
    /// ```rust
    /// let mut request = TSSRequest::new();
    /// request.insert("ApBoardID", board_id);
    /// request.insert("ApChipID", chip_id);
    /// let response = request.send().await?;
    /// ```
    pub async fn send(&self) -> Result<plist::Value, IdeviceError> {
        let response = crate::http::HttpRequest::post(TSS_CONTROLLER_ACTION_URL)
            .https_only()
            .header("Cache-Control", "no-cache")
            .header("Content-type", "text/xml; charset=\"utf-8\"")
            .header("User-Agent", "InetURL/1.0")
            .body(plist_to_xml_bytes(&self.inner))
            .send()
            .await?;

        parse_tss_http_response(response.status, &response.body)
    }

    /// Sets the `@ApImg4Ticket` request flag.
    ///
    /// When true, the server returns a signed IMG4 manifest (`ApImg4Ticket`).
    pub fn set_ap_img4_ticket(&mut self, value: bool) {
        self.insert("@ApImg4Ticket", value);
    }

    /// Sets the `@BBTicket` request flag (request a baseband ticket).
    pub fn set_bb_ticket(&mut self, value: bool) {
        self.insert("@BBTicket", value);
    }

    /// Adds the common `Ap*` identity tags shared by the developer-disk-image
    /// personalization flow and the full IPSW restore flow.
    ///
    /// Sets `ApBoardID`, `ApChipID`, `ApECID`, `ApProductionMode` (true),
    /// `ApSecurityDomain` (1), `ApSecurityMode` (true) and `UID_MODE` (false).
    /// `ap_nonce`/`sep_nonce`, when supplied, are inserted as `ApNonce`/`SepNonce`
    /// data blobs.
    pub fn add_common_tags(
        &mut self,
        board_id: u64,
        chip_id: u64,
        ecid: u64,
        ap_nonce: Option<Vec<u8>>,
        sep_nonce: Option<Vec<u8>>,
    ) {
        self.insert("ApBoardID", board_id);
        self.insert("ApChipID", chip_id);
        self.insert("ApECID", ecid);
        self.insert("ApProductionMode", true);
        self.insert("ApSecurityDomain", 1);
        self.insert("ApSecurityMode", true);
        self.insert("UID_MODE", false);
        if let Some(n) = ap_nonce {
            self.insert("ApNonce", plist::Value::Data(n));
        }
        if let Some(n) = sep_nonce {
            self.insert("SepNonce", plist::Value::Data(n));
        }
    }

    /// Removes a key from the request, returning the removed value if present.
    pub fn remove(&mut self, key: &str) -> Option<Value> {
        self.inner.remove(key)
    }

    pub fn add_build_identity_tags(&mut self, build_identity: &plist::Dictionary, keys: &[&str]) {
        for &key in keys {
            if let Some(v) = build_identity.get(key) {
                let converted = match v {
                    Value::String(s) if s.starts_with("0x") => {
                        match u64::from_str_radix(s.trim_start_matches("0x"), 16) {
                            Ok(n) => Value::from(n),
                            Err(_) => v.clone(),
                        }
                    }
                    _ => v.clone(),
                };
                self.insert(key, converted);
            }
        }
    }

    pub fn add_ap_personalization_identifiers(&mut self, identifiers: &plist::Dictionary) {
        for (key, val) in identifiers {
            if key.starts_with("Ap,") {
                self.insert(key.clone(), val.clone());
            }
        }
    }

    pub fn add_ap_tags(&mut self, build_identity: &plist::Dictionary) {
        const KEYS: &[&str] = &[
            "UniqueBuildID",
            "Ap,OSLongVersion",
            "Ap,OSReleaseType",
            "Ap,ProductType",
            "Ap,SDKPlatform",
            "Ap,SikaFuse",
            "Ap,Target",
            "Ap,TargetType",
            "Ap,ProductMarketingVersion",
            "ApBoardID",
            "ApChipID",
            "ApSecurityDomain",
            "BMU,BoardID",
            "BMU,ChipID",
            "BbChipID",
            "BbProvisioningManifestKeyHash",
            "BbActivationManifestKeyHash",
            "BbCalibrationManifestKeyHash",
            "BbFactoryActivationManifestKeyHash",
            "BbFDRSecurityKeyHash",
            "BbSkeyId",
            "SE,ChipID",
            "Savage,ChipID",
            "Savage,PatchEpoch",
            "Yonkers,BoardID",
            "Yonkers,ChipID",
            "Yonkers,PatchEpoch",
            "Rap,BoardID",
            "Rap,ChipID",
            "Rap,SecurityDomain",
            "Baobab,BoardID",
            "Baobab,ChipID",
            "Baobab,ManifestEpoch",
            "Baobab,SecurityDomain",
            "eUICC,ChipID",
            "PearlCertificationRootPub",
            "Timer,BoardID,1",
            "Timer,BoardID,2",
            "Timer,ChipID,1",
            "Timer,ChipID,2",
            "Timer,SecurityDomain,1",
            "Timer,SecurityDomain,2",
            "NeRDEpoch",
        ];
        for &key in KEYS {
            if let Some(v) = build_identity.get(key) {
                let converted = match v {
                    Value::String(s) if s.starts_with("0x") => {
                        match u64::from_str_radix(s.trim_start_matches("0x"), 16) {
                            Ok(n) => Value::from(n),
                            Err(_) => v.clone(),
                        }
                    }
                    _ => v.clone(),
                };
                self.insert(key, converted);
            }
        }

        if let Some(r) = build_identity
            .get("Info")
            .and_then(|i| i.as_dictionary())
            .and_then(|i| i.get("RequiresUIDMode"))
        {
            self.insert("RequiresUIDMode", r.clone());
        }
    }

    pub fn add_ap_manifest_tags(
        &mut self,
        build_identity: &plist::Dictionary,
        parameters: &plist::Dictionary,
    ) -> Result<(), IdeviceError> {
        const SKIP_KEYS: &[&str] = &[
            "BasebandFirmware",
            "SE,UpdatePayload",
            "BaseSystem",
            "Diags",
            "Ap,ExclaveOS",
        ];

        let manifest = match build_identity.get("Manifest") {
            Some(plist::Value::Dictionary(m)) => m,
            _ => return Err(IdeviceError::BadBuildManifest),
        };
        let supports_img4 = parameters
            .get("ApSupportsImg4")
            .and_then(Value::as_boolean)
            .unwrap_or(false);

        for (key, manifest_item) in manifest {
            if SKIP_KEYS.contains(&key.as_str()) || key.starts_with("Cryptex1,") {
                continue;
            }
            let manifest_item = match manifest_item {
                plist::Value::Dictionary(m) => m,
                _ => continue,
            };
            let info = match manifest_item.get("Info") {
                Some(plist::Value::Dictionary(i)) => i,
                _ => continue,
            };
            // For IMG4 devices, only components with RestoreRequestRules belong
            // in the AP ticket.
            let has_rules = info.contains_key("RestoreRequestRules");
            if supports_img4 && !has_rules {
                debug!("skipping {key}: no RestoreRequestRules");
                continue;
            }
            if info
                .get("IsFTAB")
                .and_then(Value::as_boolean)
                .unwrap_or(false)
            {
                continue;
            }

            let mut tss_entry = manifest_item.clone();
            tss_entry.remove("Info");

            if let Some(plist::Value::Array(rules)) = info.get("RestoreRequestRules") {
                apply_restore_request_rules(&mut tss_entry, parameters, rules);
            }

            let trusted = manifest_item
                .get("Trusted")
                .and_then(Value::as_boolean)
                .unwrap_or(false);
            if trusted && !tss_entry.contains_key("Digest") {
                tss_entry.insert("Digest".into(), plist::Value::Data(Vec::new()));
            }

            self.insert(key.clone(), tss_entry);
        }

        Ok(())
    }

    pub fn add_baseband_tags(&mut self, parameters: &plist::Dictionary) {
        self.insert("@BBTicket", true);

        const KEYS: &[&str] = &[
            "BbChipID",
            "BbProvisioningManifestKeyHash",
            "BbActivationManifestKeyHash",
            "BbCalibrationManifestKeyHash",
            "BbFactoryActivationManifestKeyHash",
            "BbFDRSecurityKeyHash",
            "BbSkeyId",
            "BbNonce",
            "BbGoldCertId",
            "BbSNUM",
            "PearlCertificationRootPub",
            "Ap,OSLongVersion",
        ];
        for &key in KEYS {
            if let Some(v) = parameters.get(key) {
                self.insert(key, v.clone());
            }
        }

        if let Some(bbfw) = parameters
            .get("Manifest")
            .and_then(|m| m.as_dictionary())
            .and_then(|m| m.get("BasebandFirmware"))
            .and_then(|b| b.as_dictionary())
        {
            let mut bbfwdict = bbfw.clone();
            bbfwdict.remove("Info");

            let bb_chip_id = parameters
                .get("BbChipID")
                .and_then(Value::as_unsigned_integer);
            let bb_cert_id = parameters
                .get("BbGoldCertId")
                .and_then(Value::as_unsigned_integer);
            if bb_chip_id == Some(0x68) {
                if matches!(bb_cert_id, Some(0x26F3_FACC | 0x5CF2_EC4E | 0x8399_785A)) {
                    bbfwdict.remove("PSI2-PartialDigest");
                    bbfwdict.remove("RestorePSI2-PartialDigest");
                } else {
                    bbfwdict.remove("PSI-PartialDigest");
                    bbfwdict.remove("RestorePSI-PartialDigest");
                }
            }
            self.insert("BasebandFirmware", Value::Dictionary(bbfwdict));
        }
    }

    pub fn populate_from_manifest(
        &mut self,
        build_identity: &plist::Dictionary,
        parameters: &plist::Dictionary,
        rules_override: Option<&[plist::Value]>,
    ) -> Result<(), IdeviceError> {
        let manifest = match build_identity.get("Manifest") {
            Some(plist::Value::Dictionary(m)) => m,
            _ => return Err(IdeviceError::BadBuildManifest),
        };

        for (key, manifest_item) in manifest {
            let manifest_item = match manifest_item {
                plist::Value::Dictionary(m) => m,
                _ => {
                    debug!("Manifest item {key} wasn't a dictionary");
                    continue;
                }
            };

            let info = match manifest_item.get("Info") {
                Some(plist::Value::Dictionary(i)) => i,
                _ => {
                    debug!("Manifest item {key} didn't contain Info");
                    continue;
                }
            };

            if !matches!(
                manifest_item.get("Trusted"),
                Some(plist::Value::Boolean(true))
            ) {
                debug!("Manifest item {key} isn't trusted");
                continue;
            }

            let mut tss_entry = manifest_item.clone();
            tss_entry.remove("Info");

            let rules = match rules_override {
                Some(r) => Some(r),
                None => info
                    .get("RestoreRequestRules")
                    .and_then(|v| v.as_array())
                    .map(|v| v.as_slice()),
            };
            if let Some(rules) = rules {
                apply_restore_request_rules(&mut tss_entry, parameters, rules);
            }

            if manifest_item.get("Digest").is_none() {
                tss_entry.insert("Digest".into(), plist::Value::Data(Vec::new()));
            }

            self.insert(key.clone(), tss_entry);
        }

        Ok(())
    }
}

impl Default for TSSRequest {
    /// Creates a default TSS request (same as `new()`)
    fn default() -> Self {
        Self::new()
    }
}

/// Applies restore request rules to modify input parameters
///
/// # Arguments
/// * `input` - The dictionary to modify based on rules
/// * `parameters` - Device parameters to check conditions against
/// * `rules` - List of rules to apply
///
/// # Process
/// For each rule:
/// 1. Checks all conditions against the parameters
/// 2. If all conditions are met, applies the rule's actions
/// 3. Actions can add, modify or remove parameters
pub fn apply_restore_request_rules(
    input: &mut plist::Dictionary,
    parameters: &plist::Dictionary,
    rules: &[plist::Value],
) {
    for rule in rules {
        if let plist::Value::Dictionary(rule) = rule {
            let conditions = match rule.get("Conditions") {
                Some(plist::Value::Dictionary(c)) => c,
                _ => {
                    warn!("Conditions doesn't exist or wasn't a dictionary!");
                    continue;
                }
            };

            let mut conditions_fulfilled = true;
            for (key, value) in conditions {
                let value2 = match key.as_str() {
                    "ApRawProductionMode" => parameters.get("ApProductionMode"),
                    "ApCurrentProductionMode" => parameters.get("ApProductionMode"),
                    "ApRawSecurityMode" => parameters.get("ApSecurityMode"),
                    "ApRequiresImage4" => parameters.get("ApSupportsImg4"),
                    "ApDemotionPolicyOverride" => parameters.get("DemotionPolicy"),
                    "ApInRomDFU" => parameters.get("ApInRomDFU"),
                    _ => {
                        warn!("Unhandled key {key}");
                        None
                    }
                };

                if value2.is_none() || value2 != Some(value) {
                    conditions_fulfilled = false;
                    break; // Stop checking other conditions immediately
                }
            }

            if !conditions_fulfilled {
                continue;
            }

            let actions = match rule.get("Actions") {
                Some(plist::Value::Dictionary(a)) => a,
                _ => {
                    warn!("Actions doesn't exist or wasn't a dictionary!");
                    continue;
                }
            };

            for (key, value) in actions {
                // Skip special values (255 typically means "ignore")
                if let Some(i) = value.as_unsigned_integer()
                    && i == 255
                {
                    continue;
                }
                if let Some(i) = value.as_signed_integer()
                    && i == 255
                {
                    continue;
                }

                input.remove(key); // Explicitly remove before inserting
                input.insert(key.to_owned(), value.to_owned());
            }
        } else {
            warn!("Rule wasn't a dictionary");
        }
    }
}

fn parse_hex_field(v: Option<&plist::Value>) -> Option<u64> {
    match v {
        Some(plist::Value::String(s)) => u64::from_str_radix(s.trim_start_matches("0x"), 16).ok(),
        Some(plist::Value::Integer(i)) => i.as_unsigned(),
        _ => None,
    }
}

pub fn select_build_identity<'a>(
    build_manifest: &'a plist::Dictionary,
    board_id: u64,
    chip_id: u64,
    restore_behavior: Option<&str>,
) -> Result<&'a plist::Dictionary, IdeviceError> {
    let identities = match build_manifest.get("BuildIdentities") {
        Some(plist::Value::Array(i)) => i,
        _ => return Err(IdeviceError::BadBuildManifest),
    };

    for id in identities {
        let id = match id {
            plist::Value::Dictionary(id) => id,
            _ => {
                debug!("build identity wasn't a dictionary");
                continue;
            }
        };

        if parse_hex_field(id.get("ApBoardID")) != Some(board_id) {
            continue;
        }
        if parse_hex_field(id.get("ApChipID")) != Some(chip_id) {
            continue;
        }
        if let Some(behavior) = restore_behavior {
            let matches = id
                .get("Info")
                .and_then(|i| i.as_dictionary())
                .and_then(|i| i.get("RestoreBehavior"))
                .and_then(|b| b.as_string())
                == Some(behavior);
            if !matches {
                continue;
            }
        }
        return Ok(id);
    }

    Err(IdeviceError::BadBuildManifest)
}

/// Extracts the `ApImg4Ticket` blob from a TSS response dictionary.
///
/// # Errors
/// Returns [`IdeviceError::UnexpectedResponse`] if the ticket is absent.
pub fn extract_img4_ticket(response: &plist::Dictionary) -> Result<Vec<u8>, IdeviceError> {
    match response.get("ApImg4Ticket") {
        Some(plist::Value::Data(d)) => Ok(d.clone()),
        _ => Err(IdeviceError::UnexpectedResponse(
            "missing ApImg4Ticket data in TSS response".into(),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        TSS_CONTROLLER_ACTION_URL, TSSRequest, parse_tss_http_response, parse_tss_response,
    };
    use crate::IdeviceError;

    #[test]
    fn tss_endpoint_requires_https() {
        assert_eq!(
            TSS_CONTROLLER_ACTION_URL,
            "https://gs.apple.com/TSS/controller?action=2"
        );
    }

    #[test]
    fn parses_a_complete_success_envelope() {
        let payload = plist_macro::plist_to_xml_bytes(&plist_macro::plist!(dict {
            "ApImg4Ticket": vec![1_u8, 2, 3]
        }));
        let mut response = b"STATUS=0&MESSAGE=SUCCESS&REQUEST_STRING=".to_vec();
        response.extend_from_slice(&payload);

        let parsed = parse_tss_response(&response).unwrap();

        assert_eq!(
            parsed
                .as_dictionary()
                .and_then(|dictionary| dictionary.get("ApImg4Ticket"))
                .and_then(plist::Value::as_data),
            Some([1_u8, 2, 3].as_slice())
        );
    }

    #[test]
    fn rejects_http_failure_without_echoing_the_sensitive_body() {
        let secret = "ECID=123&NONCE=private&TICKET=signed";

        let error = parse_tss_http_response(503, secret.as_bytes()).unwrap_err();

        assert!(
            matches!(error, IdeviceError::Http(ref message) if message == "TSS request failed with HTTP status 503")
        );
        assert!(!error.to_string().contains(secret));
    }

    #[test]
    fn debug_output_redacts_request_identifiers_and_nonces() {
        let secret = "device-ecid-and-nonce";
        let mut request = TSSRequest::new();
        request.insert("ApECID", secret);
        request.insert("ApNonce", plist::Value::Data(secret.as_bytes().to_vec()));

        let debug_output = format!("{request:?}");

        assert_eq!(debug_output, "TSSRequest { inner: <redacted> }");
        assert!(!debug_output.contains(secret));
    }

    #[test]
    fn malformed_responses_fail_closed_without_echoing_contents() {
        let secret = "ECID-AND-NONCE-MUST-STAY-PRIVATE";
        let cases: Vec<Vec<u8>> = vec![
            Vec::new(),
            vec![0xff],
            format!("STATUS=94&MESSAGE={secret}").into_bytes(),
            b"STATUS=0&MESSAGE=SUCCESS&REQUEST_STRING=".to_vec(),
            format!("STATUS=0&MESSAGE=SUCCESS&REQUEST_STRING=<not-a-plist>{secret}</not-a-plist>")
                .into_bytes(),
        ];

        for response in cases {
            let error = parse_tss_http_response(200, &response).unwrap_err();
            assert!(matches!(error, IdeviceError::UnexpectedResponse(_)));
            assert!(!error.to_string().contains(secret));
        }
    }

    #[test]
    fn non_dictionary_plists_and_trailing_data_are_rejected() {
        let array = plist::Value::Array(vec![plist::Value::String("ticket".into())]);
        let mut array_payload = Vec::new();
        array.to_writer_xml(&mut array_payload).unwrap();
        let mut array_response = b"STATUS=0&MESSAGE=SUCCESS&REQUEST_STRING=".to_vec();
        array_response.extend_from_slice(&array_payload);
        assert!(matches!(
            parse_tss_response(&array_response),
            Err(IdeviceError::UnexpectedResponse(ref message))
                if message == "TSS response plist is not a dictionary"
        ));

        let payload = plist_macro::plist_to_xml_bytes(&plist_macro::plist!(dict {
            "ApImg4Ticket": vec![1_u8, 2, 3]
        }));
        let mut trailing_response = b"STATUS=0&MESSAGE=SUCCESS&REQUEST_STRING=".to_vec();
        trailing_response.extend_from_slice(&payload);
        trailing_response.extend_from_slice(b"trailing-untrusted-data");
        assert!(parse_tss_response(&trailing_response).is_err());
    }

    #[test]
    fn arbitrary_short_responses_never_panic() {
        for length in 0..=512 {
            for byte in [0_u8, b'&', b'<', 0xff] {
                let response = vec![byte; length];
                let _ = parse_tss_http_response(200, &response);
            }
        }
    }
}
