/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "nd.h"
#include <string.h>
#include <ctype.h>
static const char *services[]={"", "_remotepairing._tcp.local", "_apple-mobdev2._tcp.local", "_remotepairing-pairable-host._tcp.local"};
const char *nd_service_name(nd_service s) { return s==ND_REMOTE_PAIRING?"remotepairing":s==ND_LOCKDOWN?"lockdown":s==ND_PAIRABLE_HOST?"pairable-host":"unknown"; }
static uint16_t u16(const uint8_t *p) { return (uint16_t)((p[0]<<8)|p[1]); }
static uint32_t u32(const uint8_t *p) { return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]; }
size_t nd_dns_question(const char *q,uint16_t type,uint8_t *out,size_t cap) {
    if (!q || !out || !*q || cap<strlen(q)+18) return 0;
    memset(out,0,12); out[5]=1; size_t n=12; const char *start=q;
    while (*start) { const char *dot=strchr(start,'.'); size_t len=dot?(size_t)(dot-start):strlen(start);
        if (!len || len>63) return 0;
        out[n++]=(uint8_t)len; memcpy(out+n,start,len); n+=len; if (!dot) break; start=dot+1; }
    out[n++]=0; out[n++]=(uint8_t)(type>>8); out[n++]=(uint8_t)type; out[n++]=0; out[n++]=1; return n;
}
size_t nd_dns_query(nd_service s,uint8_t *out,size_t cap) {
    return s<1 || s>3?0:nd_dns_question(services[s],12,out,cap);
}
static bool name(const uint8_t *p,size_t size,size_t *at,char out[ND_NAME]) {
    size_t pos=*at,n=0,next=0; bool jumped=false;
    for (size_t hops=0;hops<128;hops++) {
        if (pos>=size) return false;
        uint8_t len=p[pos++];
        if ((len&0xc0)==0xc0) { if (pos>=size) return false; size_t target=((size_t)(len&63)<<8)|p[pos++];
            if (target>=pos-2) return false; // backward-only compression, no cycles
            if (!jumped) next=pos;
            jumped=true; pos=target; continue; }
        if (len&0xc0 || len>63 || pos+len>size) return false;
        if (!len) { out[n]=0; *at=jumped?next:pos; return true; }
        if (n && n<ND_NAME-1) out[n++]='.';
        if (n+len>=ND_NAME) return false;
        for (size_t i=0;i<len;i++) { uint8_t c=p[pos++]; if (!c || c=='.') return false; out[n++]=(char)(c<128?tolower(c):c); }
    }
    return false;
}
static nd_service service_of(const char *name) {
    size_t n=strlen(name);
    for (int i=1;i<=3;i++) { size_t m=strlen(services[i]); if (n>m && name[n-m-1]=='.' && !strcmp(name+n-m,services[i])) return (nd_service)i; }
    return 0;
}
static bool insert(nd_catalog *c,const nd_record *r,bool alive) {
    size_t i;
    for (i=0;i<c->count;i++) if (c->records[i].type==r->type && !strcmp(c->records[i].name,r->name) &&
        (r->type==33 || (r->type==12?!strcmp(c->records[i].target,r->target):!memcmp(c->records[i].address,r->address,16)))) break;
    if (!alive) { if (i<c->count) c->records[i]=c->records[--c->count]; return true; }
    if (i==c->count) { if (i==ND_RECORDS) return false; c->count++; }
    c->records[i]=*r; return true;
}
bridge_status nd_dns_ingest(nd_catalog *catalog,const uint8_t *p,size_t size,uint64_t now) {
    if (!catalog || !p || size<12 || size>ND_DNS_LIMIT) return BRIDGE_E_ARGUMENT;
    if ((u16(p+2)&0xFA0F)!=0x8000 || u16(p)!=0) return BRIDGE_E_FORMAT; // reply, no TC/opcode/rcode
    unsigned questions=u16(p+4), total=(unsigned)u16(p+6)+u16(p+8)+u16(p+10);
    if (questions>32 || total>128) return BRIDGE_E_LIMIT;
    /* Fixed transactional copy; firmware diagnostic task reserves 32 KiB stack. */
    nd_catalog pending=*catalog; if (!pending.expires) pending.expires=UINT64_MAX; size_t at=12; char ignored[ND_NAME];
    for (unsigned i=0;i<questions;i++) { if (!name(p,size,&at,ignored) || at+4>size) return BRIDGE_E_FORMAT; at+=4; }
    for (unsigned i=0;i<total;i++) {
        nd_record r={0}; if (!name(p,size,&at,r.name) || at+10>size) return BRIDGE_E_FORMAT;
        r.type=u16(p+at); uint16_t cls=u16(p+at+2)&0x7fff; uint32_t ttl=u32(p+at+4); size_t len=u16(p+at+8); at+=10;
        if (len>size-at) return BRIDGE_E_FORMAT;
        size_t end=at+len; bool keep=false;
        if (cls==1 && r.type==33 && service_of(r.name)) {
            if (len<7) return BRIDGE_E_FORMAT;
            r.port=u16(p+at+4); size_t target=at+6;
            if (!name(p,size,&target,r.target) || target!=end || !r.target[0] || !r.port) return BRIDGE_E_FORMAT;
            keep=true;
        } else if (cls==1 && (r.type==1 || r.type==28)) {
            size_t width=r.type==1?4:16; if (len!=width) return BRIDGE_E_FORMAT;
            memcpy(r.address,p+at,width); keep=true;
        } else if (cls==1 && r.type==12) {
            size_t target=at; if (!name(p,size,&target,r.target) || target!=end) return BRIDGE_E_FORMAT;
            for (int k=1;k<=3;k++) if (!strcmp(r.name,services[k]) && service_of(r.target)==(nd_service)k) keep=true;
        }
        if (keep) {
            /* A goodbye conservatively expires this whole short-lived snapshot. */
            uint64_t expiry=now+(uint64_t)ttl*1000;
            if (expiry<pending.expires) pending.expires=expiry;
            if (!insert(&pending,&r,ttl!=0)) return BRIDGE_E_LIMIT;
        }
        at=end;
    }
    if (at!=size) return BRIDGE_E_FORMAT;
    *catalog=pending; return BRIDGE_OK;
}
size_t nd_dns_endpoints(const nd_catalog *c,const uint8_t peer4[4],nd_endpoint *out,size_t cap) {
    size_t n=0;
    for (size_t i=0;i<c->count;i++) { const nd_record *s=&c->records[i]; if (s->type!=33) continue;
        nd_service kind=service_of(s->name); if (!kind || !s->port) continue;
        for (size_t j=0;j<c->count;j++) { const nd_record *a=&c->records[j]; if (strcmp(a->name,s->target)) continue;
            if (a->type==1) { if (memcmp(a->address,peer4,4)) continue; }
            else if (a->type==28) { if (a->address[0]!=0xfe || (a->address[1]&0xc0)!=0x80) continue; }
            else continue;
            nd_endpoint e={.service=kind,.family=a->type==1?4:6,.port=s->port}; memcpy(e.address,a->address,a->type==1?4:16);
            bool duplicate=false; for (size_t k=0;k<n;k++) if (out[k].service==e.service && out[k].family==e.family && out[k].port==e.port && !memcmp(out[k].address,e.address,16)) duplicate=true;
            if (!duplicate && n<cap) out[n++]=e;
        }
    }
    return n;
}
