/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bridge_core.h"
#include "bridge_bplist.h"
#include "fixtures.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

typedef struct {
    uint8_t data[2048]; size_t size, pos, step; uint64_t now;
    int fail; bool oversize; uint64_t *sink_clock;
} fake_io;
static ptrdiff_t rd(void *c, uint8_t *b, size_t n, uint32_t timeout) {
    fake_io *f = c; assert(timeout); f->now++;
    if (f->fail) return -(ptrdiff_t)f->fail;
    if (f->oversize) return (ptrdiff_t)n + 1;
    if (n > f->step) n = f->step;
    if (n > f->size - f->pos) n = f->size - f->pos;
    memcpy(b, f->data + f->pos, n); f->pos += n; return (ptrdiff_t)n;
}
static ptrdiff_t wr(void *c, const uint8_t *b, size_t n, uint32_t timeout) {
    fake_io *f = c; assert(timeout); f->now++;
    if (f->fail) return -(ptrdiff_t)f->fail;
    if (f->oversize) return (ptrdiff_t)n + 1;
    if (n > f->step) n = f->step;
    if (n > sizeof f->data - f->size) return -BRIDGE_E_IO;
    memcpy(f->data + f->size, b, n); f->size += n; return (ptrdiff_t)n;
}
static uint64_t clk(void *c) { return ((fake_io *)c)->now; }
static bridge_status sink(void *c, const uint8_t *b, size_t n) {
    fake_io *f = c;
    if (f->fail) return (bridge_status)f->fail;
    if (f->sink_clock) *f->sink_clock += 100;
    assert(n <= f->step); assert(f->size + n <= sizeof f->data);
    memcpy(f->data + f->size, b, n); f->size += n; return BRIDGE_OK;
}
static void test_io(void) {
    for (size_t step = 1; step <= 23; ++step) {
        fake_io f = {.step = step}, o = {.step = 7}; bridge_io io = {&f, rd, wr, clk};
        assert(bridge_plist_send(&io, screenshot_reply, sizeof screenshot_reply, 2048, 10000) == BRIDGE_OK);
        assert(f.size == sizeof screenshot_reply + 4); uint8_t scratch[7]; uint32_t size = 99;
        assert(bridge_plist_recv(&io, 2048, scratch, sizeof scratch, sink, &o, 10000, &size) == BRIDGE_OK);
        assert(size == sizeof screenshot_reply); assert(o.size == size);
        assert(!memcmp(o.data, screenshot_reply, size));
    }
    fake_io f = {.step = 1, .data = {0, 0, 1, 0}, .size = 4}, o = {.step = 8};
    bridge_io io = {&f, rd, wr, clk}; uint8_t scratch[8]; uint32_t size;
    assert(bridge_plist_recv(&io, 255, scratch, 8, sink, &o, 999, &size) == BRIDGE_E_LIMIT);
    assert(size == 0 && f.pos == 4 && o.size == 0);
    f.pos = 0; assert(bridge_plist_recv(&io, 256, scratch, 8, sink, &o, 999, &size) == BRIDGE_E_EOF);
    f.pos = 0; f.now = 0; assert(bridge_plist_recv(&io, 256, scratch, 8, sink, &o, 2, &size) == BRIDGE_E_TIMEOUT);
    f.pos = 0; f.now = 0; memset(f.data, 0, 4);
    assert(bridge_plist_recv(&io, 256, scratch, 8, sink, &o, 999, &size) == BRIDGE_E_FORMAT);
    f.fail = BRIDGE_E_TIMEOUT; assert(bridge_read_exact(&io, scratch, 1, 999) == BRIDGE_E_TIMEOUT);
    f.fail = BRIDGE_E_IO; assert(bridge_read_exact(&io, scratch, 1, 999) == BRIDGE_E_IO);
    f.fail = 0; f.oversize = true; assert(bridge_read_exact(&io, scratch, 1, 999) == BRIDGE_E_IO);
    assert(bridge_write_exact(&io, scratch, 1, 999) == BRIDGE_E_IO);
    f.oversize = false; f.fail = BRIDGE_E_TIMEOUT;
    assert(bridge_write_exact(&io, scratch, 1, 999) == BRIDGE_E_TIMEOUT);
    f.fail = 0;
    assert(bridge_read_exact(NULL, scratch, 1, 999) == BRIDGE_E_ARGUMENT);
    assert(bridge_plist_send(&io, screenshot_reply, sizeof screenshot_reply, 2, 999) == BRIDGE_E_LIMIT);
    f.oversize = false; f.size = f.pos = f.now = 0; f.step = 1024;
    assert(bridge_plist_send(&io, screenshot_reply, sizeof screenshot_reply, 2048, 999) == BRIDGE_OK);
    o.fail = BRIDGE_E_IO;
    assert(bridge_plist_recv(&io, 2048, scratch, 8, sink, &o, 999, &size) == BRIDGE_E_IO && size == 0);
    f.pos = 0; f.now = 0; o.fail = 0; o.size = 0; o.step = sizeof o.data; o.sink_clock = &f.now;
    assert(bridge_plist_recv(&io, 2048, scratch, 8, sink, &o, 10, &size) == BRIDGE_E_TIMEOUT && size == 0);
    f.now = 0; f.pos = 0;
    assert(bridge_read_exact(&io, scratch, 1, 1) == BRIDGE_E_TIMEOUT);
}
static void test_plist(void) {
    bridge_bplist p; bridge_bplist_value v; uint64_t r, d, n;
    assert(bridge_bplist_open(&p, screenshot_reply, sizeof screenshot_reply) == BRIDGE_OK);
    assert(bridge_bplist_array_at(&p, p.root, 1, &d) == BRIDGE_OK);
    assert(bridge_bplist_dict_find(&p, d, "ScreenShotData", &r) == BRIDGE_OK);
    assert(bridge_bplist_get(&p, r, &v) == BRIDGE_OK && v.type == 4);
    static const uint8_t expected[] = "NOT A REAL PNG\0\xff";
    assert(v.length == sizeof expected - 1 && !memcmp(v.payload, expected, v.length));
    assert(bridge_bplist_dict_find(&p, d, "missing", &r) == BRIDGE_E_NOT_FOUND);
    assert(bridge_bplist_array_at(&p, p.root, 100, &r) == BRIDGE_E_NOT_FOUND);
    assert(bridge_bplist_get(&p, p.count, &v) == BRIDGE_E_FORMAT);
    assert(bridge_bplist_dict_find(&p, p.root, "x", &r) == BRIDGE_E_TYPE);
    assert(bridge_bplist_open(&p, metadata, sizeof metadata) == BRIDGE_OK);
    assert(bridge_bplist_dict_find(&p, p.root, "Width", &r) == BRIDGE_OK);
    assert(bridge_bplist_uint(&p, r, &n) == BRIDGE_OK && n == 1170);
    assert(bridge_bplist_dict_find(&p, p.root, "UID", &r) == BRIDGE_OK);
    assert(bridge_bplist_uint(&p, r, &n) == BRIDGE_OK && n == 300);
    assert(bridge_bplist_dict_find(&p, p.root, "Long", &r) == BRIDGE_OK);
    assert(bridge_bplist_get(&p, r, &v) == BRIDGE_OK && v.length == 300 && v.type == 5);
    assert(bridge_bplist_dict_find(&p, p.root, "Unicode", &r) == BRIDGE_OK);
    assert(bridge_bplist_get(&p, r, &v) == BRIDGE_OK && v.length == 2 && v.type == 6);
    assert(bridge_bplist_dict_find(&p, p.root, "Negative", &r) == BRIDGE_OK);
    assert(bridge_bplist_uint(&p, r, &n) == BRIDGE_E_TYPE);
    assert(bridge_bplist_dict_find(&p, p.root, "True", &r) == BRIDGE_OK);
    assert(bridge_bplist_get(&p, r, &v) == BRIDGE_OK && v.type == 0 && v.subtype == 9);
    assert(bridge_bplist_dict_find(&p, p.root, "False", &r) == BRIDGE_OK);
    assert(bridge_bplist_get(&p, r, &v) == BRIDGE_OK && v.type == 0 && v.subtype == 8);
    assert(bridge_bplist_dict_find(&p, p.root, "Null", &r) == BRIDGE_OK);
    assert(bridge_bplist_get(&p, r, &v) == BRIDGE_OK && v.type == 0 && v.subtype == 0);
    for (size_t i = 0; i < sizeof metadata; ++i)
        assert(bridge_bplist_open(&p, metadata, i) != BRIDGE_OK);
    uint8_t bad[sizeof metadata]; memcpy(bad, metadata, sizeof bad);
    memset(bad + sizeof bad - 24, 255, 8);
    assert(bridge_bplist_open(&p, bad, sizeof bad) != BRIDGE_OK);
}
static uint32_t random_state = 0x47657374;
static uint32_t rnd(void) { random_state ^= random_state << 13; random_state ^= random_state >> 17; random_state ^= random_state << 5; return random_state; }
static void mutate(void) {
    uint8_t data[sizeof metadata];
    for (unsigned run = 0; run < 20000; ++run) {
        memcpy(data, metadata, sizeof data);
        for (unsigned i = 0, count = 1 + rnd() % 12; i < count; ++i) data[rnd() % sizeof data] = (uint8_t)rnd();
        bridge_bplist p;
        if (bridge_bplist_open(&p, data, sizeof data) == BRIDGE_OK) {
            for (uint64_t r = 0; r < p.count; ++r) {
                bridge_bplist_value v; uint64_t x;
                (void)bridge_bplist_get(&p, r, &v);
                (void)bridge_bplist_uint(&p, r, &x);
                (void)bridge_bplist_array_at(&p, r, rnd() % 5000, &x);
                (void)bridge_bplist_dict_find(&p, r, "Width", &x);
            }
        }
    }
}
int main(void) { test_io(); test_plist(); mutate(); puts("PASS: fragmented I/O, deadlines, bounded framing, plist fixtures, 20000 deterministic malformed-plist mutations"); return 0; }
