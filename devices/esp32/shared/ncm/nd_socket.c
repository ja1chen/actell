/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "nd_socket.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#ifdef ESP_PLATFORM
#include "esp_timer.h"
#else
#include <arpa/inet.h>
#include <sys/select.h>
#include <time.h>
#endif
uint64_t nd_now(void *unused) {
    (void)unused;
#ifdef ESP_PLATFORM
    return (uint64_t)esp_timer_get_time()/1000;
#else
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts); return (uint64_t)ts.tv_sec*1000+(uint64_t)ts.tv_nsec/1000000;
#endif
}
static bridge_status wait_fd(nd_socket *s,bool writing,uint64_t deadline) {
    while (nd_now(NULL)<deadline) {
        if (s->link->alive && !s->link->alive(s->link->context)) return BRIDGE_E_EOF;
        uint64_t now=nd_now(NULL); if (now>=deadline) break;
        uint64_t left=deadline-now; if (left>50) left=50;
        struct timeval tv={.tv_sec=0,.tv_usec=(int)left*1000}; fd_set set; FD_ZERO(&set); FD_SET(s->fd,&set);
        int r=select(s->fd+1,writing?NULL:&set,writing?&set:NULL,NULL,&tv);
        if (r>0) return BRIDGE_OK;
        if (r<0 && errno!=EINTR) { s->error=errno; return BRIDGE_E_IO; }
    }
    return BRIDGE_E_TIMEOUT;
}
static ptrdiff_t transfer(nd_socket *s,void *data,size_t size,uint32_t timeout,bool writing) {
    uint64_t end=nd_now(NULL)+timeout;
    for (;;) {
        bridge_status r=wait_fd(s,writing,end); if (r!=BRIDGE_OK) return -(ptrdiff_t)r;
        ssize_t n=writing?send(s->fd,data,size,0):recv(s->fd,data,size,0);
        if (n>=0) return n;
        if (errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR) { s->error=errno; return -BRIDGE_E_IO; }
    }
}
static ptrdiff_t read_io(void *s,uint8_t *p,size_t n,uint32_t ms) { return transfer(s,p,n,ms,false); }
static ptrdiff_t write_io(void *s,const uint8_t *p,size_t n,uint32_t ms) { return transfer(s,(void *)p,n,ms,true); }
bridge_io nd_socket_io(nd_socket *s) { return (bridge_io){.context=s,.read=read_io,.write=write_io,.clock_ms=nd_now}; }
void nd_socket_close(nd_socket *s) { if (s->fd>=0) { close(s->fd); s->fd=-1; } }
bridge_status nd_socket_connect(nd_socket *s,const nd_link *link,const nd_endpoint *e,uint64_t deadline) {
    *s=(nd_socket){.fd=-1,.link=link};
    if (!link || !e || !e->port || !link->interface_index || (e->family!=4 && e->family!=6)) return BRIDGE_E_ARGUMENT;
    if ((e->family==4 && memcmp(e->address,link->peer4,4)) ||
        (e->family==6 && (e->address[0]!=0xfe || (e->address[1]&0xc0)!=0x80))) return BRIDGE_E_ARGUMENT;
    int family=e->family==4?AF_INET:AF_INET6;
    s->fd=socket(family,SOCK_STREAM,IPPROTO_TCP); if (s->fd<0) { s->error=errno; return BRIDGE_E_IO; }
    if (fcntl(s->fd,F_SETFL,O_NONBLOCK)<0) goto failed;
#ifdef __APPLE__
    int yes=1; if (setsockopt(s->fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof yes)<0) goto failed;
    if (setsockopt(s->fd,family==AF_INET?IPPROTO_IP:IPPROTO_IPV6,family==AF_INET?IP_BOUND_IF:IPV6_BOUND_IF,&link->interface_index,sizeof link->interface_index)<0) goto failed;
#endif
    int r;
    if (family==AF_INET) {
        struct sockaddr_in local={.sin_family=AF_INET},peer={.sin_family=AF_INET,.sin_port=htons(e->port)};
        memcpy(&local.sin_addr,link->local4,4); memcpy(&peer.sin_addr,e->address,4);
        if (bind(s->fd,(struct sockaddr *)&local,sizeof local)) goto failed;
        r=connect(s->fd,(struct sockaddr *)&peer,sizeof peer);
    } else {
        struct sockaddr_in6 peer={.sin6_family=AF_INET6,.sin6_port=htons(e->port),.sin6_scope_id=link->interface_index};
        memcpy(&peer.sin6_addr,e->address,16); r=connect(s->fd,(struct sockaddr *)&peer,sizeof peer);
    }
    if (r<0 && errno!=EINPROGRESS) goto failed;
    if (r<0) {
        bridge_status result=wait_fd(s,true,deadline); if (result!=BRIDGE_OK) { nd_socket_close(s); return result; }
        int error=0; socklen_t size=sizeof error;
        if (getsockopt(s->fd,SOL_SOCKET,SO_ERROR,&error,&size)<0) goto failed;
        if (error) { errno=error; goto failed; }
    }
    return BRIDGE_OK;
failed:
    s->error=errno; nd_socket_close(s); return BRIDGE_E_IO;
}
bridge_status nd_discover(const nd_link *link,int family,nd_catalog *catalog,uint64_t deadline,int *os_error) {
    if (os_error) *os_error=0;
    if (!link || !catalog || !link->interface_index || (family!=4 && family!=6)) return BRIDGE_E_ARGUMENT;
    memset(catalog,0,sizeof *catalog);
    nd_socket s={.fd=socket(family==4?AF_INET:AF_INET6,SOCK_DGRAM,IPPROTO_UDP),.link=link};
    if (s.fd<0) { if (os_error) *os_error=errno; return BRIDGE_E_IO; }
    bridge_status result=BRIDGE_E_IO; int yes=1;
    struct sockaddr_storage dest={0}; socklen_t dest_size;
    if (setsockopt(s.fd,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof yes) || fcntl(s.fd,F_SETFL,O_NONBLOCK)<0) goto done;
    if (family==4) {
        struct sockaddr_in local={.sin_family=AF_INET,.sin_port=htons(5353)};
        /* A multicast listener binds ANY: explicit membership, outgoing IF and
         * source filtering keep it on NCM. Never made a default interface. */
        struct ip_mreq membership={0}; memcpy(&membership.imr_interface,link->local4,4);
        inet_pton(AF_INET,"224.0.0.251",&membership.imr_multiaddr);
        int ttl=255;
        if (bind(s.fd,(struct sockaddr *)&local,sizeof local) ||
            setsockopt(s.fd,IPPROTO_IP,IP_MULTICAST_IF,&membership.imr_interface,sizeof membership.imr_interface) ||
            setsockopt(s.fd,IPPROTO_IP,IP_MULTICAST_TTL,&ttl,sizeof ttl) ||
            setsockopt(s.fd,IPPROTO_IP,IP_ADD_MEMBERSHIP,&membership,sizeof membership)) goto done;
        struct sockaddr_in *d=(void *)&dest; d->sin_family=AF_INET; d->sin_port=htons(5353); d->sin_addr=membership.imr_multiaddr; dest_size=sizeof *d;
    } else {
        struct sockaddr_in6 local={.sin6_family=AF_INET6,.sin6_port=htons(5353)};
        struct ipv6_mreq membership={.ipv6mr_interface=link->interface_index}; inet_pton(AF_INET6,"ff02::fb",&membership.ipv6mr_multiaddr);
        int ttl=255;
        if (bind(s.fd,(struct sockaddr *)&local,sizeof local) ||
            setsockopt(s.fd,IPPROTO_IPV6,IPV6_MULTICAST_IF,&link->interface_index,sizeof link->interface_index) ||
            setsockopt(s.fd,IPPROTO_IPV6,IPV6_MULTICAST_HOPS,&ttl,sizeof ttl) ||
            setsockopt(s.fd,IPPROTO_IPV6,IPV6_JOIN_GROUP,&membership,sizeof membership)) goto done;
        struct sockaddr_in6 *d=(void *)&dest; d->sin6_family=AF_INET6; d->sin6_port=htons(5353); d->sin6_scope_id=link->interface_index; d->sin6_addr=membership.ipv6mr_multiaddr; dest_size=sizeof *d;
    }
    uint8_t packet[ND_DNS_LIMIT];
    for (int kind=1;kind<=3;kind++) { size_t n=nd_dns_query((nd_service)kind,packet,sizeof packet);
        if (sendto(s.fd,packet,n,0,(struct sockaddr *)&dest,dest_size)!=(ssize_t)n) goto done; }
    result=BRIDGE_OK; uint64_t followup=nd_now(NULL)+900;
    while (nd_now(NULL)<deadline) {
        bridge_status ready=wait_fd(&s,false,followup<deadline?followup:deadline);
        if (ready==BRIDGE_E_TIMEOUT) {
            if (nd_now(NULL)>=deadline) break;
            /* PTR-only replies need SRV; a later SRV may need A/AAAA. Repeat
             * bounded follow-ups, allowing records to arrive in separate packets. */
            for (size_t i=0;i<catalog->count;i++) {
                const nd_record *r=&catalog->records[i];
                if (r->type!=12 && r->type!=33) continue;
                size_t count=r->type==12?1:2;
                for (size_t q=0;q<count;q++) {
                    size_t n=nd_dns_question(r->target,r->type==12?33:(q?28:1),packet,sizeof packet);
                    if (!n || sendto(s.fd,packet,n,0,(struct sockaddr *)&dest,dest_size)!=(ssize_t)n) { result=BRIDGE_E_IO; goto done; }
                }
            }
            followup=nd_now(NULL)+900; continue;
        }
        if (ready!=BRIDGE_OK) { result=ready; break; }
        struct sockaddr_storage peer={0}; socklen_t peer_size=sizeof peer;
        ssize_t n=recvfrom(s.fd,packet,sizeof packet,0,(struct sockaddr *)&peer,&peer_size);
        if (n<0) { if (errno==EAGAIN || errno==EINTR) continue; result=BRIDGE_E_IO; break; }
        bool accepted=false;
        if (family==4 && peer.ss_family==AF_INET) { struct sockaddr_in *p=(void *)&peer; accepted=p->sin_port==htons(5353) && !memcmp(&p->sin_addr,link->peer4,4); }
        if (family==6 && peer.ss_family==AF_INET6) { struct sockaddr_in6 *p=(void *)&peer; const uint8_t *a=(void *)&p->sin6_addr;
            accepted=p->sin6_port==htons(5353) && p->sin6_scope_id==link->interface_index && a[0]==0xfe && (a[1]&0xc0)==0x80; }
        if (accepted && n>=12 && (packet[2]&0x80)) { result=nd_dns_ingest(catalog,packet,(size_t)n,nd_now(NULL)); if (result!=BRIDGE_OK) break; }
    }
done:
    if (result==BRIDGE_E_IO && os_error) *os_error=s.error?s.error:errno;
    nd_socket_close(&s); if (result!=BRIDGE_OK) memset(catalog,0,sizeof *catalog); return result;
}
