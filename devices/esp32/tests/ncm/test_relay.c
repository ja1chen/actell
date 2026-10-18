/* SPDX-License-Identifier: GPL-3.0-or-later: no device sockets. */
#include "nd_relay.h"
#include <assert.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
static void exact(int fd,void *data,size_t size,bool writing) { size_t done=0;while(done<size){ssize_t n=writing?send(fd,(char *)data+done,size-done,0):recv(fd,(char *)data+done,size-done,0);assert(n>0);done+=(size_t)n;} }
static int listener(uint16_t *port) { int fd=socket(AF_INET,SOCK_STREAM,0);assert(fd>=0);struct sockaddr_in addr={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};assert(!bind(fd,(void *)&addr,sizeof addr));assert(!listen(fd,4));socklen_t n=sizeof addr;assert(!getsockname(fd,(void *)&addr,&n));*port=ntohs(addr.sin_port);return fd; }
static void no_signal(int fd){int one=1;assert(!setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof one));}
typedef struct { nd_relay_job job;int fd;nd_relay_stats stats;bridge_status result; } worker;
static void *run(void *ctx){worker *w=ctx;w->result=nd_relay_run(&w->job,w->fd,&w->stats);return NULL;}
static void start(nd_relay *s,nd_server *catalog,nd_link *link,const char *line,worker *w,int *client,int *peer,pthread_t *thread,int server){
    assert(nd_relay_prepare(s,catalog,link,line,&w->job)==BRIDGE_OK);int pair[2];assert(!socketpair(AF_UNIX,SOCK_STREAM,0,pair));no_signal(pair[0]);no_signal(pair[1]);w->fd=pair[0];*client=pair[1];assert(!pthread_create(thread,NULL,run,w));*peer=accept(server,NULL,NULL);assert(*peer>=0);no_signal(*peer);char ack[7];exact(*client,ack,sizeof ack,false);assert(!memcmp(ack,"NR1 OK\n",7));
}
typedef struct { int fd;size_t size;uint8_t seed; } bytes;
static void *produce(void *ctx){bytes *b=ctx;uint8_t block[8192];for(size_t i=0;i<sizeof block;i++)block[i]=(uint8_t)(i+b->seed);for(size_t n=0;n<b->size;n+=sizeof block)exact(b->fd,block,sizeof block,true);return NULL;}
static void consume(int fd,size_t size,uint8_t seed){uint8_t block[8192];for(size_t n=0;n<size;n+=sizeof block){exact(fd,block,sizeof block,false);for(size_t i=0;i<sizeof block;i++)assert(block[i]==(uint8_t)(i+seed));}}
int main(void){
    uint16_t port;int server=listener(&port);nd_server catalog={.generation=7,.count=1,.expires=UINT64_MAX};catalog.endpoints[0]=(nd_endpoint){.service=ND_REMOTE_PAIRING,.family=4,.port=port,.address={127,0,0,1}};
    nd_link link={.local4={127,0,0,1},.peer4={127,0,0,1},.interface_index=if_nametoindex("lo0")};assert(link.interface_index);
    const char *nonce="0123456789abcdef0123456789abcdef";char open[96],tunnel[96],cancel[96];snprintf(open,sizeof open,"NR1 OPEN 7 0 %s",nonce);snprintf(tunnel,sizeof tunnel,"NR1 TUNNEL %s %u",nonce,port);snprintf(cancel,sizeof cancel,"NR1 CANCEL %s",nonce);
    nd_relay a={0},other={0};worker control={0},data={0},isolated={0};nd_relay_job rejected={0};int c,p,d,q,o,r;pthread_t ct,dt,ot;
    nd_relay locked={0};nd_relay_job fixed={0};
    assert(nd_relay_prepare(&locked,&catalog,&link,"NL1 OPEN 0123456789abcdef0123456789abcdef",&fixed)==BRIDGE_OK);
    assert(fixed.target.service==ND_LOCKDOWN && fixed.target.family==4 && fixed.target.port==62078 && !memcmp(fixed.target.address,link.peer4,4));
    atomic_store(&locked.control_ready,true);
    assert(nd_relay_prepare(&locked,&catalog,&link,tunnel,&rejected)==BRIDGE_E_NOT_FOUND);
    assert(nd_relay_prepare(&locked,&catalog,&link,cancel,&rejected)==BRIDGE_E_NOT_FOUND);
    assert(nd_relay_prepare(&locked,&catalog,&link,"NL1 CANCEL 0123456789abcdef0123456789abcdef",&rejected)==BRIDGE_OK);
    nd_relay_abandon(&fixed);assert(!nd_relay_busy(&locked));
    assert(nd_relay_prepare(&a,&catalog,&link,tunnel,&rejected)==BRIDGE_E_NOT_FOUND);
    assert(nd_relay_prepare(&a,&catalog,&link,"NR1 OPEN 6 0 0123456789abcdef0123456789abcdef",&rejected)==BRIDGE_E_NOT_FOUND);
    start(&a,&catalog,&link,open,&control,&c,&p,&ct,server);
    assert(nd_relay_prepare(&a,&catalog,&link,open,&rejected)==BRIDGE_E_LIMIT);
    assert(nd_relay_prepare(&a,&catalog,&link,"NR1 TUNNEL ffffffffffffffffffffffffffffffff 1234",&rejected)==BRIDGE_E_NOT_FOUND);
    start(&a,&catalog,&link,tunnel,&data,&d,&q,&dt,server);
    assert(nd_relay_prepare(&a,&catalog,&link,tunnel,&rejected)==BRIDGE_E_LIMIT);
    start(&other,&catalog,&link,open,&isolated,&o,&r,&ot,server);
    const size_t size=1024*1024;bytes forward={d,size,11},reverse={q,size,97};pthread_t fw,rw;assert(!pthread_create(&fw,NULL,produce,&forward));assert(!pthread_create(&rw,NULL,produce,&reverse));
    // Delay consumption until kernel windows and relay slabs exert backpressure.
    struct timespec pause={.tv_nsec=80000000};nanosleep(&pause,NULL);
    consume(q,size,11);consume(d,size,97);pthread_join(fw,NULL);pthread_join(rw,NULL);
    assert(nd_relay_prepare(&a,&catalog,&link,cancel,&rejected)==BRIDGE_OK);pthread_join(ct,NULL);pthread_join(dt,NULL);
    assert(control.result==BRIDGE_E_EOF && data.result==BRIDGE_E_EOF);assert(data.stats.to_peer==size && data.stats.to_client==size);assert(data.stats.peak_buffered<=2*ND_RELAY_BUFFER);assert(!nd_relay_busy(&a));
    char payload[]="other session still live",got[sizeof payload];exact(o,payload,sizeof payload,true);exact(r,got,sizeof got,false);assert(!memcmp(got,payload,sizeof got));assert(!atomic_load(&other.cancelled));
    close(o);pthread_join(ot,NULL);assert(atomic_load(&other.cancelled));assert(!nd_relay_busy(&other));
    close(c);close(p);close(d);close(q);close(r);close(server);
    puts("Relay: bounded bidirectional 1MiB streams, blocked-consumer backpressure, two channels, cancel fanout, independent sessions, stale/wrong nonce and duplicate rejection passed");
}
