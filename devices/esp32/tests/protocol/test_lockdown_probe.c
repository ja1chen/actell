/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bridge_lockdown_probe.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

typedef struct {
    const uint8_t *data;
    size_t size;
    bridge_status status;
    bridge_lockdown_encoding encoding;
    bool echo;
} fixture;
#include "lockdown_fixtures.h"

static const char expected_request[] =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
    "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    "<plist version=\"1.0\"><dict>"
    "<key>Label</key><string>esp32-iphone-bridge</string>"
    "<key>Request</key><string>QueryType</string>"
    "</dict></plist>\n";
#define WRAP(s) "<plist version=\"1.0\"><dict>" s "</dict></plist>"
#define TYPE "<key>Type</key><string>com.apple.mobile.lockdown</string>"
#define REQUEST "<key>Request</key><string>QueryType</string>"
static const char minimal[] = WRAP(TYPE);

static void expect_zero(const bridge_lockdown_probe_result *result) {
    assert(result->encoding == BRIDGE_LOCKDOWN_ENCODING_UNKNOWN);
    assert(result->reply_bytes == 0 && !result->request_echoed && !result->lockdown_type_verified);
}
static void check(const uint8_t *data, size_t size, bridge_status expected) {
    bridge_lockdown_probe_result result;
    memset(&result, 0x99, sizeof result);
    bridge_status status = bridge_lockdown_probe_parse_reply(data, size, &result);
    if (status != expected) {
        fprintf(stderr, "Expected %s, got %s (%zu-byte input)\n", bridge_status_name(expected), bridge_status_name(status), size);
        abort();
    }
    if (status != BRIDGE_OK) expect_zero(&result);
    else assert(result.lockdown_type_verified && result.reply_bytes == size);
}
static void xml(const char *data, bridge_status expected) {
    check((const uint8_t *)data, strlen(data), expected);
}
static void test_fixtures(void) {
    for (size_t i = 0; i < sizeof fixtures / sizeof fixtures[0]; ++i) {
        const fixture *f = &fixtures[i];
        check(f->data, f->size, f->status);
        if (f->status == BRIDGE_OK) {
            bridge_lockdown_probe_result result;
            assert(bridge_lockdown_probe_parse_reply(f->data, f->size, &result) == BRIDGE_OK);
            assert(result.encoding == f->encoding && result.request_echoed == f->echo);
        }
    }
}
static void test_xml(void) {
    xml(minimal, BRIDGE_OK);
    xml(WRAP(TYPE REQUEST), BRIDGE_OK);
    xml("\xef\xbb\xbf<?xml version='1.0' encoding = 'utf-8' standalone='yes'?>\n" WRAP(TYPE), BRIDGE_OK);
    xml("<?xml version='1.0' standalone='no'?>" WRAP(TYPE), BRIDGE_OK);
    xml("<?xml version='1.0'?>" WRAP(TYPE), BRIDGE_OK);
    xml("<!-- <key>Type</key><string>wrong</string> -->\n" WRAP(TYPE) "<!--after-->", BRIDGE_OK);
    xml("<plist version = '1.0' > <dict >\n" TYPE "</dict > </plist >", BRIDGE_OK);
    xml(WRAP("<key>Ty&#112;e</key><string>com.apple.mobile.lockdow&#x6e;</string>"), BRIDGE_OK);
    xml(WRAP(TYPE "<key>Result</key><string>Success</string>"), BRIDGE_OK);
    xml(WRAP(TYPE TYPE), BRIDGE_E_FORMAT);
    xml(WRAP(TYPE REQUEST REQUEST), BRIDGE_E_FORMAT);
    xml(WRAP(TYPE "<key>Ty&#x70;e</key><string>com.apple.mobile.lockdown</string>"), BRIDGE_E_FORMAT);
    xml(WRAP(TYPE "<key>Request</key><string>GetValue</string>"), BRIDGE_E_TYPE);
    xml(WRAP(TYPE "<key>Error</key><string/>"), BRIDGE_E_TYPE);
    xml(WRAP(TYPE "<key>Result</key><string>Failure</string>"), BRIDGE_E_TYPE);
    xml(WRAP(TYPE "<key>Foo</key><string>Bar</string>"), BRIDGE_E_UNSUPPORTED);
    xml(WRAP("<key>Type</key><string>wrongcom.apple.mobile.lockdown</string>"), BRIDGE_E_TYPE);
    xml(WRAP("<key>Type</key><string>com.apple.mobile.lockdownx</string>"), BRIDGE_E_TYPE);
    xml(WRAP("<key>Type</key><string>com.apple.mobile.lockdown </string>"), BRIDGE_E_TYPE);
    xml(WRAP("<key>Type</key><data>com.apple.mobile.lockdown</data>"), BRIDGE_E_FORMAT);
    xml(WRAP("<key>Type</key><string/>"), BRIDGE_E_TYPE);
    xml(WRAP("<key>Type</key><string />"), BRIDGE_E_TYPE);
    xml(WRAP("<key>Type</key><string>&unknown;</string>"), BRIDGE_E_UNSUPPORTED);
    xml(WRAP("<key>Type</key><string>&amp;&lt;&gt;&quot;&apos;</string>"), BRIDGE_E_TYPE);
    xml(WRAP("<key>Type</key><string>&#9999999999999999999999;</string>"), BRIDGE_E_UNSUPPORTED);
    xml(WRAP("<key>Type</key><string>&#x1f600;</string>"), BRIDGE_E_UNSUPPORTED);
    xml(WRAP("<key>Type</key><string>&#x;</string>"), BRIDGE_E_FORMAT);
    xml(WRAP("<key>Type</key><string>&#0;</string>"), BRIDGE_E_FORMAT);
    xml(WRAP("<key>Type</key><string>&#12;</string>"), BRIDGE_E_FORMAT);
    xml(WRAP("<key>Type</key><string>&#Z;</string>"), BRIDGE_E_FORMAT);
    xml(WRAP("<key>Type</key><string>&#x1G;</string>"), BRIDGE_E_FORMAT);
    xml(WRAP("<key>Type</key><string><![CDATA[com.apple.mobile.lockdown]]></string>"), BRIDGE_E_FORMAT);
    xml(WRAP("<key>Type</key><string>com.apple.mobile.lockdown<!--x--></string>"), BRIDGE_E_FORMAT);
    xml(WRAP("<key>Type</key><string>]]></string>"), BRIDGE_E_FORMAT);
    xml(WRAP("<key>Type</key><string>\1</string>"), BRIDGE_E_FORMAT);
    xml(WRAP("<key>Type</key><string>\xff</string>"), BRIDGE_E_FORMAT);
    xml(WRAP("<key>Type</key><dict>" TYPE "</dict>"), BRIDGE_E_FORMAT);
    xml(WRAP("<array><dict>" TYPE "</dict></array>"), BRIDGE_E_FORMAT);
    xml(WRAP("<!--" TYPE "-->"), BRIDGE_E_NOT_FOUND);
    xml(WRAP("<!--unterminated"), BRIDGE_E_FORMAT);
    xml(WRAP("<!--invalid--comment-->" TYPE), BRIDGE_E_FORMAT);
    xml(WRAP(""), BRIDGE_E_NOT_FOUND);
    xml("<plist version='1.0'><dict /></plist>", BRIDGE_E_NOT_FOUND);
    xml("<plist version='1.0'><dict/> </plist>", BRIDGE_E_NOT_FOUND);
    xml("<plist version='1.0'><array>" TYPE "</array></plist>", BRIDGE_E_FORMAT);
    xml("<plist version='1.0'><dict>" TYPE "</plist></dict>", BRIDGE_E_FORMAT);
    xml("<plist version='1.0'><dictionary>" TYPE "</dictionary></plist>", BRIDGE_E_FORMAT);
    xml("<plist version='1.0'><dict>" TYPE "</dictionary></plist>", BRIDGE_E_FORMAT);
    xml("<plist version='1.0'><dict>" TYPE "</dict></plistx>", BRIDGE_E_FORMAT);
    xml("<plist version='1.0'><dict>" TYPE "</dict></plist>trailing", BRIDGE_E_FORMAT);
    xml(WRAP(TYPE) WRAP(TYPE), BRIDGE_E_FORMAT);
    xml("<plist version='1.0' version='1.0'><dict>" TYPE "</dict></plist>", BRIDGE_E_FORMAT);
    xml("<plist version='2.0'><dict>" TYPE "</dict></plist>", BRIDGE_E_UNSUPPORTED);
    xml("<?xml version='1.1'?>" WRAP(TYPE), BRIDGE_E_UNSUPPORTED);
    xml("<?xml version='1.0' encoding='UTF-16'?>" WRAP(TYPE), BRIDGE_E_UNSUPPORTED);
    xml("<?xml version='1.0' standalone='perhaps'?>" WRAP(TYPE), BRIDGE_E_FORMAT);
    xml("<?xml version='1.0'encoding='UTF-8'?>" WRAP(TYPE), BRIDGE_E_FORMAT);
    xml("<?xml version='1.0' encoding='UTF-8' encoding='UTF-8'?>" WRAP(TYPE), BRIDGE_E_FORMAT);
    xml("<?xml version='1.0'?><?xml version='1.0'?>" WRAP(TYPE), BRIDGE_E_FORMAT);
    xml("<?instruction do='evil'?>" WRAP(TYPE), BRIDGE_E_FORMAT);
    xml("<!DOCTYPE plist SYSTEM 'file:///etc/passwd'>" WRAP(TYPE), BRIDGE_E_UNSUPPORTED);
    xml("<!DOCTYPE plist [<!ENTITY x SYSTEM 'file:///etc/passwd'>]>" WRAP(TYPE), BRIDGE_E_UNSUPPORTED);
    xml("<!DOCTYPE plist PUBLIC '-//Apple//DTD PLIST 1.0//EN' 'https://attacker.invalid/dtd'>" WRAP(TYPE), BRIDGE_E_UNSUPPORTED);
    xml("<!DOCTYPE plist PUBLIC '-//Apple//DTD PLIST 1.0//EN' 'http://www.apple.com/DTDs/PropertyList-1.0.dtd' [<!ENTITY x 'x'>]>" WRAP(TYPE), BRIDGE_E_UNSUPPORTED);
    char large[BRIDGE_LOCKDOWN_PROBE_MAX_REPLY_BYTES + 1u];
    memset(large, ' ', sizeof large);
    memcpy(large, minimal, sizeof minimal - 1u);
    check((const uint8_t *)large, sizeof large - 1u, BRIDGE_OK);
    check((const uint8_t *)large, sizeof large, BRIDGE_E_LIMIT);
    memset(large, 0, sizeof large);
    (void)snprintf(large, sizeof large, "<plist version='1.0'><dict><key>Type</key><string>%080u</string></dict></plist>", 1u);
    xml(large, BRIDGE_E_LIMIT);
    /* Deep input fails at the first unexpected structural token, no recursion. */
    strcpy(large, "<plist version='1.0'><dict><key>Type</key>");
    for (unsigned i = 0; i < 200; ++i) strcat(large, "<array>");
    xml(large, BRIDGE_E_FORMAT);
    check((const uint8_t *)minimal, sizeof minimal, BRIDGE_E_FORMAT); /* NUL isn't XML whitespace */
    check(NULL, 10, BRIDGE_E_ARGUMENT);
    check((const uint8_t *)minimal, 0, BRIDGE_E_FORMAT);
    assert(bridge_lockdown_probe_parse_reply((const uint8_t *)minimal, strlen(minimal), NULL) == BRIDGE_E_ARGUMENT);
    /* Every non-whitespace truncation of a minimal valid reply fails. */
    for (size_t n = 0; n < strlen(minimal); ++n) {
        bridge_lockdown_probe_result result;
        assert(bridge_lockdown_probe_parse_reply((const uint8_t *)minimal, n, &result) != BRIDGE_OK);
        expect_zero(&result);
    }
}

