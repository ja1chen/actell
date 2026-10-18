#pragma once
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
// Test-only port binding is loopback. Production main still binds 192.168.7.1.
static inline int test_inet_pton(int family,const char *source,void *out) {
    (void)source; return inet_pton(family,"127.0.0.1",out);
}
#define inet_pton test_inet_pton

#include <stdlib.h>
static inline int test_bind(int fd,const struct sockaddr *address,socklen_t length) {
    struct sockaddr_in local=*(const struct sockaddr_in *)address;
    const char *port=getenv("PA_TEST_PORT");
    if (port) local.sin_port=htons((uint16_t)atoi(port));
    return bind(fd,(const struct sockaddr *)&local,length);
}
#define bind test_bind
