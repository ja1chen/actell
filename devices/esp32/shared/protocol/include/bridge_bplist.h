/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_BPLIST_H
#define BRIDGE_BPLIST_H
#include "bridge_core.h"
#define BRIDGE_BPLIST_MAX_OBJECTS 4096u
/* Borrowed zero-copy view: keep the original bytes alive AND immutable; do not
 * modify these view fields. open validates envelope/table; get lazily validates
 * an object. UTF-16 payload is raw big-endian units, not decoded or validated.
 * Never recursively builds a tree, allocates, or follows UIDs automatically. */
typedef struct {
    const uint8_t *data;
    size_t size, table;
    uint64_t count, root;
    uint8_t offset_width, ref_width;
} bridge_bplist;
typedef struct {
    uint8_t type;
    uint8_t subtype; /* original low marker nibble; distinguishes null/false/true */
    const uint8_t *payload;
    size_t length; /* bytes for data/ASCII; units for UTF16; elements for containers */
} bridge_bplist_value;
bridge_status bridge_bplist_open(bridge_bplist *, const uint8_t *, size_t);
bridge_status bridge_bplist_get(const bridge_bplist *, uint64_t ref, bridge_bplist_value *);
/* Only nonnegative plist integers and unsigned UIDs; negative integers return TYPE. */
bridge_status bridge_bplist_uint(const bridge_bplist *, uint64_t ref, uint64_t *);
bridge_status bridge_bplist_array_at(const bridge_bplist *, uint64_t ref, size_t index, uint64_t *out_ref);
/* ASCII dictionary keys only; unsupported key encodings return TYPE, never match. */
bridge_status bridge_bplist_dict_find(const bridge_bplist *, uint64_t ref, const char *key, uint64_t *out_ref);
#endif
