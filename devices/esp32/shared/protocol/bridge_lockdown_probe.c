/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Independently implemented, narrow read-only protocol probe. Wire semantics:
 * https://github.com/libimobiledevice/libimobiledevice/blob/master/src/lockdown.c
 * (lockdownd_query_type / lockdownd_client_new), and
 * https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/service_connection.py
 * (build_plist). Consulted 2026-10-02; no upstream implementation is embedded.
 */
#include "bridge_lockdown_probe.h"
#include "bridge_bplist.h"
#include <string.h>

#define TEXT_CAPACITY 64u
#define MAX_REPLY_OBJECTS 7u /* dictionary and up to three key/string pairs */

static const uint8_t query_type_request[] =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
    "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    "<plist version=\"1.0\"><dict>"
    "<key>Label</key><string>" BRIDGE_LOCKDOWN_PROBE_LABEL "</string>"
    "<key>Request</key><string>QueryType</string>"
    "</dict></plist>\n";

typedef struct {
    const uint8_t *data;
    size_t size, pos;
} xml_cursor;

static bool prefix(const xml_cursor *c, const char *text) {
    size_t n = strlen(text);
    return n <= c->size - c->pos && !memcmp(c->data + c->pos, text, n);
}
static bool consume(xml_cursor *c, const char *text) {
    if (!prefix(c, text)) return false;
    c->pos += strlen(text);
    return true;
}
static bool xml_space(uint8_t ch) {
    return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';
}
static bool spaces(xml_cursor *c) {
    size_t before = c->pos;
    while (c->pos < c->size && xml_space(c->data[c->pos])) ++c->pos;
    return c->pos != before;
}
static bool ascii_xml(uint8_t ch) {
    return (ch >= 0x20 && ch <= 0x7e) || xml_space(ch);
}
/* Only XML comments and whitespace between structural tokens are supported.
 * Comments cannot contribute keys or values and cannot contain invalid '--'. */
