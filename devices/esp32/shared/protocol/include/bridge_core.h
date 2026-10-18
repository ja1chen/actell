/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_CORE_H
#define BRIDGE_CORE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    BRIDGE_OK = 0, BRIDGE_E_ARGUMENT, BRIDGE_E_IO, BRIDGE_E_EOF,
    BRIDGE_E_TIMEOUT, BRIDGE_E_LIMIT, BRIDGE_E_FORMAT, BRIDGE_E_TYPE,
    BRIDGE_E_NOT_FOUND, BRIDGE_E_UNSUPPORTED
} bridge_status;
const char *bridge_status_name(bridge_status status);

/* A callback returns bytes transferred or one negative BRIDGE_E_* value.
 * It must enforce the passed remaining timeout, never retain data pointers,
 * and return zero only at EOF. No callback is called with length zero.
 */
typedef ptrdiff_t (*bridge_read_fn)(void *, uint8_t *, size_t, uint32_t);
typedef ptrdiff_t (*bridge_write_fn)(void *, const uint8_t *, size_t, uint32_t);
typedef uint64_t (*bridge_clock_fn)(void *);
typedef bridge_status (*bridge_sink_fn)(void *, const uint8_t *, size_t);
typedef struct {
    void *context;
    bridge_read_fn read;
    bridge_write_fn write;
    bridge_clock_fn clock_ms;
} bridge_io;
bridge_status bridge_read_exact(bridge_io *, uint8_t *, size_t, uint64_t deadline_ms);
bridge_status bridge_write_exact(bridge_io *, const uint8_t *, size_t, uint64_t deadline_ms);
/* Length-prefixed service_connection.py framing, not USB packet framing.
 * Exceeding max_size is terminal: close the transport; do not try to resync.
 * Sinks must be bounded/nonblocking; deadline checks detect overruns but cannot
 * preempt blocking callbacks. Sink failures are terminal too; no screenshot is valid until OK is returned.
 */
bridge_status bridge_plist_recv(bridge_io *, uint32_t max_size, uint8_t *scratch,
    size_t scratch_size, bridge_sink_fn, void *sink_context,
    uint64_t deadline_ms, uint32_t *received_size);
bridge_status bridge_plist_send(bridge_io *, const uint8_t *, size_t,
    uint32_t max_size, uint64_t deadline_ms);
#endif
