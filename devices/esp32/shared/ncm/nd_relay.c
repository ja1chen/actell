/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "nd_relay.h"
#include "bridge_lockdown_probe.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#ifndef ESP_PLATFORM
#include <sys/select.h>
#endif
void nd_relay_cancel(nd_relay *s) { atomic_store(&s->cancelled,true); }
bool nd_relay_busy(nd_relay *s) {
    if(s->claimed && atomic_load(&s->cancelled) && atomic_load(&s->done)==s->started){s->claimed=false;memset(s->nonce,0,sizeof s->nonce);}
    return s->claimed;
}
static bool alive(void *ctx) {
    nd_relay_job *j=ctx;nd_relay *s=j->session;
    return !atomic_load(&s->cancelled) && (!s->base.alive || s->base.alive(s->base.context));
}
static bool number(const char **cursor,uint32_t *result) {
    const char *p=*cursor;uint32_t n=0;bool digit=false;
    while(*p>='0' && *p<='9'){unsigned d=(unsigned)(*p++-'0');if(n>(UINT32_MAX-d)/10)return false;n=n*10+d;digit=true;}
    if(!digit)return false;
    *result=n;*cursor=p;return true;
}
static bool token(const char **cursor,char out[33]) {
    for(size_t i=0;i<32;i++){char c=(*cursor)[i];if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')))return false;out[i]=c;}
    out[32]=0;*cursor+=32;return true;
}
bridge_status nd_relay_prepare(nd_relay *s,const nd_server *catalog,const nd_link *link,const char *line,nd_relay_job *job) {
    if(!s||!catalog||!link||!line||!job||strlen(line)>ND_RELAY_LINE_LIMIT)return BRIDGE_E_ARGUMENT;
    bool busy=nd_relay_busy(s);const char *p=line;char nonce[33]={0};unsigned bit=0;nd_endpoint target={0};
    if(!strncmp(p,"NL1 OPEN ",9)){
        p+=9;if(strlen(p)!=32||!token(&p,nonce)||*p)return BRIDGE_E_FORMAT;
        if(busy)return BRIDGE_E_LIMIT;
        target=(nd_endpoint){.service=ND_LOCKDOWN,.family=4,.port=BRIDGE_LOCKDOWN_PORT};
        memcpy(target.address,link->peer4,4);
        s->claimed=true;s->lockdown=true;s->started=0;s->target=target;s->base=*link;memcpy(s->nonce,nonce,sizeof nonce);
        atomic_store(&s->done,0);atomic_store(&s->cancelled,false);atomic_store(&s->control_ready,false);atomic_store(&s->last_io_ms,(uint32_t)nd_now(NULL));bit=1;
    }else if(!strncmp(p,"NR1 OPEN ",9)){
        p+=9;uint32_t generation=0,index=0;
        if(!number(&p,&generation)||*p++!=' '||!number(&p,&index)||*p++!=' '||strlen(p)!=32||!token(&p,nonce)||*p)return BRIDGE_E_FORMAT;
        if(busy)return BRIDGE_E_LIMIT;
        if(!generation||generation!=catalog->generation||index>=catalog->count||nd_now(NULL)>=catalog->expires)return BRIDGE_E_NOT_FOUND;
        target=catalog->endpoints[index];if(target.service!=ND_REMOTE_PAIRING)return BRIDGE_E_UNSUPPORTED;
        s->claimed=true;s->lockdown=false;s->started=0;s->target=target;s->base=*link;memcpy(s->nonce,nonce,sizeof nonce);
        atomic_store(&s->done,0);atomic_store(&s->cancelled,false);atomic_store(&s->control_ready,false);atomic_store(&s->last_io_ms,(uint32_t)nd_now(NULL));bit=1;
    }else if(!strncmp(p,"NR1 TUNNEL ",11)){
        p+=11;uint32_t port=0;if(strlen(p)<34||!token(&p,nonce)||*p++!=' '||!number(&p,&port)||*p||!port||port>65535)return BRIDGE_E_FORMAT;
        if(!busy||s->lockdown||strcmp(nonce,s->nonce)||atomic_load(&s->cancelled)||!atomic_load(&s->control_ready))return BRIDGE_E_NOT_FOUND;
        if(s->started&2)return BRIDGE_E_LIMIT;
        target=s->target;target.port=(uint16_t)port;bit=2;
    }else if(!strncmp(p,"NR1 CANCEL ",11)||!strncmp(p,"NL1 CANCEL ",11)){
        bool lockdown=line[1]=='L';
        p+=11;if(strlen(p)!=32||!token(&p,nonce)||*p)return BRIDGE_E_FORMAT;
        if(!busy||s->lockdown!=lockdown||strcmp(nonce,s->nonce))return BRIDGE_E_NOT_FOUND;
        nd_relay_cancel(s);memset(job,0,sizeof *job);return BRIDGE_OK;
    }else return BRIDGE_E_FORMAT;
    *job=(nd_relay_job){.session=s,.link=s->base,.target=target,.bit=bit};job->link.alive=alive;job->link.context=job;s->started|=bit;
    return BRIDGE_OK;
}
void nd_relay_abandon(nd_relay_job *j) {
    if(j->session){nd_relay_cancel(j->session);atomic_fetch_or(&j->session->done,j->bit);}
}
typedef struct { uint8_t data[ND_RELAY_BUFFER];size_t start,length; } slab;
static bridge_status pump(nd_relay_job *j,int a,int b,nd_relay_stats *stats) {
    slab ab={0},ba={0};
    for(;;){
        if(!alive(j))return BRIDGE_E_EOF;
        if((uint32_t)((uint32_t)nd_now(NULL)-atomic_load(&j->session->last_io_ms))>=60000)return BRIDGE_E_TIMEOUT;
        fd_set reads,writes;FD_ZERO(&reads);FD_ZERO(&writes);
        if(!ab.length)FD_SET(a,&reads);else FD_SET(b,&writes);
        if(!ba.length)FD_SET(b,&reads);else FD_SET(a,&writes);
        struct timeval wait={.tv_sec=0,.tv_usec=50000};int ready=select((a>b?a:b)+1,&reads,&writes,NULL,&wait);
        if(ready<0){if(errno==EINTR)continue;return BRIDGE_E_IO;}
        for(unsigned direction=0;direction<2;direction++){
            int from=direction?b:a,to=direction?a:b;slab *q=direction?&ba:&ab;
            if(FD_ISSET(from,&reads)){
                ssize_t n=recv(from,q->data,sizeof q->data,0);if(!n)return BRIDGE_E_EOF;
                if(n<0){if(errno!=EAGAIN&&errno!=EWOULDBLOCK&&errno!=EINTR)return BRIDGE_E_IO;}
                else {q->start=0;q->length=(size_t)n;atomic_store(&j->session->last_io_ms,(uint32_t)nd_now(NULL));}
            }
            if(q->length && FD_ISSET(to,&writes)){
                ssize_t n=send(to,q->data+q->start,q->length,0);
                if(n<0){if(errno!=EAGAIN&&errno!=EWOULDBLOCK&&errno!=EINTR)return BRIDGE_E_IO;}
                else if(n){q->start+=(size_t)n;q->length-=(size_t)n;if(direction)stats->to_client+=(uint64_t)n;else stats->to_peer+=(uint64_t)n;atomic_store(&j->session->last_io_ms,(uint32_t)nd_now(NULL));}
            }
        }
        size_t buffered=ab.length+ba.length;if(buffered>stats->peak_buffered)stats->peak_buffered=buffered;
    }
}
bridge_status nd_relay_run(nd_relay_job *j,int fd,nd_relay_stats *stats) {
    nd_socket upstream={.fd=-1},client={.fd=fd,.link=&j->link};bridge_io io=nd_socket_io(&client);nd_relay_stats unused={0};if(!stats)stats=&unused;*stats=(nd_relay_stats){0};
    bridge_status result=BRIDGE_E_EOF;
    if(!alive(j))goto done;
    result=BRIDGE_E_IO;
    if(fcntl(fd,F_SETFL,O_NONBLOCK)<0)goto done;
#ifdef __APPLE__
    int yes=1;if(setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof yes))goto done;
#endif
    result=nd_socket_connect(&upstream,&j->link,&j->target,nd_now(NULL)+3000);
    if(result!=BRIDGE_OK){const char *reply=j->session->lockdown?"NL1 ERR connect\n":"NR1 ERR connect\n";(void)bridge_write_exact(&io,(const uint8_t *)reply,strlen(reply),nd_now(NULL)+500);goto done;}
    if(j->bit==1)atomic_store(&j->session->control_ready,true);
    result=bridge_write_exact(&io,(const uint8_t *)(j->session->lockdown?"NL1 OK\n":"NR1 OK\n"),7,nd_now(NULL)+1000);
    if(result==BRIDGE_OK)result=pump(j,fd,upstream.fd,stats);
done:
    nd_socket_close(&upstream);nd_socket_close(&client);nd_relay_abandon(j);return result;
}