static bridge_status misc(xml_cursor *c) {
    for (;;) {
        (void)spaces(c);
        if (!consume(c, "<!--")) return BRIDGE_OK;
        for (;;) {
            if (consume(c, "-->")) break;
            if (c->pos == c->size || prefix(c, "--") || !ascii_xml(c->data[c->pos]))
                return BRIDGE_E_FORMAT;
            ++c->pos;
        }
    }
}
static bridge_status quoted_literal(xml_cursor *c, char *out, size_t cap) {
    if (c->pos == c->size || (c->data[c->pos] != '\'' && c->data[c->pos] != '"'))
        return BRIDGE_E_FORMAT;
    uint8_t quote = c->data[c->pos++];
    size_t n = 0;
    while (c->pos < c->size && c->data[c->pos] != quote) {
        uint8_t ch = c->data[c->pos++];
        if (!ascii_xml(ch) || ch == '<' || ch == '&') return BRIDGE_E_FORMAT;
        if (n == cap - 1u) return BRIDGE_E_LIMIT;
        out[n++] = (char)ch;
    }
    if (c->pos == c->size) return BRIDGE_E_FORMAT;
    ++c->pos;
    out[n] = '\0';
    return BRIDGE_OK;
}
static bridge_status attribute(xml_cursor *c, const char *name,
    char *value, size_t cap) {
    if (!consume(c, name)) return BRIDGE_E_FORMAT;
    (void)spaces(c);
    if (!consume(c, "=")) return BRIDGE_E_FORMAT;
    (void)spaces(c);
    return quoted_literal(c, value, cap);
}
static bridge_status declaration(xml_cursor *c) {
    if (!consume(c, "<?xml")) return BRIDGE_OK;
    char value[TEXT_CAPACITY];
    if (!spaces(c)) return BRIDGE_E_FORMAT;
    bridge_status s = attribute(c, "version", value, sizeof value);
    if (s != BRIDGE_OK) return s;
    if (strcmp(value, "1.0")) return BRIDGE_E_UNSUPPORTED;
    bool gap = spaces(c);
    if (prefix(c, "encoding")) {
        if (!gap) return BRIDGE_E_FORMAT;
        s = attribute(c, "encoding", value, sizeof value);
        if (s != BRIDGE_OK) return s;
        if (strcmp(value, "UTF-8") && strcmp(value, "utf-8")) return BRIDGE_E_UNSUPPORTED;
        gap = spaces(c);
    }
    if (prefix(c, "standalone")) {
        if (!gap) return BRIDGE_E_FORMAT;
        s = attribute(c, "standalone", value, sizeof value);
        if (s != BRIDGE_OK) return s;
        if (strcmp(value, "yes") && strcmp(value, "no")) return BRIDGE_E_FORMAT;
        (void)spaces(c);
    }
    return consume(c, "?>") ? BRIDGE_OK : BRIDGE_E_FORMAT;
}
static bridge_status doctype(xml_cursor *c) {
    if (!consume(c, "<!DOCTYPE")) return BRIDGE_OK;
    /* Recognize the normal plist declaration as inert syntax. No DTD parser,
     * internal subset, other public/system ID, entity expansion or network. */
    if (!spaces(c) || !consume(c, "plist") || !spaces(c) ||
        !consume(c, "PUBLIC") || !spaces(c)) return BRIDGE_E_UNSUPPORTED;
    char value[TEXT_CAPACITY];
    bridge_status s = quoted_literal(c, value, sizeof value);
    if (s != BRIDGE_OK) return s;
    if (strcmp(value, "-//Apple//DTD PLIST 1.0//EN")) return BRIDGE_E_UNSUPPORTED;
    if (!spaces(c)) return BRIDGE_E_FORMAT;
    s = quoted_literal(c, value, sizeof value);
    if (s != BRIDGE_OK) return s;
    if (strcmp(value, "http://www.apple.com/DTDs/PropertyList-1.0.dtd"))
        return BRIDGE_E_UNSUPPORTED;
    (void)spaces(c);
    return consume(c, ">") ? BRIDGE_OK : BRIDGE_E_UNSUPPORTED;
}
static bridge_status element_start(xml_cursor *c, const char *name, bool *empty) {
    if (!consume(c, "<") || !consume(c, name)) return BRIDGE_E_FORMAT;
    (void)spaces(c);
    if (consume(c, "/>")) { *empty = true; return BRIDGE_OK; }
    if (!consume(c, ">")) return BRIDGE_E_FORMAT;
    *empty = false;
    return BRIDGE_OK;
}
static bridge_status element_end(xml_cursor *c, const char *name) {
    if (!consume(c, "</") || !consume(c, name)) return BRIDGE_E_FORMAT;
    (void)spaces(c);
    return consume(c, ">") ? BRIDGE_OK : BRIDGE_E_FORMAT;
}
static bridge_status entity(xml_cursor *c, uint8_t *out) {
    static const struct { const char *name; uint8_t ch; } builtins[] = {
        {"amp;", '&'}, {"lt;", '<'}, {"gt;", '>'}, {"quot;", '"'}, {"apos;", '\''}
    };
    if (!consume(c, "&")) return BRIDGE_E_FORMAT;
    if (consume(c, "#")) {
        unsigned radix = consume(c, "x") ? 16u : 10u;
        unsigned n = 0, digits = 0;
        while (c->pos < c->size && c->data[c->pos] != ';') {
            uint8_t ch = c->data[c->pos++];
            unsigned d;
            if (ch >= '0' && ch <= '9') d = (unsigned)(ch - '0');
            else if (radix == 16 && ch >= 'a' && ch <= 'f') d = (unsigned)(ch - 'a') + 10u;
            else if (radix == 16 && ch >= 'A' && ch <= 'F') d = (unsigned)(ch - 'A') + 10u;
            else return BRIDGE_E_FORMAT;
            if (d >= radix || n > (127u - d) / radix) return BRIDGE_E_UNSUPPORTED;
            n = n * radix + d;
            ++digits;
        }
        if (!digits || !consume(c, ";") || !ascii_xml((uint8_t)n)) return BRIDGE_E_FORMAT;
        *out = (uint8_t)n;
        return BRIDGE_OK;
    }
    for (size_t i = 0; i < sizeof builtins / sizeof builtins[0]; ++i) {
        if (consume(c, builtins[i].name)) { *out = builtins[i].ch; return BRIDGE_OK; }
    }
    return BRIDGE_E_UNSUPPORTED;
}
static bridge_status text_element(xml_cursor *c, const char *name,
    char *out, size_t cap) {
    bool empty;
    bridge_status s = element_start(c, name, &empty);
    if (s != BRIDGE_OK) return s;
    size_t n = 0;
    if (!empty) {
        while (c->pos < c->size && c->data[c->pos] != '<') {
            uint8_t ch = c->data[c->pos];
            if (ch == '&') {
                s = entity(c, &ch);
                if (s != BRIDGE_OK) return s;
            } else {
                if (!ascii_xml(ch) || prefix(c, "]]>")) return BRIDGE_E_FORMAT;
                ++c->pos;
            }
            if (n == cap - 1u) return BRIDGE_E_LIMIT;
            out[n++] = (char)ch;
        }
        s = element_end(c, name);
        if (s != BRIDGE_OK) return s;
    }
    out[n] = '\0';
    return BRIDGE_OK;
}
static bridge_status check_pair(const char *key, const char *value, unsigned *seen) {
    unsigned bit;
    const char *expected;
    if (!strcmp(key, "Type")) { bit = 1u; expected = BRIDGE_LOCKDOWN_SERVICE_TYPE; }
    else if (!strcmp(key, "Request")) { bit = 2u; expected = "QueryType"; }
    else if (!strcmp(key, "Result")) { bit = 4u; expected = "Success"; }
    else if (!strcmp(key, "Error")) return BRIDGE_E_TYPE;
    else return BRIDGE_E_UNSUPPORTED;
    if (*seen & bit) return BRIDGE_E_FORMAT;
    *seen |= bit;
    return strcmp(value, expected) ? BRIDGE_E_TYPE : BRIDGE_OK;
}
static bridge_status parse_xml(const uint8_t *data, size_t size, unsigned *seen) {
    xml_cursor c = {data, size, 0};
    if (size >= 3 && !memcmp(data, "\xef\xbb\xbf", 3)) c.pos = 3;
    bridge_status s = declaration(&c);
    if (s != BRIDGE_OK || (s = misc(&c)) != BRIDGE_OK ||
        (s = doctype(&c)) != BRIDGE_OK || (s = misc(&c)) != BRIDGE_OK) return s;
    if (!consume(&c, "<plist") || !spaces(&c)) return BRIDGE_E_FORMAT;
    char version[TEXT_CAPACITY];
    s = attribute(&c, "version", version, sizeof version);
    if (s != BRIDGE_OK) return s;
    if (strcmp(version, "1.0")) return BRIDGE_E_UNSUPPORTED;
    (void)spaces(&c);
    if (!consume(&c, ">")) return BRIDGE_E_FORMAT;
    if ((s = misc(&c)) != BRIDGE_OK) return s;
    bool empty;
    s = element_start(&c, "dict", &empty);
    if (s != BRIDGE_OK) return s;
    unsigned pairs = 0;
    if (!empty) {
        for (;;) {
            if ((s = misc(&c)) != BRIDGE_OK) return s;
            if (prefix(&c, "</dict")) break;
            if (++pairs > 3u) return BRIDGE_E_UNSUPPORTED;
            char key[TEXT_CAPACITY], value[TEXT_CAPACITY];
            if ((s = text_element(&c, "key", key, sizeof key)) != BRIDGE_OK ||
                (s = misc(&c)) != BRIDGE_OK ||
                (s = text_element(&c, "string", value, sizeof value)) != BRIDGE_OK ||
                (s = check_pair(key, value, seen)) != BRIDGE_OK) return s;
        }
        if ((s = element_end(&c, "dict")) != BRIDGE_OK) return s;
    }
    if ((s = misc(&c)) != BRIDGE_OK || (s = element_end(&c, "plist")) != BRIDGE_OK ||
        (s = misc(&c)) != BRIDGE_OK) return s;
    return c.pos == c.size ? BRIDGE_OK : BRIDGE_E_FORMAT;
}

