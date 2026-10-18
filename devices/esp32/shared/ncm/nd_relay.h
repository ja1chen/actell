/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include "nd_server.h"
#include <stdatomic.h>
#define ND_RELAY_LINE_LIMIT 96
#define ND_RELAY_BUFFER 2048
/* Owner/dispatcher alone prepares/reaps. Workers only mutate atomic fields.
 * At most two streams per instance, to one pinned discovered RP target. */
typedef struct {
    bool claimed;
    bool lockdown;
    char nonce[33];
    nd_endpoint target;
    nd_link base;
    unsigned started;
    atomic_uint done;
    atomic_bool cancelled,control_ready;
    atomic_uint_least32_t last_io_ms;
} nd_relay;
typedef struct { nd_relay *session; nd_link link; nd_endpoint target; unsigned bit; } nd_relay_job;
typedef struct { size_t peak_buffered; uint64_t to_peer,to_client; } nd_relay_stats;
/* link.context must remain stable until all workers are done. */
bridge_status nd_relay_prepare(nd_relay *,const nd_server *,const nd_link *,const char *,nd_relay_job *);
bool nd_relay_busy(nd_relay *);
void nd_relay_cancel(nd_relay *);
/* Takes ownership of client_fd, including on all failures. No payload logging. */
bridge_status nd_relay_run(nd_relay_job *,int client_fd,nd_relay_stats *);
void nd_relay_abandon(nd_relay_job *);
