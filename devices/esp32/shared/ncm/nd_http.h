/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include "nd_server.h"
#define ND_HTTP_BODY_LIMIT 8192
/* Per-link random token; never a pairing credential. Rotate on USB reconnect. */
typedef struct { char token[33]; } nd_http;
/* request_line excludes CRLF. GET is idle. POST permits only diagnostics. */
bridge_status nd_http_serve(nd_http *,nd_server *,const nd_link *,bridge_io *,const char *request_line,char *body,size_t capacity,uint64_t deadline);
