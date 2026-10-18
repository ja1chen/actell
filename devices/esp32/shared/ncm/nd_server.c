/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "nd_server.h"
#include "bridge_lockdown_probe.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
void nd_server_reset(nd_server *s) { uint32_t next=s->generation+1; memset(s,0,sizeof *s); s->generation=next?next:1; }
static bridge_status reply(char *out,size_t cap,const char *layer,const char *result,int error,bool tcp,uint32_t version) {
    int n=snprintf(out,cap,"{\"protocol\":\"ND1\",\"layer\":\"%s\",\"result\":\"%s\",\"osError\":%d,\"tcpConnected\":%s,\"wireVersion\":%"PRIu32",\"authenticated\":false,\"screenCaptured\":false,\"inputExecuted\":false}\n",layer,result,error,tcp?"true":"false",version);
    return n<0 || (size_t)n>=cap?BRIDGE_E_LIMIT:BRIDGE_OK;
}
bridge_status nd_server_command(nd_server *s,const nd_link *link,const char *command,char *out,size_t cap) {
    if (!s || !link || !command || !out || cap<ND_REPLY_LIMIT || strlen(command)>ND_COMMAND_LIMIT) return BRIDGE_E_ARGUMENT;
    if (!strcmp(command,"STATUS")) return reply(out,cap,"ncm","diagnostic-only",0,false,0);
    if (!strcmp(command,"RSD") || !strcmp(command,"SCREENSHOT") || !strcmp(command,"TAP"))
        return reply(out,cap,"authentication","authorization-required",0,false,0);
    if (!strcmp(command,"DISCOVER4") || !strcmp(command,"DISCOVER6")) {
        nd_server_reset(s); int os_error=0; int family=command[8]=='4'?4:6;
        bridge_status result=nd_discover(link,family,&s->catalog,nd_now(NULL)+3000,&os_error);
        if (result!=BRIDGE_OK) return reply(out,cap,"discovery",bridge_status_name(result),os_error,false,0);
        s->count=nd_dns_endpoints(&s->catalog,link->peer4,s->endpoints,ND_ENDPOINTS); s->expires=nd_now(NULL)+5000;
        if (s->catalog.expires<s->expires) s->expires=s->catalog.expires;
        if (s->expires<=nd_now(NULL)) s->count=0;
        size_t used=(size_t)snprintf(out,cap,"{\"protocol\":\"ND1\",\"layer\":\"discovery\",\"result\":\"%s\",\"generation\":%"PRIu32",\"authenticated\":false,\"endpoints\":[",s->count?"candidates":"no-candidates",s->generation);
        for (size_t i=0;i<s->count;i++) {
            nd_endpoint *e=&s->endpoints[i];
            int n=snprintf(out+used,cap-used,"%s{\"index\":%zu,\"service\":\"%s\",\"family\":%d,\"port\":%u}",i?",":"",i,nd_service_name(e->service),e->family,e->port);
            if (n<0 || (size_t)n>=cap-used) return BRIDGE_E_LIMIT;
            used+=(size_t)n;
        }
        if (used+4>=cap) return BRIDGE_E_LIMIT;
        memcpy(out+used,"]}\n",4); return BRIDGE_OK;
    }
    nd_endpoint e={.service=ND_LOCKDOWN,.family=4,.port=BRIDGE_LOCKDOWN_PORT}; memcpy(e.address,link->peer4,4);
    if (strcmp(command,"LOCKDOWN")) {
        uint32_t generation=0,index=0; const char *cursor=command;
        bool valid=!strncmp(cursor,"PROBE ",6);
        if (valid) {
            cursor+=6;
            for (int field=0;field<2;field++) {
                uint32_t value=0; bool digit=false;
                while (*cursor>='0' && *cursor<='9') {
                    unsigned d=(unsigned)(*cursor++-'0'); digit=true;
                    if (value>(UINT32_MAX-d)/10) { valid=false; break; }
                    value=value*10+d;
                }
                if (!valid || !digit) { valid=false; break; }
                if (field==0) { generation=value; if (*cursor++!=' ') { valid=false; break; } }
                else index=value;
            }
        }
        if (!valid || *cursor || !generation)
            return reply(out,cap,"command","unsupported",0,false,0);
        if (generation!=s->generation || index>=s->count || nd_now(NULL)>=s->expires)
            return reply(out,cap,"discovery","stale-candidate",0,false,0);
        e=s->endpoints[index];
        if (e.service==ND_PAIRABLE_HOST) return reply(out,cap,"pairing","authorization-required",0,false,0);
    }
    nd_socket socket={.fd=-1}; uint64_t deadline=nd_now(NULL)+3000;
    bridge_status status=nd_socket_connect(&socket,link,&e,deadline); bool connected=status==BRIDGE_OK; uint32_t version=0;
    const char *layer="tcp";
    if (connected) {
        bridge_io io=nd_socket_io(&socket);
        uint8_t *scratch=calloc(1,ND_GREETING_LIMIT+1);
        if (!scratch) status=BRIDGE_E_LIMIT;
        else {
            if (e.service==ND_REMOTE_PAIRING) { layer="greeting"; status=nd_pairing_greeting(&io,scratch,ND_GREETING_LIMIT+1,deadline,&version); }
            else { layer="lockdown-querytype"; bridge_lockdown_probe_result result={0}; status=bridge_lockdown_probe_query_type(&io,scratch,BRIDGE_LOCKDOWN_PROBE_MAX_REPLY_BYTES,deadline,&result); }
            memset(scratch,0,ND_GREETING_LIMIT+1); free(scratch);
        }
    }
    nd_socket_close(&socket);
    return reply(out,cap,layer,bridge_status_name(status),socket.error,connected,version);
}
