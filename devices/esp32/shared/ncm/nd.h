/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include "bridge_core.h"
#define ND_RECORDS 24
#define ND_ENDPOINTS 16
#define ND_NAME 256
#define ND_DNS_LIMIT 4096
#define ND_GREETING_LIMIT 16384
/* Discovery is unauthenticated. Names/TXT/peer JSON never leave this module. */
typedef enum { ND_REMOTE_PAIRING=1, ND_LOCKDOWN=2, ND_PAIRABLE_HOST=3 } nd_service;
typedef struct { char name[ND_NAME], target[ND_NAME]; uint16_t type, port; uint8_t address[16]; } nd_record;
typedef struct { nd_record records[ND_RECORDS]; size_t count; uint64_t expires; } nd_catalog;
typedef struct { nd_service service; int family; uint8_t address[16]; uint16_t port; } nd_endpoint;
const char *nd_service_name(nd_service service);
size_t nd_dns_question(const char *name, uint16_t type, uint8_t *out, size_t capacity);
size_t nd_dns_query(nd_service service, uint8_t *out, size_t capacity);
/* All-or-nothing datagram parsing; DNS compression loops and truncation fail.
 * Snapshot only: caller clears at each discovery, expires it within 5 seconds,
 * and invalidates it on USB epoch changes. No TXT retention. */
bridge_status nd_dns_ingest(nd_catalog *, const uint8_t *, size_t, uint64_t now_ms);
size_t nd_dns_endpoints(const nd_catalog *, const uint8_t peer4[4], nd_endpoint *, size_t);
/* Protocol greeting ONLY. Does not Pair Setup/Verify or generate an identity.
 * Reply storage wiped, result contains only a version. Caller closes stream. */
bridge_status nd_pairing_greeting(bridge_io *, uint8_t *scratch, size_t capacity,
    uint64_t deadline, uint32_t *wire_version);
