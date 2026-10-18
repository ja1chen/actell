/* SPDX-License-Identifier: GPL-3.0-or-later. Loopback-only synthetic server. */
#include "nd_server.h"
#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <net/if.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
typedef struct { int listener; int mode; } peer;
static const char greeting[]="{\"originatedBy\":\"device\",\"sequenceNumber\":0,\"message\":{\"plain\":{\"_0\":{\"response\":{\"_1\":{\"handshake\":{\"_0\":{\"wireProtocolVersion\":26}}}}}}}}";
static void exact(int fd,void *p,size_t n,bool sending) { while(n){ssize_t r=sending?send(fd,p,n,0):recv(fd,p,n,0);assert(r>0);p=(char *)p+r;n-=(size_t)r;} }
static void *respond(void *context) {
    peer *p=context;int fd=accept(p->listener,NULL,NULL);assert(fd>=0);
    if(p->mode==2) { char ignored[512]; while(recv(fd,ignored,sizeof ignored,0)>0){} close(fd);return NULL; }
    uint8_t header[11];exact(fd,header,11,false);assert(!memcmp(header,"RPPairing",9));
    size_t n=((size_t)header[9]<<8)|header[10];char request[1024]={0};assert(n<sizeof request);exact(fd,request,n,false);
    assert(strstr(request,"attemptPairVerify") && !strstr(request,"pairingData"));
    if(p->mode==1) { close(fd);return NULL; }
    n=strlen(greeting);header[9]=(uint8_t)(n>>8);header[10]=(uint8_t)n;
    for(size_t i=0;i<11;i++) exact(fd,header+i,1,true);
    for(size_t i=0;i<n;i++) exact(fd,(void *)(greeting+i),1,true);
    close(fd);return NULL;
}
static uint16_t listener(peer *p) {
    p->listener=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);assert(p->listener>=0);
    struct sockaddr_in a={.sin_family=AF_INET};inet_pton(AF_INET,"127.0.0.1",&a.sin_addr);
    if(bind(p->listener,(void *)&a,sizeof a)) { perror("loopback bind");assert(false); }
    assert(!listen(p->listener,1));socklen_t n=sizeof a;assert(!getsockname(p->listener,(void *)&a,&n));return ntohs(a.sin_port);
}
int main(void) {
    nd_link link={.local4={127,0,0,1},.peer4={127,0,0,1},.interface_index=if_nametoindex("lo0")};assert(link.interface_index);
    for(int mode=0;mode<=2;mode++) {
        peer p={.mode=mode};nd_endpoint e={.service=ND_REMOTE_PAIRING,.family=4,.address={127,0,0,1},.port=listener(&p)};
        pthread_t thread;assert(!pthread_create(&thread,NULL,respond,&p));
        if(mode<2) {
            nd_server server={.count=1,.generation=33,.expires=UINT64_MAX};server.endpoints[0]=e;char reply[4096];
            assert(nd_server_command(&server,&link,"PROBE 33 0",reply,sizeof reply)==BRIDGE_OK);
            assert(strstr(reply,"\"tcpConnected\":true") && strstr(reply,"\"authenticated\":false"));
            if (!strstr(reply,mode==0?"\"wireVersion\":26":"\"result\":\"eof\"")) fprintf(stderr,"synthetic mode=%d result=%s",mode,reply);
            assert(strstr(reply,mode==0?"\"wireVersion\":26":"\"result\":\"eof\""));
        } else {
            nd_socket s;assert(nd_socket_connect(&s,&link,&e,nd_now(NULL)+300)==BRIDGE_OK);
            bridge_io io=nd_socket_io(&s);uint8_t scratch[16385];uint32_t v=0;uint64_t before=nd_now(NULL);
            assert(nd_pairing_greeting(&io,scratch,sizeof scratch,before+80,&v)==BRIDGE_E_TIMEOUT);
            assert(nd_now(NULL)-before<500);nd_socket_close(&s);
        }
        assert(!pthread_join(thread,NULL));close(p.listener);
    }
    nd_socket s;nd_endpoint wrong={.family=4,.address={192,168,7,2},.port=62078};
    assert(nd_socket_connect(&s,&link,&wrong,nd_now(NULL)+100)==BRIDGE_E_ARGUMENT);
    puts("Loopback-only TCP: actual source binding, fragmented greeting, EOF vs TCP success, absolute timeout, target rejection passed");
}
