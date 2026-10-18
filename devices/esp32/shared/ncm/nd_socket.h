/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include "nd.h"
#ifdef ESP_PLATFORM
#include "lwip/sockets.h"
#else
#include <sys/socket.h>
#include <netinet/in.h>
#endif
typedef struct {
    uint8_t local4[4],peer4[4];
    uint32_t interface_index;
    bool (*alive)(void *); void *context;
} nd_link;
typedef struct { int fd; const nd_link *link; int error; } nd_socket;
uint64_t nd_now(void *unused);
bridge_status nd_socket_connect(nd_socket *,const nd_link *,const nd_endpoint *,uint64_t deadline);
bridge_io nd_socket_io(nd_socket *);
void nd_socket_close(nd_socket *);
/* Bounded multicast on the selected NCM interface. No default route, no DNS,
 * no radio fallback. family=4/6. Ignores off-link sources, omits TXT entirely. */
bridge_status nd_discover(const nd_link *,int family,nd_catalog *,uint64_t deadline,int *os_error);
