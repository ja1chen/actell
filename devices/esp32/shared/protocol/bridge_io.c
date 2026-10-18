/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bridge_core.h"
#include <limits.h>

const char *bridge_status_name(bridge_status s) {
    static const char *const names[] = {"ok", "argument", "io", "eof", "timeout",
        "limit", "format", "type", "not_found", "unsupported"};
    return (unsigned)s < sizeof names / sizeof names[0] ? names[s] : "unknown";
}
static bridge_status remaining(bridge_io *io, uint64_t deadline, uint32_t *ms) {
    uint64_t now = io->clock_ms(io->context);
    if (now >= deadline) return BRIDGE_E_TIMEOUT;
    uint64_t delta = deadline - now;
    *ms = delta > UINT32_MAX ? UINT32_MAX : (uint32_t)delta;
    return BRIDGE_OK;
}
static bridge_status callback_error(ptrdiff_t n) {
    if (n == 0) return BRIDGE_E_EOF;
    if (n == -(ptrdiff_t)BRIDGE_E_TIMEOUT) return BRIDGE_E_TIMEOUT;
    return BRIDGE_E_IO;
}
bridge_status bridge_read_exact(bridge_io *io, uint8_t *buf, size_t len, uint64_t deadline) {
    if (!io || !io->read || !io->clock_ms || (!buf && len)) return BRIDGE_E_ARGUMENT;
    while (len) {
        uint32_t ms;
        bridge_status s = remaining(io, deadline, &ms);
        if (s != BRIDGE_OK) return s;
        ptrdiff_t n = io->read(io->context, buf, len, ms);
        if (n <= 0) return callback_error(n);
        if ((size_t)n > len) return BRIDGE_E_IO;
        if (io->clock_ms(io->context) >= deadline) return BRIDGE_E_TIMEOUT;
        buf += (size_t)n; len -= (size_t)n;
    }
    return BRIDGE_OK;
}
bridge_status bridge_write_exact(bridge_io *io, const uint8_t *buf, size_t len, uint64_t deadline) {
    if (!io || !io->write || !io->clock_ms || (!buf && len)) return BRIDGE_E_ARGUMENT;
    while (len) {
        uint32_t ms;
        bridge_status s = remaining(io, deadline, &ms);
        if (s != BRIDGE_OK) return s;
        ptrdiff_t n = io->write(io->context, buf, len, ms);
        if (n <= 0) return callback_error(n);
        if ((size_t)n > len) return BRIDGE_E_IO;
        if (io->clock_ms(io->context) >= deadline) return BRIDGE_E_TIMEOUT;
        buf += (size_t)n; len -= (size_t)n;
    }
    return BRIDGE_OK;
}
bridge_status bridge_plist_recv(bridge_io *io, uint32_t max, uint8_t *scratch,
    size_t cap, bridge_sink_fn sink, void *ctx, uint64_t deadline, uint32_t *received) {
    if (!scratch || !cap || !sink || !received || !max) return BRIDGE_E_ARGUMENT;
    *received = 0;
    uint8_t h[4];
    bridge_status s = bridge_read_exact(io, h, sizeof h, deadline);
    if (s != BRIDGE_OK) return s;
    uint32_t len = (uint32_t)h[0] << 24 | (uint32_t)h[1] << 16 | (uint32_t)h[2] << 8 | h[3];
    if (!len) return BRIDGE_E_FORMAT;
    if (len > max) return BRIDGE_E_LIMIT;
    uint32_t left = len;
    while (left) {
        size_t n = left < cap ? left : cap;
        s = bridge_read_exact(io, scratch, n, deadline);
        if (s != BRIDGE_OK) return s;
        s = sink(ctx, scratch, n);
        if (s != BRIDGE_OK) return s;
        if (io->clock_ms(io->context) >= deadline) return BRIDGE_E_TIMEOUT;
        left -= (uint32_t)n;
    }
    *received = len;
    return BRIDGE_OK;
}
bridge_status bridge_plist_send(bridge_io *io, const uint8_t *buf, size_t len,
    uint32_t max, uint64_t deadline) {
    if (!buf || !len || !max) return BRIDGE_E_ARGUMENT;
    if (len > max || len > UINT32_MAX) return BRIDGE_E_LIMIT;
    uint8_t h[4] = {(uint8_t)(len >> 24), (uint8_t)(len >> 16), (uint8_t)(len >> 8), (uint8_t)len};
    bridge_status s = bridge_write_exact(io, h, sizeof h, deadline);
    return s == BRIDGE_OK ? bridge_write_exact(io, buf, len, deadline) : s;
}
