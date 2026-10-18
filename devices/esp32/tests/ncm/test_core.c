/* SPDX-License-Identifier: GPL-3.0-or-later: synthetic peers only. */
#include "nd_server.h"
#include "nd_http.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
static uint8_t packet[4096]; static size_t length;
static void u16(unsigned n) { packet[length++]=(uint8_t)(n>>8); packet[length++]=(uint8_t)n; }
static void u32(unsigned n) { u16(n>>16);u16(n); }
static void dnsname(const char *s) { uint8_t q[512];size_t n=nd_dns_question(s,1,q,sizeof q);assert(n);memcpy(packet+length,q+12,n-16);length+=n-16; }
static void start(unsigned count) { memset(packet,0,sizeof packet);length=2;u16(0x8400);u16(0);u16(count);u16(0);u16(0); }
static void srv(unsigned ttl) { dnsname("test._remotepairing._tcp.local");u16(33);u16(0x8001);u32(ttl);size_t size=length;u16(0);u16(0);u16(0);u16(49321);dnsname("test.local");packet[size]=(uint8_t)((length-size-2)>>8);packet[size+1]=(uint8_t)(length-size-2); }
static void addr(bool ipv6,bool offlink) { dnsname("test.local");u16(ipv6?28:1);u16(1);u32(30);u16(ipv6?16:4);
    if (ipv6) { uint8_t a[16]={0xfe,0x80};a[15]=2;memcpy(packet+length,a,16);length+=16; }
    else { uint8_t a[4]={192,168,7,offlink?3:2};memcpy(packet+length,a,4);length+=4; } }
