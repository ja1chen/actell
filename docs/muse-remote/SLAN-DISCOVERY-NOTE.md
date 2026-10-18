# Bonjour TLS identity discovery clarification

Status: approved by the user and implemented on both sides. The earlier deferred
proposal is superseded by the shared SLAN/1 host clarification.

Actell advertises its existing stable certificate DNS SAN as TXT `host`, equal to
claim.host; no certificate rotation is involved. Muse connects to Bonjour's SRV
address/port, with host as its certificate name and SNI. The stable host does not
need to resolve. The selected host and handshake DER pin are retained through
claim and persisted after verification; later broadcasts cannot replace them.
Missing/invalid/duplicate host in a new-pairing advertisement is incompatible,
never a reason to skip hostname checking. DHCP and SRV name changes preserve the
saved identity. See [the synchronized contract](SLAN-1.md).

Validation uses actual Muse discovery code with synthetic mDNS/Wi-Fi, plus native
TLS and application tests; it is not physical iPhone/Muse acceptance.