typedef struct {
    uint8_t reply[BRIDGE_LOCKDOWN_PROBE_MAX_REPLY_BYTES + 8u];
    uint8_t sent[1024];
    size_t reply_size, read_pos, written, fragment;
    size_t reads, writes;
    uint64_t now, step_ms, deadline;
    uint32_t last_timeout;
    int read_error, write_error;
    bool read_oversize, write_oversize, write_eof, late_on_final_clock;
} synthetic_peer;
static size_t request_frame_size(void) { return sizeof expected_request - 1u + 4u; }
static uint8_t request_byte(size_t pos) {
    const uint32_t size = (uint32_t)(sizeof expected_request - 1u);
    if (pos < 4u) return (uint8_t)(size >> (8u * (3u - (unsigned)pos)));
    return (uint8_t)expected_request[pos - 4u];
}
static void check_timeout(synthetic_peer *peer, uint32_t ms) {
    assert(ms && peer->now < peer->deadline);
    uint64_t left = peer->deadline - peer->now;
    assert(ms == (left > UINT32_MAX ? UINT32_MAX : (uint32_t)left));
    assert(!peer->last_timeout || ms <= peer->last_timeout);
    peer->last_timeout = ms;
    peer->now += peer->step_ms;
}
static ptrdiff_t read_fragment(void *context, uint8_t *bytes, size_t size, uint32_t ms) {
    synthetic_peer *peer = context;
    assert(size && peer->written == request_frame_size());
    ++peer->reads;
    check_timeout(peer, ms);
    if (peer->read_error) return -(ptrdiff_t)peer->read_error;
    if (peer->read_oversize) return (ptrdiff_t)size + 1;
    if (size > peer->fragment) size = peer->fragment;
    if (size > peer->reply_size - peer->read_pos) size = peer->reply_size - peer->read_pos;
    memcpy(bytes, peer->reply + peer->read_pos, size);
    peer->read_pos += size;
    return (ptrdiff_t)size;
}
static ptrdiff_t write_fragment(void *context, const uint8_t *bytes, size_t size, uint32_t ms) {
    synthetic_peer *peer = context;
    assert(size && !peer->reads);
    ++peer->writes;
    check_timeout(peer, ms);
    if (peer->write_error) return -(ptrdiff_t)peer->write_error;
    if (peer->write_eof) return 0;
    if (peer->write_oversize) return (ptrdiff_t)size + 1;
    if (size > peer->fragment) size = peer->fragment;
    assert(size <= request_frame_size() - peer->written);
    for (size_t i = 0; i < size; ++i) assert(bytes[i] == request_byte(peer->written + i));
    memcpy(peer->sent + peer->written, bytes, size);
    peer->written += size;
    return (ptrdiff_t)size;
}
static uint64_t peer_clock(void *context) {
    synthetic_peer *peer = context;
    /* Called once after final read, once after sink and once after validation. */
    if (peer->late_on_final_clock && peer->read_pos == peer->reply_size && peer->read_pos) {
        if (++peer->now > 2u) return peer->deadline;
    }
    return peer->now;
}
static void init_peer(synthetic_peer *peer, const uint8_t *data, size_t size, size_t fragment) {
    assert(size <= BRIDGE_LOCKDOWN_PROBE_MAX_REPLY_BYTES);
    memset(peer, 0, sizeof *peer);
    peer->reply[0] = (uint8_t)(size >> 24);
    peer->reply[1] = (uint8_t)(size >> 16);
    peer->reply[2] = (uint8_t)(size >> 8);
    peer->reply[3] = (uint8_t)size;
    memcpy(peer->reply + 4u, data, size);
    peer->reply_size = size + 4u;
    peer->fragment = fragment;
    peer->deadline = 100000;
}
static bridge_status run_peer(synthetic_peer *peer, size_t capacity, bridge_lockdown_probe_result *out) {
    bridge_io io = {peer, read_fragment, write_fragment, peer_clock};
    uint8_t reply[BRIDGE_LOCKDOWN_PROBE_MAX_REPLY_BYTES];
    memset(out, 0x99, sizeof *out);
    bridge_status s = bridge_lockdown_probe_query_type(&io, reply, capacity, peer->deadline, out);
    if (s != BRIDGE_OK) expect_zero(out);
    return s;
}
static void test_transport(void) {
    synthetic_peer peer;
    bridge_lockdown_probe_result result;
    for (size_t f = 1; f <= 257; f += f < 32 ? 1u : 15u) {
        for (size_t i = 0; i < sizeof fixtures / sizeof fixtures[0]; ++i) {
            const fixture *fxt = &fixtures[i];
            init_peer(&peer, fxt->data, fxt->size, f);
            peer.step_ms = 1;
            assert(run_peer(&peer, BRIDGE_LOCKDOWN_PROBE_MAX_REPLY_BYTES, &result) == fxt->status);
            assert(peer.read_pos == peer.reply_size && peer.written == request_frame_size());
        }
    }
    init_peer(&peer, (const uint8_t *)minimal, strlen(minimal), 1);
    assert(run_peer(&peer, strlen(minimal), &result) == BRIDGE_OK);
    FILE *capture = fopen(".build/lockdown-fixtures/captured_query.bin", "wb");
    assert(capture && fwrite(peer.sent, 1, peer.written, capture) == peer.written && fclose(capture) == 0);
    init_peer(&peer, (const uint8_t *)minimal, strlen(minimal), 4096);
    peer.reply[peer.reply_size++] = 0xff; /* next frame is not consumed */
    assert(run_peer(&peer, 4096, &result) == BRIDGE_OK && peer.read_pos == peer.reply_size - 1u);
    init_peer(&peer, (const uint8_t *)minimal, strlen(minimal), 4096);
    assert(run_peer(&peer, strlen(minimal) - 1u, &result) == BRIDGE_E_LIMIT && peer.read_pos == 4u);
    for (size_t n = 0; n < strlen(minimal) + 4u; ++n) {
        init_peer(&peer, (const uint8_t *)minimal, strlen(minimal), 3);
        peer.reply_size = n;
        assert(run_peer(&peer, 4096, &result) == BRIDGE_E_EOF);
    }
    init_peer(&peer, (const uint8_t *)minimal, strlen(minimal), 4096);
    memset(peer.reply, 0, 4);
    assert(run_peer(&peer, 4096, &result) == BRIDGE_E_FORMAT && peer.read_pos == 4u);
    init_peer(&peer, (const uint8_t *)minimal, strlen(minimal), 4096);
    memset(peer.reply, 0xff, 4);
    assert(run_peer(&peer, 4096, &result) == BRIDGE_E_LIMIT && peer.read_pos == 4u);
    for (int error = BRIDGE_E_IO; error <= BRIDGE_E_TIMEOUT; ++error) {
        init_peer(&peer, (const uint8_t *)minimal, strlen(minimal), 4096);
        peer.read_error = error;
        bridge_status expected = error == BRIDGE_E_TIMEOUT ? BRIDGE_E_TIMEOUT : BRIDGE_E_IO;
        assert(run_peer(&peer, 4096, &result) == expected);
        init_peer(&peer, (const uint8_t *)minimal, strlen(minimal), 4096);
        peer.write_error = error;
        assert(run_peer(&peer, 4096, &result) == expected && peer.reads == 0);
    }
    init_peer(&peer, (const uint8_t *)minimal, strlen(minimal), 4096);
    peer.read_oversize = true;
    assert(run_peer(&peer, 4096, &result) == BRIDGE_E_IO);
    init_peer(&peer, (const uint8_t *)minimal, strlen(minimal), 4096);
    peer.write_oversize = true;
    assert(run_peer(&peer, 4096, &result) == BRIDGE_E_IO && peer.reads == 0);
    init_peer(&peer, (const uint8_t *)minimal, strlen(minimal), 4096);
    peer.write_eof = true;
    assert(run_peer(&peer, 4096, &result) == BRIDGE_E_EOF && peer.reads == 0);
    init_peer(&peer, (const uint8_t *)minimal, strlen(minimal), 1);
    peer.step_ms = 1;
    peer.deadline = 3;
    assert(run_peer(&peer, 4096, &result) == BRIDGE_E_TIMEOUT && peer.reads == 0);
    init_peer(&peer, (const uint8_t *)minimal, strlen(minimal), 4096);
    peer.step_ms = 1;
    peer.deadline = 4;
    assert(run_peer(&peer, 4096, &result) == BRIDGE_E_TIMEOUT);
    init_peer(&peer, (const uint8_t *)minimal, strlen(minimal), 4096);
    peer.late_on_final_clock = true;
    assert(run_peer(&peer, 4096, &result) == BRIDGE_E_TIMEOUT);
    init_peer(&peer, (const uint8_t *)minimal, strlen(minimal), 4096);
    peer.deadline = 0;
    assert(run_peer(&peer, 4096, &result) == BRIDGE_E_TIMEOUT && peer.writes == 0);
    init_peer(&peer, (const uint8_t *)minimal, strlen(minimal), 4096);
    peer.now = UINT64_MAX - 100u;
    peer.deadline = UINT64_MAX;
    assert(run_peer(&peer, 4096, &result) == BRIDGE_OK);
    init_peer(&peer, (const uint8_t *)minimal, strlen(minimal), 4096);
    peer.deadline = UINT64_MAX;
    assert(run_peer(&peer, 4096, &result) == BRIDGE_OK && peer.last_timeout == UINT32_MAX);
    init_peer(&peer, (const uint8_t *)minimal, strlen(minimal), 4096);
    assert(run_peer(&peer, 0, &result) == BRIDGE_E_ARGUMENT && peer.writes == 0);
    assert(run_peer(&peer, 4097, &result) == BRIDGE_E_ARGUMENT && peer.writes == 0);
    uint8_t reply[4096];
    bridge_io io = {&peer, read_fragment, write_fragment, peer_clock};
    assert(bridge_lockdown_probe_query_type(NULL, reply, sizeof reply, 999, &result) == BRIDGE_E_ARGUMENT);
    assert(bridge_lockdown_probe_query_type(&io, NULL, sizeof reply, 999, &result) == BRIDGE_E_ARGUMENT);
    assert(bridge_lockdown_probe_query_type(&io, reply, sizeof reply, 999, NULL) == BRIDGE_E_ARGUMENT);
    io.read = NULL;
    assert(bridge_lockdown_probe_query_type(&io, reply, sizeof reply, 999, &result) == BRIDGE_E_ARGUMENT);
    io.read = read_fragment; io.write = NULL;
    assert(bridge_lockdown_probe_query_type(&io, reply, sizeof reply, 999, &result) == BRIDGE_E_ARGUMENT);
    io.write = write_fragment; io.clock_ms = NULL;
    assert(bridge_lockdown_probe_query_type(&io, reply, sizeof reply, 999, &result) == BRIDGE_E_ARGUMENT);
    expect_zero(&result);
}
static uint32_t state = UINT32_C(0x4c4f434b);
static uint32_t random_u32(void) {
    state ^= state << 13; state ^= state >> 17; state ^= state << 5;
    return state;
}
static void test_mutations(void) {
    uint8_t bytes[BRIDGE_LOCKDOWN_PROBE_MAX_REPLY_BYTES];
    for (unsigned run = 0; run < 40000u; ++run) {
        const fixture *f = &fixtures[random_u32() % (sizeof fixtures / sizeof fixtures[0])];
        size_t size = f->size;
        memcpy(bytes, f->data, size);
        for (unsigned i = 0, n = 1u + random_u32() % 8u; i < n; ++i)
            bytes[random_u32() % size] = (uint8_t)random_u32();
        if (run % 3u == 0) size = random_u32() % (size + 1u);
        bridge_lockdown_probe_result result;
        bridge_status s = bridge_lockdown_probe_parse_reply(bytes, size, &result);
        if (s != BRIDGE_OK) expect_zero(&result);
        else assert(result.lockdown_type_verified && result.reply_bytes == size);
    }
    for (unsigned run = 0; run < 10000u; ++run) {
        size_t size = random_u32() % sizeof bytes;
        for (size_t i = 0; i < size; ++i) bytes[i] = (uint8_t)random_u32();
        bridge_lockdown_probe_result result;
        assert(bridge_lockdown_probe_parse_reply(bytes, size, &result) != BRIDGE_OK);
        expect_zero(&result);
    }
    for (size_t i = 0; i < sizeof fixtures / sizeof fixtures[0]; ++i) {
        const fixture *f = &fixtures[i];
        if (f->encoding != BRIDGE_LOCKDOWN_ENCODING_BINARY || f->status != BRIDGE_OK) continue;
        for (size_t n = 0; n < f->size; ++n) {
            bridge_lockdown_probe_result result;
            assert(bridge_lockdown_probe_parse_reply(f->data, n, &result) != BRIDGE_OK);
            expect_zero(&result);
        }
    }
}
int main(void) {
    test_fixtures(); test_xml(); test_transport(); test_mutations();
    puts("PASS: strict XML/binary QueryType replies, exact fragmented request/response, limits, deadlines, EOF/errors, 50000 parser mutations/random inputs (ASan/UBSan)");
    return 0;
}