static uint64_t read_be(const uint8_t *data, uint8_t width) {
    uint64_t value = 0;
    while (width--) value = value << 8 | *data++;
    return value;
}
static bridge_status bplist_text(const bridge_bplist_value *value, char *out) {
    if (value->type != 5 && value->type != 6) return BRIDGE_E_TYPE;
    if (value->length >= TEXT_CAPACITY) return BRIDGE_E_LIMIT;
    for (size_t i = 0; i < value->length; ++i) {
        uint8_t ch;
        if (value->type == 6) {
            if (value->payload[i * 2] != 0) return BRIDGE_E_UNSUPPORTED;
            ch = value->payload[i * 2 + 1];
        } else ch = value->payload[i];
        if (!ascii_xml(ch)) return BRIDGE_E_FORMAT;
        out[i] = (char)ch;
    }
    out[value->length] = '\0';
    return BRIDGE_OK;
}
static bridge_status parse_binary(const uint8_t *data, size_t size, unsigned *seen) {
    bridge_bplist p;
    bridge_status s = bridge_bplist_open(&p, data, size);
    if (s != BRIDGE_OK) return s;
    if (p.count > MAX_REPLY_OBJECTS) return BRIDGE_E_LIMIT;
    if (p.table + (size_t)p.count * p.offset_width != size - 32u)
        return BRIDGE_E_FORMAT;
    for (size_t i = size - 32u; i < size - 26u; ++i)
        if (data[i]) return BRIDGE_E_FORMAT;
    bridge_bplist_value values[MAX_REPLY_OBJECTS];
    size_t starts[MAX_REPLY_OBJECTS], ends[MAX_REPLY_OBJECTS];
    bool used[MAX_REPLY_OBJECTS] = {false};
    /* Validate every object, including otherwise unreachable objects; reject
     * overlap/duplicate offsets, padding and hidden nested/unsupported data.
     * This stricter subset has bounded work and never walks recursive graphs. */
    for (uint64_t i = 0; i < p.count; ++i) {
        s = bridge_bplist_get(&p, i, &values[i]);
        if (s != BRIDGE_OK) return s;
        bridge_bplist_value *v = &values[i];
        if (i == p.root) {
            if (v->type != 13) return BRIDGE_E_TYPE;
            if (v->length > 3u) return BRIDGE_E_UNSUPPORTED;
        } else if (v->type != 5 && v->type != 6) return BRIDGE_E_TYPE;
        starts[i] = (size_t)read_be(data + p.table + (size_t)i * p.offset_width, p.offset_width);
        size_t unit = i == p.root ? 2u * p.ref_width : (v->type == 6 ? 2u : 1u);
        ends[i] = (size_t)(v->payload - data) + v->length * unit;
        for (uint64_t j = 0; j < i; ++j)
            if (starts[i] < ends[j] && starts[j] < ends[i]) return BRIDGE_E_FORMAT;
    }
    size_t position = 8u;
    for (uint64_t n = 0; n < p.count; ++n) {
        bool found = false;
        for (uint64_t i = 0; i < p.count; ++i) {
            if (starts[i] == position) { position = ends[i]; found = true; break; }
        }
        if (!found) return BRIDGE_E_FORMAT;
    }
    if (position != p.table) return BRIDGE_E_FORMAT;
    used[p.root] = true;
    const bridge_bplist_value *dict = &values[p.root];
    for (size_t i = 0; i < dict->length; ++i) {
        uint64_t key_ref = read_be(dict->payload + i * p.ref_width, p.ref_width);
        uint64_t value_ref = read_be(dict->payload + (dict->length + i) * p.ref_width, p.ref_width);
        char key[TEXT_CAPACITY], value[TEXT_CAPACITY];
        if ((s = bplist_text(&values[key_ref], key)) != BRIDGE_OK ||
            (s = bplist_text(&values[value_ref], value)) != BRIDGE_OK ||
            (s = check_pair(key, value, seen)) != BRIDGE_OK) return s;
        used[key_ref] = used[value_ref] = true;
    }
    for (uint64_t i = 0; i < p.count; ++i)
        if (!used[i]) return BRIDGE_E_FORMAT;
    return BRIDGE_OK;
}

