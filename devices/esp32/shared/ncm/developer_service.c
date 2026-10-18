/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "developer_service.h"
#include "nd_server.h"
#include "nd_http.h"
#include "nd_relay.h"
#include "esp_random.h"
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include <fcntl.h>
#include <string.h>
static bool (*usb_online_callback)(void);
static uint32_t (*usb_epoch_callback)(void);
static uint32_t usb_interface_index;
static void rotate(nd_http *http) { uint8_t nonce[16]; esp_fill_random(nonce,sizeof nonce);for(size_t i=0;i<sizeof nonce;i++)snprintf(http->token+2*i,3,"%02x",nonce[i]); }
static bool alive(void *context) { return usb_online_callback() && usb_epoch_callback()==*(uint32_t *)context; }
typedef struct { nd_relay_job job; int fd; } relay_worker;
static void relay_task(void *arg) { relay_worker *w=arg;(void)nd_relay_run(&w->job,w->fd,NULL);vTaskDelete(NULL); }
static void serve(void *unused) {
    (void)unused;
    int listener=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);
    ESP_ERROR_CHECK(listener<0?ESP_FAIL:ESP_OK);
    struct sockaddr_in address={.sin_family=AF_INET,.sin_port=htons(28767)};
    inet_pton(AF_INET,"192.168.7.1",&address.sin_addr);
    ESP_ERROR_CHECK(bind(listener,(struct sockaddr *)&address,sizeof address)?ESP_FAIL:ESP_OK);
    ESP_ERROR_CHECK(listen(listener,1)?ESP_FAIL:ESP_OK);
    ESP_ERROR_CHECK(fcntl(listener,F_SETFL,O_NONBLOCK)<0?ESP_FAIL:ESP_OK);
    static nd_server server; static nd_http http; static char output[ND_HTTP_BODY_LIMIT]; rotate(&http);
    static nd_relay relay; static relay_worker workers[2];
    uint32_t epoch=usb_epoch_callback(),relay_epoch=epoch;
    nd_link link={.local4={192,168,7,1},.peer4={192,168,7,2},.interface_index=usb_interface_index,.alive=alive,.context=&epoch};
    ESP_LOGI("pa_developer","Developer-service diagnostics / bounded relay; no stored keys or radio; idle until command");
    for (;;) {
        if (usb_epoch_callback()!=epoch) { nd_relay_cancel(&relay); epoch=usb_epoch_callback(); nd_server_reset(&server); rotate(&http); }
        if (usb_online_callback()) {
            struct sockaddr_in peer={0}; socklen_t length=sizeof peer;
            int fd=accept(listener,(struct sockaddr *)&peer,&length);
            if (fd>=0) {
                if (memcmp(&peer.sin_addr,link.peer4,4) || fcntl(fd,F_SETFL,O_NONBLOCK)<0) { close(fd); continue; }
                nd_socket socket={.fd=fd,.link=&link}; bridge_io io=nd_socket_io(&socket);
                char command[ND_RELAY_LINE_LIMIT+1]; size_t n=0; uint64_t deadline=nd_now(NULL)+3000; bool complete=false;
                while (n<ND_RELAY_LINE_LIMIT) {
                    uint8_t ch=0; if (bridge_read_exact(&io,&ch,1,deadline)!=BRIDGE_OK) break;
                    if (ch=='\n') { complete=true; break; }
                    if (ch=='\r') { if(bridge_read_exact(&io,&ch,1,deadline)==BRIDGE_OK && ch=='\n')complete=true; break; }
                    if (ch<32 || ch>126) break;
                    command[n++]=(char)ch;
                }
                command[n]=0;
                if(complete && (!strncmp(command,"NR1 ",4)||!strncmp(command,"NL1 ",4))) {
                    nd_relay_job cancellation={0};
                    relay_worker *w=(!strncmp(command,"NR1 OPEN ",9)||!strncmp(command,"NL1 OPEN ",9))?&workers[0]:!strncmp(command,"NR1 TUNNEL ",11)?&workers[1]:NULL;
                    if(!nd_relay_busy(&relay))relay_epoch=epoch;
                    nd_link pinned=link;pinned.context=&relay_epoch;
                    bridge_status result=nd_relay_prepare(&relay,&server,&pinned,command,w?&w->job:&cancellation);
                    if(result==BRIDGE_OK && w) {
                        w->fd=fd;
                        if(xTaskCreate(relay_task,"ncm_relay",8192,w,4,NULL)==pdPASS)socket.fd=-1;
                        else nd_relay_abandon(&w->job);
                    } else {
                        bool lockdown=command[1]=='L';
                        const char *reply=lockdown?(result==BRIDGE_OK?"NL1 OK\n":"NL1 ERR rejected\n"):(result==BRIDGE_OK?"NR1 OK\n":"NR1 ERR rejected\n");
                        (void)bridge_write_exact(&io,(const uint8_t *)reply,strlen(reply),nd_now(NULL)+500);
                    }
                }
                else if(complete && (strstr(command," HTTP/")!=NULL)) {
                    bridge_status result=nd_http_serve(&http,&server,&link,&io,command,output,sizeof output,deadline);
                    ESP_LOGI("ncm_http","%s result=%s socketError=%d",!strncmp(command,"POST ",5)?"POST":"GET",bridge_status_name(result),socket.error);
                }
                else if (complete && nd_server_command(&server,&link,command,output,sizeof output)==BRIDGE_OK)
                    (void)bridge_write_exact(&io,(const uint8_t *)output,strlen(output),nd_now(NULL)+1000);
                nd_socket_close(&socket);
            }
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}
esp_err_t developer_service_start(bool (*online)(void), uint32_t (*epoch)(void), uint32_t interface_index) {
    if (!online || !epoch || !interface_index) return ESP_ERR_INVALID_ARG;
    usb_online_callback=online; usb_epoch_callback=epoch; usb_interface_index=interface_index;
    return xTaskCreate(serve,"ncm_developer",32768,NULL,4,NULL)==pdPASS ? ESP_OK : ESP_ERR_NO_MEM;
}