static void discovery(void) {
    const uint8_t peer[4]={192,168,7,2};nd_catalog c={0},empty={0};nd_endpoint e[16];
    start(3);srv(30);addr(false,false);addr(true,false);
    assert(nd_dns_ingest(&c,packet,length,100)==BRIDGE_OK);assert(nd_dns_endpoints(&c,peer,e,16)==2);
    assert(c.expires==30100 && e[0].port==49321 && e[1].family==6);
    for(size_t n=0;n<length;n++){nd_catalog t={0};assert(nd_dns_ingest(&t,packet,n,100)!=BRIDGE_OK);assert(!memcmp(&t,&empty,sizeof t));}
    uint8_t save[4096];size_t count=length;memcpy(save,packet,length);
    packet[12]=0xc0;packet[13]=12;assert(nd_dns_ingest(&c,packet,length,100)==BRIDGE_E_FORMAT);
    memcpy(packet,save,count);packet[2]|=2;assert(nd_dns_ingest(&c,packet,length,100)==BRIDGE_E_FORMAT);
    start(1);srv(0);assert(nd_dns_ingest(&c,packet,length,200)==BRIDGE_OK);assert(c.expires==200);assert(nd_dns_endpoints(&c,peer,e,16)==0);
    memset(&c,0,sizeof c);start(1);addr(false,true);assert(nd_dns_ingest(&c,packet,length,0)==BRIDGE_OK);start(1);srv(1);assert(nd_dns_ingest(&c,packet,length,0)==BRIDGE_OK);assert(nd_dns_endpoints(&c,peer,e,16)==0);
    start(1);addr(false,false);assert(nd_dns_ingest(&c,packet,length,0)==BRIDGE_OK);assert(nd_dns_endpoints(&c,peer,e,16)==1);
    // Unknown TXT (can contain identity material) is never retained.
    start(1);dnsname("test._remotepairing._tcp.local");u16(16);u16(1);u32(30);u16(6);memcpy(packet+length,"secret",6);length+=6;
    nd_catalog before=c;assert(nd_dns_ingest(&c,packet,length,0)==BRIDGE_OK);assert(!memcmp(&c,&before,sizeof c));
    puts("DNS: split replies, IPv4/IPv6, off-link filter, every truncation, compression cycle, TC, goodbye, TTL, TXT omission passed");
}
typedef struct { uint8_t input[20000],output[16384];size_t n,pos,written; } memory;
static ptrdiff_t rd(void *ctx,uint8_t *p,size_t n,uint32_t ms){(void)ms;memory *m=ctx;if(n>3)n=3;if(n>m->n-m->pos)n=m->n-m->pos;memcpy(p,m->input+m->pos,n);m->pos+=n;return (ptrdiff_t)n;}
static ptrdiff_t wr(void *ctx,const uint8_t *p,size_t n,uint32_t ms){(void)ms;memory *m=ctx;if(n>2)n=2;assert(m->written+n<=sizeof m->output);memcpy(m->output+m->written,p,n);m->written+=n;return (ptrdiff_t)n;}
static uint64_t clk(void *ctx){(void)ctx;return 1;}
static const char valid[]="{\"originatedBy\":\"device\",\"sequenceNumber\":0,\"message\":{\"plain\":{\"_0\":{\"response\":{\"_1\":{\"handshake\":{\"_0\":{\"wireProtocolVersion\":26,\"peerDeviceInfo\":{\"identifier\":\"SYNTHETIC-NEVER-LOG\"}}}}}}}}}";
static void frame(memory *m,const char *body){memset(m,0,sizeof *m);size_t n=strlen(body);memcpy(m->input,"RPPairing",9);m->input[9]=(uint8_t)(n>>8);m->input[10]=(uint8_t)n;memcpy(m->input+11,body,n);m->n=n+11;}
static void greeting(void) {
    memory m;frame(&m,valid);bridge_io io={&m,rd,wr,clk};uint8_t scratch[ND_GREETING_LIMIT+1];uint32_t version=0;
    memset(scratch,1,sizeof scratch);assert(nd_pairing_greeting(&io,scratch,sizeof scratch,100,&version)==BRIDGE_OK && version==26);
    for(size_t i=0;i<=strlen(valid);i++) assert(!scratch[i]);
    assert(strstr((char *)m.output+11,"attemptPairVerify"));assert(!strstr((char *)m.output+11,"pairingData"));
    size_t full=m.n;
    for(size_t i=0;i<full;i++){frame(&m,valid);m.n=i;version=99;assert(nd_pairing_greeting(&io,scratch,sizeof scratch,100,&version)!=BRIDGE_OK);assert(!version);}
    frame(&m,valid);m.input[0]='X';assert(nd_pairing_greeting(&io,scratch,sizeof scratch,100,&version)==BRIDGE_E_FORMAT);
    frame(&m,valid);m.input[9]=0xff;assert(nd_pairing_greeting(&io,scratch,sizeof scratch,100,&version)==BRIDGE_E_LIMIT);
    frame(&m,"{\"message\":\"wireProtocolVersion 26\"}");assert(nd_pairing_greeting(&io,scratch,sizeof scratch,100,&version)==BRIDGE_E_FORMAT);
    char duplicate[2048];snprintf(duplicate,sizeof duplicate,"{\"originatedBy\":\"host\",%s",valid+1);frame(&m,duplicate);assert(nd_pairing_greeting(&io,scratch,sizeof scratch,100,&version)==BRIDGE_E_FORMAT);
    char deep[1024];memset(deep,'[',100);memset(deep+100,']',100);deep[200]=0;frame(&m,deep);assert(nd_pairing_greeting(&io,scratch,sizeof scratch,100,&version)==BRIDGE_E_FORMAT);
    frame(&m,valid);assert(nd_pairing_greeting(&io,scratch,sizeof scratch,1,&version)==BRIDGE_E_TIMEOUT);
    puts("Greeting: fragmented I/O, every EOF boundary, malformed/schema/role/duplicate/size/depth/timeout, metadata-only and wipe passed");
}
static void boundaries(void) {
    nd_server s={0};nd_link link={.local4={127,0,0,1},.peer4={127,0,0,1},.interface_index=1};char output[16384];
    const char *blocked[]={"RSD","SCREENSHOT","TAP","PAIR","PROBE 1 0","PROBE 999999999999999999999999 0","PROBE -1 0"};
    for(size_t i=0;i<sizeof blocked/sizeof *blocked;i++){assert(nd_server_command(&s,&link,blocked[i],output,sizeof output)==BRIDGE_OK);assert(strstr(output,"\"authenticated\":false"));assert(!strstr(output,"\"result\":\"ok\""));}
    s.count=1;s.generation=17;s.expires=UINT64_MAX;nd_server_reset(&s);assert(!s.count && s.generation==18);
    puts("Boundaries: stale generation and no capture/tap promotion passed");
}
static void browser(void) {
    memory m={0};bridge_io io={&m,rd,wr,clk};nd_server server={0};nd_link link={0};
    nd_http http={.token="0123456789abcdef0123456789abcdef"};char body[ND_HTTP_BODY_LIMIT];
    const char *cases[]={
        "Host: 192.168.7.1:28767\r\n\r\n",
        "Host: attacker.example\r\n\r\n",
        "Host: 192.168.7.1:28767\r\nHost: 192.168.7.1:28767\r\n\r\n",
        "Host: 192.168.7.1:28767\r\nTransfer-Encoding: chunked\r\n\r\n"};
    for(size_t i=0;i<sizeof cases/sizeof *cases;i++){
        memset(&m,0,sizeof m);m.n=strlen(cases[i]);memcpy(m.input,cases[i],m.n);
        assert(nd_http_serve(&http,&server,&link,&io,"GET / HTTP/1.1",body,sizeof body,nd_now(NULL)+3000)==BRIDGE_OK);
        assert(strstr((char *)m.output,i?"400 Bad Request":"200 OK"));assert(!server.generation);
        /* Form navigation under no-referrer sends Origin:null and is rejected.
         * Preserve same-origin form submissions without accepting null origins. */
        assert(strstr((char *)m.output,"Referrer-Policy: same-origin\r\n"));
    }
    const char *actions[]={"STATUS","PAIR","SCREENSHOT","CHECK4"};
    for(size_t i=0;i<4;i++){
        char request[128];snprintf(request,sizeof request,"token=%s&action=%s",i==3?"WRONG":http.token,actions[i]);
        memset(&m,0,sizeof m);m.n=(size_t)snprintf((char *)m.input,sizeof m.input,"Host: 192.168.7.1:28767\r\nOrigin: http://192.168.7.1:28767\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %zu\r\n\r\n%s",strlen(request),request);
        assert(nd_http_serve(&http,&server,&link,&io,"POST /probe HTTP/1.1",body,sizeof body,nd_now(NULL)+3000)==BRIDGE_OK);
        assert(strstr((char *)m.output,i?"400 Bad Request":"diagnostic-only"));assert(!server.generation);
    }
    memset(&m,0,sizeof m);const char *cross="Host: 192.168.7.1:28767\r\nOrigin: https://evil.example\r\nContent-Length: 0\r\n\r\n";m.n=strlen(cross);memcpy(m.input,cross,m.n);
    assert(nd_http_serve(&http,&server,&link,&io,"POST /probe HTTP/1.1",body,sizeof body,nd_now(NULL)+3000)==BRIDGE_OK);assert(strstr((char *)m.output,"400 Bad Request"));
    memset(&m,0,sizeof m);const char *opaque="Host: 192.168.7.1:28767\r\nOrigin: null\r\nContent-Length: 0\r\n\r\n";m.n=strlen(opaque);memcpy(m.input,opaque,m.n);
    assert(nd_http_serve(&http,&server,&link,&io,"POST /probe HTTP/1.1",body,sizeof body,nd_now(NULL)+3000)==BRIDGE_OK);assert(strstr((char *)m.output,"Invalid origin"));assert(!server.generation);
    puts("Browser: idle GET, same origin/host/token, no action escalation, duplicate and transfer-coding rejection passed (memory only)");
}
int main(void){discovery();greeting();boundaries();browser();return 0;}