bridge_status bridge_lockdown_probe_parse_reply(const uint8_t *data, size_t size,
    bridge_lockdown_probe_result *out) {
    if (!out) return BRIDGE_E_ARGUMENT;
    memset(out, 0, sizeof *out);
    if (!data) return BRIDGE_E_ARGUMENT;
    if (!size) return BRIDGE_E_FORMAT;
    if (size > BRIDGE_LOCKDOWN_PROBE_MAX_REPLY_BYTES) return BRIDGE_E_LIMIT;
    unsigned seen = 0;
    bool binary = size >= 8 && !memcmp(data, "bplist00", 8);
    bridge_status s = binary ? parse_binary(data, size, &seen) : parse_xml(data, size, &seen);
    if (s != BRIDGE_OK) return s;
    if (!(seen & 1u)) return BRIDGE_E_NOT_FOUND;
    *out = (bridge_lockdown_probe_result){
        .encoding = binary ? BRIDGE_LOCKDOWN_ENCODING_BINARY : BRIDGE_LOCKDOWN_ENCODING_XML,
        .reply_bytes = (uint32_t)size,
        .request_echoed = (seen & 2u) != 0,
        .lockdown_type_verified = true
    };
    return BRIDGE_OK;
}

typedef struct { uint8_t *data; size_t size, capacity; } reply_sink;
static bridge_status collect_reply(void *context, const uint8_t *data, size_t size) {
    reply_sink *sink = context;
    if (size > sink->capacity - sink->size) return BRIDGE_E_LIMIT;
    memcpy(sink->data + sink->size, data, size);
    sink->size += size;
    return BRIDGE_OK;
}
bridge_status bridge_lockdown_probe_query_type(bridge_io *io,
    uint8_t *reply_buffer, size_t reply_capacity, uint64_t deadline_ms,
    bridge_lockdown_probe_result *out) {
    if (!out) return BRIDGE_E_ARGUMENT;
    memset(out, 0, sizeof *out);
    if (!io || !io->read || !io->write || !io->clock_ms || !reply_buffer ||
        !reply_capacity || reply_capacity > BRIDGE_LOCKDOWN_PROBE_MAX_REPLY_BYTES)
        return BRIDGE_E_ARGUMENT;
    bridge_status s = bridge_plist_send(io, query_type_request, sizeof query_type_request - 1u,
        (uint32_t)(sizeof query_type_request - 1u), deadline_ms);
    if (s != BRIDGE_OK) return s;
    uint8_t scratch[128];
    reply_sink sink = {reply_buffer, 0, reply_capacity};
    uint32_t received;
    s = bridge_plist_recv(io, (uint32_t)reply_capacity, scratch, sizeof scratch,
        collect_reply, &sink, deadline_ms, &received);
    if (s != BRIDGE_OK) return s;
    bridge_lockdown_probe_result verified;
    s = bridge_lockdown_probe_parse_reply(reply_buffer, received, &verified);
    if (s != BRIDGE_OK) return s;
    if (io->clock_ms(io->context) >= deadline_ms) return BRIDGE_E_TIMEOUT;
    *out = verified;
    return BRIDGE_OK;
}
