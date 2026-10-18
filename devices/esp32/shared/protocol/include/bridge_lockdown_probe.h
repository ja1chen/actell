/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_LOCKDOWN_PROBE_H
#define BRIDGE_LOCKDOWN_PROBE_H
#include "bridge_core.h"

#define BRIDGE_LOCKDOWN_PORT 62078u
#define BRIDGE_LOCKDOWN_PROBE_MAX_REPLY_BYTES 4096u
#define BRIDGE_LOCKDOWN_PROBE_LABEL "esp32-iphone-bridge"
#define BRIDGE_LOCKDOWN_SERVICE_TYPE "com.apple.mobile.lockdown"

typedef enum {
    BRIDGE_LOCKDOWN_ENCODING_UNKNOWN = 0,
    BRIDGE_LOCKDOWN_ENCODING_XML,
    BRIDGE_LOCKDOWN_ENCODING_BINARY
} bridge_lockdown_encoding;

typedef struct {
    bridge_lockdown_encoding encoding;
    uint32_t reply_bytes;       /* plist payload only, excludes four-byte prefix */
    bool request_echoed;       /* Request is optional; if present it matched */
    bool lockdown_type_verified;
} bridge_lockdown_probe_result;

/* Strict, bounded QueryType reply schema, not a general XML parser. Accepts
 * Type plus optional Request and legacy Result=Success, all strings. Rejects
 * Error, unknown/duplicate keys, nested values, extra documents, unsupported
 * declarations/entities/types and malformed input. XML DTDs are never fetched.
 * Binary plists use bridge_bplist with additional schema/envelope validation.
 * out is zero on every failure; no response text or device identifiers escape.
 * BRIDGE_E_TYPE means wrong value/type or an Error/failed Result reply;
 * BRIDGE_E_NOT_FOUND means missing Type; other parsing failures use FORMAT,
 * UNSUPPORTED or LIMIT. data must remain immutable during this call and must
 * not overlap out. On success this proves only the expected service reply,
 * never authentication, pairing, trust, TLS or CoreDevice readiness.
 */
bridge_status bridge_lockdown_probe_parse_reply(const uint8_t *data, size_t size,
    bridge_lockdown_probe_result *out);

/* Send exactly one XML QueryType + fixed, non-identifying Label over an already
 * established USBmux byte stream to BRIDGE_LOCKDOWN_PORT. Uses existing plist
 * big-endian length framing and one absolute deadline across send/receive.
 * No Pair, StartSession, credential generation/storage, TLS or device metadata
 * queries. No allocation. Caller owns reply storage (1..4096 bytes), which may
 * contain untrusted peer bytes after return: do not log it. io/out/reply_buffer
 * must not overlap. Result remains zero unless the whole operation succeeds.
 * All failures are terminal for this stream: caller closes it, never retries
 * or resynchronizes on the same stream. The caller owns stream lifecycle.
 */
bridge_status bridge_lockdown_probe_query_type(bridge_io *io,
    uint8_t *reply_buffer, size_t reply_capacity, uint64_t deadline_ms,
    bridge_lockdown_probe_result *out);
#endif
