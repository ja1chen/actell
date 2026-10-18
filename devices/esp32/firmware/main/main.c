#include "sdkconfig.h"
#include "usb_device.h"
#include "developer_service.h"

void app_main(void) {
    ESP_ERROR_CHECK(usb_network_start());
    ESP_ERROR_CHECK(developer_service_start(usb_online, usb_epoch, usb_network_index()));
#if CONFIG_USB_CONTROL_ENABLED
    usb_control_run();
#endif
}
