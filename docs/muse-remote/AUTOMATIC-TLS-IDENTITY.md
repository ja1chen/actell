# Automatic local TLS identity

The normal Muse setup path can generate its own persistent TLS server identity on iOS. A user-imported PKCS#12 file is not required. This implementation uses public Apple APIs and Apple's Swift Certificates package; it does not implement ASN.1 encoding, cryptographic signing algorithms, or a trust-all transport.

## Implementation and dependency

`RemoteGeneratedIdentityProvider` has serialized `@MainActor` operations:

- `provision(host:) -> Material`: reuse a valid existing identity or provision once.
- `load(host:) -> Material?`: nil only when no certificate exists; fail closed for corrupt, mismatched, expired, or inaccessible material.
- `remove()`: explicit deletion scoped to this provider's certificate label and private-key tag. Call only after invalidating its pairings.
- `Material`: `identity`, `certificateDER`, lowercase SHA-256 `fingerprint`, `expiresAt`.

Add product `X509` from `https://github.com/apple/swift-certificates.git`, exact version `1.10.0`, to the app target. Hosted unit tests import its module and resolve its symbols through the app BUNDLE_LOADER. On Xcode 27, explicitly linking X509 into both targets promotes its transitive Crypto product to a framework whose binary is not produced, causing a link failure; the project generator avoids that duplicate product link. The inspected tag points to `999fd70c7803da89f3904d635a6815a2a7cd7585`. Its manifest requires Swift 5.9 and depends on Swift Crypto >=3.12.3 and Swift ASN.1 >=1.1.0 within their major versions. These transitive versions still need resolution in the app's lockfile/build environment.

The provider generates a persistent P-256 `SecKey`, wraps it using `try Certificate.PrivateKey(key)`, and signs through the package's Security-framework adapter. It never exports the private key. `SecCertificate.makeWithCertificate` supplies the platform certificate. Saving the certificate beside the key allows a `kSecClassIdentity` lookup. The system fills the cryptographic association attributes; application code does not overwrite them.

The certificate contains a random positive 20-byte serial number, ECDSA/SHA-256 signature, DNS or numeric IP SAN matching the configured host, digital-signature usage and TLS server authentication usage. It is a self-signed leaf, not a certificate authority. Validity starts five minutes before issuance and ends one year afterward. Production setup should generate and persist a stable host before provisioning, then use that host consistently for client TLS name verification. No LAN DNS resolution is implied by generating a name.

The returned identity works with `sec_identity_create`, `sec_protocol_options_set_local_identity`, and `NWProtocolTLS.Options`. A self-signed certificate is not globally trusted: the paired client must obtain the exact certificate/pin through the authenticated pairing channel and enforce both that trust and the expected TLS server name. Never learn a trusted pin from untrusted Bonjour metadata alone.

## Failure and persistence rules

- Key generation failure does not save a certificate.
- If certificate construction or storage fails after key creation, the next attempt reuses that saved key.
- If a certificate exists but its private key or synthesized identity is missing, provisioning fails. It does not replace the certificate or silently change a previously shared pin.
- An expired certificate or host mismatch requires explicit reset and re-pairing.
- If certificate storage succeeded but a later lookup failed, the stored certificate is retained and retried; it is not regenerated.
- App Keychain access is device-only and requires the device to be unlocked. Keychain state may outlive app uninstall; if installation-specific lifetime is required, supply an installation UUID namespace and define explicit cleanup/re-pairing UX.

The provider's local SSL policy check anchors only this stored certificate, checks validity and host, and disables network certificate fetches. This does not change system trust or bypass the remote client's verification.

## Evidence

- [Apple DTS: mTLS identity workflow](https://developer.apple.com/forums/thread/797509): explicitly supports generation, certificate insertion and identity lookup with Security APIs, for EC and RSA keys.
- [Apple DTS: SecItem pitfalls](https://developer.apple.com/forums/thread/724013): identities are composed from matching key/certificate attributes. Certificate queries cannot use the key-only application tag.
- [Apple: local-network TLS identity](https://developer.apple.com/documentation/network/creating-an-identity-for-local-network-tls): demonstrates iOS identity retrieval and Network.framework listener configuration.
- [Swift Certificates 1.10.0 private-key wrapper](https://github.com/apple/swift-certificates/blob/1.10.0/Sources/X509/CertificatePrivateKey.swift): public SecKey initializer, available on iOS 13+.
- [Swift Certificates 1.10.0 certificate bridge](https://github.com/apple/swift-certificates/blob/1.10.0/Sources/X509/Certificate.swift): public `SecCertificate.makeWithCertificate`, available on iOS 13+.
- [Swift Certificates SecKey adapter](https://github.com/apple/swift-certificates/blob/1.10.0/Sources/X509/SecKeyWrapper.swift): exports the public key only and signs with Security APIs.

## Validation status and required acceptance

Source APIs were checked against the downloaded, fixed upstream tag. `git diff --check` passed. This cloud environment does not contain Swift, Xcode, the iOS SDK, or an iOS runtime, so the new Swift source and tests have **not** been compiled or executed here.

`RemoteGeneratedIdentityProviderTests` covers identity persistence/reload, certificate self-signature, SecKey signing, `sec_identity_create`, per-namespace uniqueness, host mismatch without rotation, IP SAN matching, invalid host rejection, and missing-private-key failure without certificate replacement. Each test uses a random test namespace; cleanup only targets that namespace's exact certificate label and private-key tag.

Before release:

1. Resolve the exact package, run app and test builds on the required Xcode/iOS SDK, and execute these tests in a signed test host.
2. Run actual NWListener + paired Muse TLS handshakes with correct certificate/name, then wrong pin, wrong name, expired certificate, and unpaired client negative cases.
3. Verify app relaunch and device unlock behavior preserve the fingerprint; simulate a failed certificate write and interrupted provisioning.
4. Verify explicit reset revokes old pairings before removing identity; verify reinstall behavior against the intended installation lifetime.
5. Confirm the Muse TLS stack accepts an explicitly trusted self-signed EC leaf with this SAN/EKU and continues enforcing hostname and certificate validity. Do not substitute a verification bypass if it fails.
