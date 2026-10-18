/* SPDX-License-Identifier: GPL-3.0-only. Standalone host TEST fixture only.
 * Real C relay -> loopback synthetic RPPairing peer; no device addresses. */
#include "nd_relay.h"
#include <assert.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int listener(uint16_t *port){int fd=socket(AF_INET,SOCK_STREAM,0);assert(fd>=0);struct sockaddr_in a={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};assert(!bind(fd,(void *)&a,sizeof a));assert(!listen(fd,2));socklen_t n=sizeof a;assert(!getsockname(fd,(void *)&a,&n));*port=ntohs(a.sin_port);return fd;}
static bool exact(int fd,void *data,size_t size,bool writing){size_t done=0;while(done<size){ssize_t n=writing?send(fd,(char *)data+done,size-done,0):recv(fd,(char *)data+done,size-done,0);if(n<=0)return false;done+=(size_t)n;}return true;}
typedef struct {int listener;bool hold;bool greeting,m1;} peer;
static void *phone(void *ctx){peer *p=ctx;int fd=accept(p->listener,NULL,NULL);assert(fd>=0);int yes=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof yes);uint8_t header[11];char body[16385];
    if(!exact(fd,header,11,false))goto done;assert(!memcmp(header,"RPPairing",9));size_t length=((size_t)header[9]<<8)|header[10];assert(length<sizeof body);assert(exact(fd,body,length,false));body[length]=0;assert(strstr(body,"attemptPairVerify"));p->greeting=true;
    puts("GREETING");fflush(stdout);
    if(p->hold){while(recv(fd,body,sizeof body,0)>0){}goto done;}
    const char reply[]="{\"originatedBy\":\"device\",\"sequenceNumber\":0,\"message\":{\"plain\":{\"_0\":{\"response\":{\"_1\":{\"handshake\":{\"_0\":{\"wireProtocolVersion\":19}}}}}}}}";
    length=strlen(reply);header[9]=(uint8_t)(length>>8);header[10]=(uint8_t)length;assert(exact(fd,header,11,true));assert(exact(fd,(void *)reply,length,true));
    assert(exact(fd,header,11,false));assert(!memcmp(header,"RPPairing",9));length=((size_t)header[9]<<8)|header[10];assert(length<sizeof body);assert(exact(fd,body,length,false));body[length]=0;assert(strstr(body,"verifyManualPairing"));assert(!strstr(body,"setupManualPairing"));p->m1=true;
    puts("VERIFY_M1");fflush(stdout);
done:close(fd);return NULL;}
int main(int argc,char **argv){alarm(12);uint16_t target_port,front_port;peer mock={.listener=listener(&target_port),.hold=argc==2&&!strcmp(argv[1],"hold")};int front=listener(&front_port);pthread_t thread;assert(!pthread_create(&thread,NULL,phone,&mock));printf("%u\n",front_port);fflush(stdout);
    int client=accept(front,NULL,NULL);assert(client>=0);char line[97];size_t used=0;while(used<sizeof line-1){char c;assert(exact(client,&c,1,false));if(c=='\n')break;line[used++]=c;}line[used]=0;
    nd_server catalog={.generation=7,.count=1,.expires=UINT64_MAX};catalog.endpoints[0]=(nd_endpoint){.service=ND_REMOTE_PAIRING,.family=4,.port=target_port,.address={127,0,0,1}};
    nd_link link={.local4={127,0,0,1},.peer4={127,0,0,1},.interface_index=if_nametoindex("lo0")};nd_relay relay={0};nd_relay_job job;assert(nd_relay_prepare(&relay,&catalog,&link,line,&job)==BRIDGE_OK);
    nd_relay_stats stats;bridge_status result=nd_relay_run(&job,client,&stats);assert(result==BRIDGE_E_EOF);assert(stats.peak_buffered<=4096);pthread_join(thread,NULL);assert(mock.greeting);assert(mock.hold||mock.m1);assert(!nd_relay_busy(&relay));close(mock.listener);close(front);puts("CLOSED");return 0;}
