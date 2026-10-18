#include "usb_device.h"
#include "esp_netif.h"
#include "esp_mac.h"
#include "freertos/FreeRTOS.h"
#include "tinyusb_net.h"
#include "freertos/semphr.h"
#include "lwip/netif.h"
#include "lwip/tcpip.h"
#include "lwip/etharp.h"
#include "lwip/ethip6.h"
#include "netif/ethernet.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

static struct netif local_net;
static uint8_t mac[6];
static SemaphoreHandle_t initialized;
static atomic_bool net_ready;
static err_t transmit(struct netif *net, struct pbuf *packet) {
    (void)net;
    if (packet->tot_len>1514 || !usb_online()) return ERR_IF;
    void *copy=malloc(packet->tot_len);
    if (!copy) return ERR_MEM;
    pbuf_copy_partial(packet,copy,packet->tot_len,0);
    // Bounded synchronous send: copied buffer stays valid until TinyUSB consumed it.
    esp_err_t result=tinyusb_net_send_sync(copy,packet->tot_len,NULL,pdMS_TO_TICKS(50));
    free(copy);
    return result==ESP_OK ? ERR_OK : ERR_IF;
}
static err_t setup(struct netif *net) {
    net->name[0]='u'; net->name[1]='s'; net->output=etharp_output; net->linkoutput=transmit;
    net->output_ip6=ethip6_output;
    net->mtu=1500; net->hwaddr_len=6; memcpy(net->hwaddr,mac,6);
    net->flags=NETIF_FLAG_BROADCAST|NETIF_FLAG_ETHARP|NETIF_FLAG_ETHERNET|NETIF_FLAG_IGMP|NETIF_FLAG_MLD6;
    return ERR_OK;
}
static void add_netif(void *unused) {
    (void)unused;
    ip4_addr_t ip,mask,gw; IP4_ADDR(&ip,192,168,7,1); IP4_ADDR(&mask,255,255,255,0); ip4_addr_set_zero(&gw);
    if (netif_add(&local_net,&ip,&mask,&gw,NULL,setup,tcpip_input)) {
        netif_create_ip6_linklocal_address(&local_net,1);
        netif_set_up(&local_net); netif_set_link_up(&local_net); atomic_store(&net_ready,true);
    }
    // No DHCP, default netif, DNS, NAT or forwarding. This is a directly attached subnet.
    xSemaphoreGive(initialized);
}
static esp_err_t receive_packet(void *data,uint16_t len,void *ctx) {
    (void)ctx;
    if (!atomic_load(&net_ready) || len>1514 || len<14) return ESP_FAIL;
    struct pbuf *p=pbuf_alloc(PBUF_RAW,len,PBUF_POOL);
    if (!p) return ESP_ERR_NO_MEM;
    if (pbuf_take(p,data,len)!=ERR_OK || local_net.input(p,&local_net)!=ERR_OK) { pbuf_free(p); return ESP_FAIL; }
    return ESP_OK;
}
esp_err_t usb_network_start(void) {
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_read_mac(mac,ESP_MAC_EFUSE_FACTORY));
    mac[0]=(mac[0]|2)&0xfe;
    initialized=xSemaphoreCreateBinary();
    if (!initialized) return ESP_ERR_NO_MEM;
    if (tcpip_callback(add_netif,NULL)!=ERR_OK) return ESP_FAIL;
    if (xSemaphoreTake(initialized,pdMS_TO_TICKS(2000))!=pdTRUE || !atomic_load(&net_ready)) return ESP_FAIL;
    vSemaphoreDelete(initialized);
    usb_install();
    tinyusb_net_config_t config={.on_recv_callback=receive_packet};
    memcpy(config.mac_addr,mac,6); config.mac_addr[5]^=1; // Host peer has a different MAC.
    return tinyusb_net_init(&config);
}

uint32_t usb_network_index(void) { return netif_get_index(&local_net); }
