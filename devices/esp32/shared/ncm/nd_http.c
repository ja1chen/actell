/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "nd_http.h"
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <stdlib.h>
#include <inttypes.h>
#ifdef ESP_PLATFORM
#include "esp_log.h"
#endif
#define HOST "192.168.7.1:28767"
#define ORIGIN "http://" HOST
static bridge_status respond(bridge_io *io,int code,const char *body,uint64_t deadline) {
#ifdef ESP_PLATFORM
    /* Error bodies are fixed parser messages; never log successful HTML/token. */
    ESP_LOGI("ncm_http","response=%d reason=%s",code,code==200?"ok":body);
#endif
    char header[512];int n=snprintf(header,sizeof header,"HTTP/1.1 %d %s\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %zu\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: same-origin\r\nContent-Security-Policy: default-src 'none'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'\r\n\r\n",code,code==200?"OK":"Bad Request",strlen(body));
    if(n<0 || (size_t)n>=sizeof header)return BRIDGE_E_LIMIT;
    bridge_status s=bridge_write_exact(io,(const uint8_t *)header,(size_t)n,deadline);
    return s==BRIDGE_OK?bridge_write_exact(io,(const uint8_t *)body,strlen(body),deadline):s;
}
static bool append(char *out,size_t cap,const char *text) {
    size_t n=strlen(out),more=strlen(text);if(more>=cap-n)return false;memcpy(out+n,text,more+1);return true;
}
/* JSON fields are currently fixed metadata, but escape independently of that. */
static bool escape(char *out,size_t cap,const char *text) {
    for(;*text;text++) { const char *s=NULL;char one[2]={*text,0};
        switch(*text){case '&':s="&amp;";break;case '<':s="&lt;";break;case '>':s="&gt;";break;default:s=one;}
        if(!append(out,cap,s))return false;
    }return true;
}
bridge_status nd_http_serve(nd_http *http,nd_server *server,const nd_link *link,bridge_io *io,const char *line,char *body,size_t cap,uint64_t deadline) {
    if(!http || !server || !link || !io || !line || !body || cap<ND_HTTP_BODY_LIMIT)return BRIDGE_E_ARGUMENT;
    bool get=!strcmp(line,"GET / HTTP/1.1"),post=!strcmp(line,"POST /probe HTTP/1.1");
    if(!get && !post)return respond(io,400,"Unsupported request",deadline);
    char headers[2048];size_t used=0;bool end=false;
    while(used<sizeof headers-1){uint8_t c=0;bridge_status s=bridge_read_exact(io,&c,1,deadline);if(s!=BRIDGE_OK)return s;
        if(c==0 || (c<32 && c!='\r' && c!='\n' && c!='\t') || c>126)return respond(io,400,"Invalid headers",deadline);
        headers[used++]=(char)c;if(used>=4 && !memcmp(headers+used-4,"\r\n\r\n",4)){end=true;break;}}
    if(!end)return respond(io,400,"Header limit",deadline);
    headers[used]=0;bool host=false,origin=false,type=false;size_t length=0;bool has_length=false;
    for(char *p=headers;*p;){char *next=strstr(p,"\r\n");if(!next)return respond(io,400,"Invalid headers",deadline);*next=0;if(!*p)break;
        char *colon=strchr(p,':');if(!colon || p[0]==' ' || p[0]=='\t')return respond(io,400,"Invalid headers",deadline);*colon=0;char *value=colon+1;while(*value==' ' || *value=='\t')value++;
        if(!strcasecmp(p,"Host")){if(host || strcmp(value,HOST))return respond(io,400,"Invalid host",deadline);host=true;}
        else if(!strcasecmp(p,"Origin")){if(origin || strcmp(value,ORIGIN))return respond(io,400,"Invalid origin",deadline);origin=true;}
        else if(!strcasecmp(p,"Content-Type")){if(type || strcmp(value,"application/x-www-form-urlencoded"))return respond(io,400,"Invalid type",deadline);type=true;}
        else if(!strcasecmp(p,"Content-Length")){if(has_length || !*value)return respond(io,400,"Invalid length",deadline);has_length=true;
            for(;*value;value++){if(*value<'0'||*value>'9'||length>128)return respond(io,400,"Invalid length",deadline);length=length*10+(unsigned)(*value-'0');}}
        else if(!strcasecmp(p,"Transfer-Encoding"))return respond(io,400,"Transfer coding refused",deadline);
        p=next+2;
    }
    if(!host || length>128 || (get && length) || (post && (!origin || !type || !has_length)))return respond(io,400,"Invalid request",deadline);
    char request[129]={0};if(length){bridge_status s=bridge_read_exact(io,(uint8_t *)request,length,deadline);if(s!=BRIDGE_OK)return s;}
    const char *action=NULL;
    if(post){char prefix[64];snprintf(prefix,sizeof prefix,"token=%s&action=",http->token);size_t n=strlen(prefix);
        if(strlen(http->token)!=32 || strlen(request)!=length || strncmp(request,prefix,n))return respond(io,400,"Invalid token",deadline);
        action=request+n;if(strcmp(action,"STATUS") && strcmp(action,"CHECK4") && strcmp(action,"CHECK6") && strcmp(action,"LOCKDOWN"))return respond(io,400,"Unsupported action",deadline);
    }
    int n=snprintf(body,cap,"<!doctype html><html lang=en><meta name=viewport content=\"width=device-width,initial-scale=1\"><title>NCM developer entry probe</title><h1>NCM developer entry probe</h1><p>Idle until you submit. Confirm this S3 and iPhone are free. Queries target this USB link only. No pairing keys, screen access or input.</p><form method=post action=/probe><input type=hidden name=token value=\"%s\"><button name=action value=STATUS>Status</button> <button name=action value=CHECK4>IPv4 discovery + greeting</button> <button name=action value=CHECK6>IPv6 discovery + greeting</button> <button name=action value=LOCKDOWN>Lockdown QueryType</button></form><p>No response proves authentication or control.</p><pre>",http->token);
    if(n<0 || (size_t)n>=cap)return BRIDGE_E_LIMIT;
    if(action){char reply[ND_REPLY_LIMIT];const char *command=!strcmp(action,"CHECK4")?"DISCOVER4":!strcmp(action,"CHECK6")?"DISCOVER6":action;
        bridge_status s=nd_server_command(server,link,command,reply,sizeof reply);if(s!=BRIDGE_OK)return s;if(!escape(body,cap,reply))return BRIDGE_E_LIMIT;
        if(!strncmp(action,"CHECK",5)){for(size_t i=0;i<server->count;i++){if(server->endpoints[i].service!=ND_REMOTE_PAIRING)continue;
            char probe[64];snprintf(probe,sizeof probe,"PROBE %"PRIu32" %zu",server->generation,i);
            s=nd_server_command(server,link,probe,reply,sizeof reply);if(s!=BRIDGE_OK)return s;if(!escape(body,cap,reply))return BRIDGE_E_LIMIT;break;}}
    }
    if(!append(body,cap,"</pre></html>"))return BRIDGE_E_LIMIT;
    return respond(io,200,body,nd_now(NULL)+1000);
}
