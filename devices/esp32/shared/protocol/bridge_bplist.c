/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bridge_bplist.h"
#include <string.h>
#include <limits.h>

static uint64_t be(const uint8_t *p, uint8_t n) {
    uint64_t v = 0; while (n--) v = (v << 8) | *p++; return v;
}
static bool width(uint8_t n) { return n == 1 || n == 2 || n == 4 || n == 8; }
static bool within(size_t offset, size_t n, size_t end) { return offset <= end && n <= end - offset; }
bridge_status bridge_bplist_open(bridge_bplist *p, const uint8_t *data, size_t size) {
    if (!p || !data) return BRIDGE_E_ARGUMENT;
    memset(p, 0, sizeof *p);
    if (size < 40 || memcmp(data, "bplist00", 8)) return BRIDGE_E_FORMAT;
    const uint8_t *t = data + size - 32;
    uint8_t ow = t[6], rw = t[7];
    uint64_t count = be(t + 8, 8), root = be(t + 16, 8), table = be(t + 24, 8);
    if (!width(ow) || !width(rw) || !count || root >= count || table < 8 || table > SIZE_MAX)
        return BRIDGE_E_FORMAT;
    if (count > BRIDGE_BPLIST_MAX_OBJECTS) return BRIDGE_E_LIMIT;
    if (!within((size_t)table, (size_t)count * ow, size - 32)) return BRIDGE_E_FORMAT;
    if (rw < 8 && count - 1 >= (UINT64_C(1) << (rw * 8))) return BRIDGE_E_FORMAT;
    for (uint64_t i = 0; i < count; ++i) {
        uint64_t off = be(data + (size_t)table + (size_t)i * ow, ow);
        if (off < 8 || off >= table) return BRIDGE_E_FORMAT;
    }
    *p = (bridge_bplist){data, size, (size_t)table, count, root, ow, rw};
    return BRIDGE_OK;
}
bridge_status bridge_bplist_get(const bridge_bplist *p, uint64_t ref, bridge_bplist_value *out) {
    if (!p || !p->data || !out) return BRIDGE_E_ARGUMENT;
    if (ref >= p->count) return BRIDGE_E_FORMAT;
    size_t pos = (size_t)be(p->data + p->table + (size_t)ref * p->offset_width, p->offset_width);
    uint8_t marker = p->data[pos++], type = marker >> 4, low = marker & 15;
    uint64_t len = low;
    if ((type == 4 || type == 5 || type == 6 || type == 10 || type == 13) && low == 15) {
        if (!within(pos, 1, p->table)) return BRIDGE_E_FORMAT;
        uint8_t lm = p->data[pos++];
        if ((lm >> 4) != 1 || (lm & 15) > 3) return BRIDGE_E_FORMAT;
        uint8_t bytes = (uint8_t)(1u << (lm & 15));
        if (!within(pos, bytes, p->table)) return BRIDGE_E_FORMAT;
        len = be(p->data + pos, bytes); pos += bytes;
    }
    size_t bytes = 0;
    switch (type) {
    case 0: if (low != 0 && low != 8 && low != 9) return BRIDGE_E_UNSUPPORTED; len = 0; break;
    case 1: if (low > 3) return BRIDGE_E_UNSUPPORTED; len = bytes = (size_t)1 << low; break;
    case 8: if (low > 7) return BRIDGE_E_UNSUPPORTED; len = bytes = (size_t)low + 1; break;
    case 4: case 5:
        if (len > SIZE_MAX) return BRIDGE_E_LIMIT;
        bytes = (size_t)len; break;
    case 6:
        if (len > SIZE_MAX / 2) return BRIDGE_E_LIMIT;
        bytes = (size_t)len * 2; break;
    case 10: case 13: {
        size_t unit = p->ref_width * (type == 13 ? 2u : 1u);
        if (len > BRIDGE_BPLIST_MAX_OBJECTS || len > SIZE_MAX / unit) return BRIDGE_E_LIMIT;
        bytes = (size_t)len * unit;
        break;
    }
    default: return BRIDGE_E_UNSUPPORTED;
    }
    if (!within(pos, bytes, p->table)) return BRIDGE_E_FORMAT;
    if (type == 10 || type == 13) {
        for (size_t i = 0; i < bytes; i += p->ref_width)
            if (be(p->data + pos + i, p->ref_width) >= p->count) return BRIDGE_E_FORMAT;
    }
    *out = (bridge_bplist_value){type, low, p->data + pos, (size_t)len};
    return BRIDGE_OK;
}
bridge_status bridge_bplist_uint(const bridge_bplist *p, uint64_t ref, uint64_t *out) {
    if (!out) return BRIDGE_E_ARGUMENT;
    bridge_bplist_value v;
    bridge_status s = bridge_bplist_get(p, ref, &v);
    if (s != BRIDGE_OK) return s;
    if (v.type != 1 && v.type != 8) return BRIDGE_E_TYPE;
    if (v.type == 1 && v.length == 8 && (v.payload[0] & 0x80u)) return BRIDGE_E_TYPE;
    *out = be(v.payload, (uint8_t)v.length); return BRIDGE_OK;
}
bridge_status bridge_bplist_array_at(const bridge_bplist *p, uint64_t ref, size_t i, uint64_t *out) {
    if (!out) return BRIDGE_E_ARGUMENT;
    bridge_bplist_value v;
    bridge_status s = bridge_bplist_get(p, ref, &v);
    if (s != BRIDGE_OK) return s;
    if (v.type != 10) return BRIDGE_E_TYPE;
    if (i >= v.length) return BRIDGE_E_NOT_FOUND;
    *out = be(v.payload + i * p->ref_width, p->ref_width); return BRIDGE_OK;
}
bridge_status bridge_bplist_dict_find(const bridge_bplist *p, uint64_t ref, const char *key, uint64_t *out) {
    if (!out || !key) return BRIDGE_E_ARGUMENT;
    bridge_bplist_value v;
    bridge_status s = bridge_bplist_get(p, ref, &v);
    if (s != BRIDGE_OK) return s;
    if (v.type != 13) return BRIDGE_E_TYPE;
    size_t n = strlen(key);
    for (size_t i = 0; i < v.length; ++i) {
        uint64_t kr = be(v.payload + i * p->ref_width, p->ref_width);
        bridge_bplist_value k;
        s = bridge_bplist_get(p, kr, &k);
        if (s != BRIDGE_OK) return s;
        if (k.type != 5) return BRIDGE_E_TYPE;
        if (k.length == n && !memcmp(k.payload, key, n)) {
            *out = be(v.payload + (v.length + i) * p->ref_width, p->ref_width);
            return BRIDGE_OK;
        }
    }
    return BRIDGE_E_NOT_FOUND;
}
