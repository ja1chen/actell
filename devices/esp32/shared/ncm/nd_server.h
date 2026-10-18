/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include "nd_socket.h"
#define ND_REPLY_LIMIT 4096
#define ND_COMMAND_LIMIT 64
/* One command per connection, one caller. No action/pairing command exists. */
typedef struct {
    nd_catalog catalog;
    nd_endpoint endpoints[ND_ENDPOINTS];
    size_t count;
    uint32_t generation;
    uint64_t expires;
} nd_server;
void nd_server_reset(nd_server *);
bridge_status nd_server_command(nd_server *, const nd_link *, const char *, char *, size_t);
