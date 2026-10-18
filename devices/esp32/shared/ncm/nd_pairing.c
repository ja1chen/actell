/* SPDX-License-Identifier: GPL-3.0-or-later
 * RemotePairing schema reference: pymobiledevice3 cd895d17, tunnel_service.py.
 * No Pair Setup/Verify, credentials, or persistent host identity is generated. */
#include "nd.h"
#include "cJSON.h"
#include <string.h>
#include <math.h>
static const char hello[]="{\"message\":{\"plain\":{\"_0\":{\"request\":{\"_0\":{\"handshake\":{\"_0\":{\"hostOptions\":{\"attemptPairVerify\":true},\"wireProtocolVersion\":19}}}}}}},\"originatedBy\":\"host\",\"sequenceNumber\":0}";
/* Bound nesting before cJSON (IDF's global default allows much deeper trees). */
static bool bounded_json(const uint8_t *p,size_t n) {
    unsigned depth=0; bool string=false,escape=false;
    for (size_t i=0;i<n;i++) {
        uint8_t c=p[i];
        if (!c) return false;
        if (string) { if (escape) escape=false; else if (c=='\\') escape=true; else if (c=='"') string=false; }
        else if (c=='"') string=true;
        else if (c=='{' || c=='[') { if (++depth>24) return false; }
        else if (c=='}' || c==']') { if (!depth) return false; --depth; }
    }
    return !depth && !string;
}
static const cJSON *unique(const cJSON *v,const char *key) {
    if (!cJSON_IsObject(v)) return NULL;
    const cJSON *found=NULL;
    for (const cJSON *p=v->child;p;p=p->next) if (p->string && !strcmp(p->string,key)) { if (found) return NULL; found=p; }
    return found;
}
bridge_status nd_pairing_greeting(bridge_io *io,uint8_t *scratch,size_t cap,uint64_t deadline,uint32_t *version) {
    if (!io || !scratch || cap<2 || !version) return BRIDGE_E_ARGUMENT;
    *version=0; uint8_t header[11]={'R','P','P','a','i','r','i','n','g',0,0}; size_t n=sizeof(hello)-1;
    header[9]=(uint8_t)(n>>8); header[10]=(uint8_t)n;
    bridge_status s=bridge_write_exact(io,header,11,deadline);
    if (s==BRIDGE_OK) s=bridge_write_exact(io,(const uint8_t *)hello,n,deadline);
    if (s==BRIDGE_OK) s=bridge_read_exact(io,header,11,deadline);
    if (s!=BRIDGE_OK) return s;
    n=((size_t)header[9]<<8)|header[10];
    if (memcmp(header,"RPPairing",9) || !n) return BRIDGE_E_FORMAT;
    if (n>=cap || n>ND_GREETING_LIMIT) return BRIDGE_E_LIMIT;
    s=bridge_read_exact(io,scratch,n,deadline); scratch[n]=0;
    cJSON *root=NULL;
    if (s==BRIDGE_OK && !bounded_json(scratch,n)) s=BRIDGE_E_FORMAT;
    if (s==BRIDGE_OK) {
        const char *end=NULL; root=cJSON_ParseWithLengthOpts((char *)scratch,n+1,&end,1);
        const cJSON *role=unique(root,"originatedBy"),*seq=unique(root,"sequenceNumber");
        const cJSON *v=root; const char *path[]={"message","plain","_0","response","_1","handshake","_0"};
        for (size_t i=0;i<7;i++) v=unique(v,path[i]);
        v=unique(v,"wireProtocolVersion");
        if (!root || end!=(char *)scratch+n || memchr(scratch,0,n) || !cJSON_IsString(role) || strcmp(role->valuestring,"device") ||
            !cJSON_IsNumber(seq) || seq->valuedouble!=0 || !cJSON_IsNumber(v) || v->valuedouble<1 || v->valuedouble>UINT32_MAX || floor(v->valuedouble)!=v->valuedouble) s=BRIDGE_E_FORMAT;
        else *version=(uint32_t)v->valuedouble;
    }
    cJSON_Delete(root); memset(scratch,0,n+1); return s;
}
