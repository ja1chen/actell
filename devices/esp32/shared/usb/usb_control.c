#include "usb_device.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "lwip/sockets.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

static const char *TAG="pa_device";
static int client=-1;
static char buffer[PA_LINE_MAX+1];
static size_t used;
static pa_ledger ledger;
static int64_t last_packet,last_ping,action_started;
static uint32_t action_id,stop_id,cancelled_id,input_generation=1;
static int64_t milliseconds(void) { return esp_timer_get_time()/1000; }
static void close_client(void) {
    usb_hid_cancel();
    if (client>=0) { shutdown(client,SHUT_RDWR); close(client); client=-1; }
    used=0; action_id=stop_id=cancelled_id=0; input_generation=1; memset(&ledger,0,sizeof(ledger));
}
static bool send_line(const char *line) {
    size_t length=strlen(line),offset=0;
    int64_t deadline=milliseconds()+100;
    while (offset<length && client>=0) {
        int n=send(client,line+offset,length-offset,0);
        if (n>0) { offset+=n; continue; }
        if ((errno==EAGAIN || errno==EWOULDBLOCK) && milliseconds()<deadline) { vTaskDelay(1); continue; }
        close_client(); return false;
    }
    return client>=0;
}
static bool reply(const char *payload) {
    char wire[256];
    snprintf(wire,sizeof(wire),"%s\n",payload); return send_line(wire);
}
static bool acknowledge(uint32_t id,const char *status) {
    char payload[64]; snprintf(payload,sizeof(payload),"%"PRIu32" %s",id,status); return reply(payload);
}
static void hello(void) {
    // Explicit no-PSK version: no credential provisioning or NVS access.
    reply(usb_hid_enabled() ? "PA3 READY 1":"PA3 READY 0");
    last_packet=milliseconds(); last_ping=0;
}
static bool process_line(char *line,int64_t now) {
    if (strlen(line)>128) return false;
    pa_command command;
    if (!pa_parse(line,&command)) return false;
    pa_receipt *receipt=NULL;
    int accepted=pa_accept(&ledger,&command,&receipt);
    if (accepted<0) return false;
    if (!accepted) {
        // STOP has one terminal ACK after neutral reports, never an early receipt.
        if (command.kind==PA_STOP && receipt->phase==PA_RECEIVED) return true;
        return acknowledge(command.id,pa_phase_name(receipt->phase));
    }
    last_packet=now;
    if (command.kind==PA_PING) {
        last_ping=now; pa_complete(&ledger,command.id); return acknowledge(command.id,"executed");
    }
    // STOP revokes this input generation immediately, including bytes already
    // queued in TCP. Rejected commands never mutate motion or the stop deadline.
    if (command.generation!=input_generation || stop_id) {
        pa_cancel(&ledger,command.id); return acknowledge(command.id,"cancelled");
    }
    if (command.kind==PA_STOP) {
        if (input_generation==UINT32_MAX) return false;
        ++input_generation;
        usb_hid_cancel(); cancelled_id=action_id; action_id=0;
        stop_id=command.id; action_started=now; return true;
    }
    if (action_id || !last_ping || now-last_ping>PA_LEASE_MS || !usb_hid_start(&command,now)) {
        pa_cancel(&ledger,command.id); return acknowledge(command.id,"cancelled");
    }
    action_id=command.id; action_started=now;
    return acknowledge(command.id,"received");
}
void usb_control_run(void) {
    int listener=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);
    ESP_ERROR_CHECK(listener<0 ? ESP_FAIL:ESP_OK);
    struct sockaddr_in address={.sin_family=AF_INET,.sin_port=htons(28766)};
    inet_pton(AF_INET,"192.168.7.1",&address.sin_addr);
    ESP_ERROR_CHECK(bind(listener,(struct sockaddr*)&address,sizeof(address)) ? ESP_FAIL:ESP_OK);
    ESP_ERROR_CHECK(listen(listener,1) ? ESP_FAIL:ESP_OK);
    fcntl(listener,F_SETFL,O_NONBLOCK);
    ESP_LOGI(TAG,"NCM %s; 192.168.7.1:28766; USB control persistent; no PSK/radio/DHCP/default route",usb_hid_enabled()?"+ HID":"only");
    uint32_t epoch=usb_epoch();
    for (;;) {
        int64_t now=milliseconds();
        uint32_t current_epoch=usb_epoch();
        if (epoch!=current_epoch) { close_client(); epoch=current_epoch; }
        if (client>=0 && (!usb_online() ||
            now-last_packet>60000 || (action_id && (now-last_ping>PA_LEASE_MS || now-action_started>2500)) ||
            (stop_id && now-action_started>500))) close_client();
        usb_hid_tick(now);
        uint32_t done=usb_hid_completed();
        if (client>=0 && done && done==action_id) {
            pa_complete(&ledger,done); action_id=0; acknowledge(done,"executed");
        }
        if (client>=0 && stop_id && usb_hid_neutral()) {
            // An interrupted input may have partially acted. Its terminal status
            // is cancelled, never executed; acknowledge only after HID release.
            if (cancelled_id) {
                uint32_t id=cancelled_id; cancelled_id=0; pa_cancel(&ledger,id);
                if (!acknowledge(id,"cancelled")) continue;
            }
            uint32_t id=stop_id; stop_id=0; pa_complete(&ledger,id); acknowledge(id,"executed");
            // TCP and the command ledger outlive tasks. Next input uses the
            // incremented generation, not a new connection or reset command ID.
        }
        if (client<0) {
            if (usb_online() && usb_hid_neutral()) {
                client=accept(listener,NULL,NULL);
                if (client>=0) {
                    fcntl(client,F_SETFL,O_NONBLOCK);
                    int nodelay=1; setsockopt(client,IPPROTO_TCP,TCP_NODELAY,&nodelay,sizeof(nodelay));
                    hello();
                }
            }
        } else {
            // Continue draining complete lines during release. PING remains
            // available; input/STOP for a revoked generation gets cancelled.
            char input[128]; int count=recv(client,input,sizeof(input),0);
            if (count==0 || (count<0 && errno!=EAGAIN && errno!=EWOULDBLOCK)) close_client();
            for (int i=0;i<count && client>=0;i++) {
                if (input[i]=='\n') {
                    buffer[used]=0; used=0;
                    if (!process_line(buffer,now)) close_client();
                } else if (used>=PA_LINE_MAX || input[i]<32 || input[i]>126) close_client();
                else buffer[used++]=input[i];
            }
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}
