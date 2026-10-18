#include "usb_device.h"
#include "hid_motion.h"
#include "tinyusb.h"
#include "tinyusb_default_config.h"
#include "tusb.h"
#include <stdatomic.h>

#if CFG_TUD_HID
static const uint8_t reports[]={
    TUD_HID_REPORT_DESC_ABSMOUSE(HID_REPORT_ID(1)),
    TUD_HID_REPORT_DESC_KEYBOARD(HID_REPORT_ID(2))
};
#endif
static const tusb_desc_device_t device={
    .bLength=sizeof(tusb_desc_device_t), .bDescriptorType=TUSB_DESC_DEVICE,.bcdUSB=0x0200,
    .bDeviceClass=TUSB_CLASS_MISC,.bDeviceSubClass=MISC_SUBCLASS_COMMON,.bDeviceProtocol=MISC_PROTOCOL_IAD,
    .bMaxPacketSize0=64,.idVendor=0x303a,.idProduct=(CFG_TUD_HID ? 0x4006 : 0x4002),
    .bcdDevice=0x0100,.iManufacturer=1,.iProduct=2,.iSerialNumber=0,.bNumConfigurations=1
};
static const uint8_t configuration[]={
    TUD_CONFIG_DESCRIPTOR(1,2+CFG_TUD_HID,0,TUD_CONFIG_DESC_LEN+TUD_CDC_NCM_DESC_LEN+(CFG_TUD_HID ? TUD_HID_DESC_LEN:0),0,100),
    TUD_CDC_NCM_DESCRIPTOR(0,4,5,0x81,64,0x02,0x82,64,1514),
#if CFG_TUD_HID
    TUD_HID_DESCRIPTOR(2,6,HID_ITF_PROTOCOL_NONE,sizeof(reports),0x83,16,5),
#endif
};
static const char *strings[]={ (const char[]){0x09,0x04},"PhoneAgent development","PhoneAgent NCM","unused","USB Ethernet","020000000002","Confirmed HID" };
static atomic_uint bus_epoch;
static atomic_bool online;
#if CFG_TUD_HID
static atomic_uint report_done;
static uint32_t consumed_report;
#endif
static pa_motion motion={.phase=HID_CANCEL_MOUSE};
static void event(tinyusb_event_t *e,void *unused) {
    (void)unused;
    atomic_fetch_add(&bus_epoch,1);
    atomic_store(&online,e->id==TINYUSB_EVENT_ATTACHED || e->id==TINYUSB_EVENT_RESUMED);
}
void usb_install(void) {
    tinyusb_config_t config=TINYUSB_DEFAULT_CONFIG();
    config.descriptor.device=&device; config.descriptor.full_speed_config=configuration;
    config.descriptor.string=strings; config.descriptor.string_count=sizeof(strings)/sizeof(strings[0]);
    config.phy.self_powered=false; config.event_cb=event;
    ESP_ERROR_CHECK(tinyusb_driver_install(&config));
}
uint32_t usb_epoch(void) { return atomic_load(&bus_epoch); }
bool usb_online(void) { return atomic_load(&online); }
bool usb_hid_enabled(void) { return CFG_TUD_HID>0; }
void usb_hid_cancel(void) { pa_motion_cancel(&motion); }
bool usb_hid_neutral(void) { return motion.phase==HID_IDLE; }
uint32_t usb_hid_completed(void) { uint32_t id=motion.completed; motion.completed=0; return id; }
bool usb_hid_start(const pa_command *c,int64_t now) {
    (void)now;
    return CFG_TUD_HID && usb_online() && pa_motion_start(&motion,c);
}
void usb_hid_tick(int64_t now) {
#if CFG_TUD_HID
    if (!usb_online()) return;
    uint32_t done=atomic_load(&report_done);
    if (motion.waiting && done!=consumed_report) pa_motion_ack(&motion,now);
    pa_report report;
    if (!pa_motion_next(&motion,now,&report) || !tud_hid_ready()) return;
    consumed_report=atomic_load(&report_done);
    bool accepted;
    if (report.keyboard) { uint8_t keys[6]={0}; accepted=tud_hid_n_keyboard_report(0,2,0,keys); }
    else accepted=tud_hid_n_abs_mouse_report(0,1,report.buttons,report.x/2,report.y/2,0,0);
    if (accepted) pa_motion_sent(&motion,&report,now);
#else
    (void)now; motion.phase=HID_IDLE;
#endif
}
#if CFG_TUD_HID
uint8_t const *tud_hid_descriptor_report_cb(uint8_t instance) { (void)instance; return reports; }
uint16_t tud_hid_get_report_cb(uint8_t instance,uint8_t id,hid_report_type_t type,uint8_t *buffer,uint16_t len) {
    (void)instance;(void)id;(void)type;(void)buffer;(void)len; return 0;
}
void tud_hid_set_report_cb(uint8_t instance,uint8_t id,hid_report_type_t type,uint8_t const *buffer,uint16_t len) {
    (void)instance;(void)id;(void)type;(void)buffer;(void)len;
}
void tud_hid_report_complete_cb(uint8_t instance,uint8_t const *report,uint16_t len) {
    (void)instance;(void)report;(void)len; atomic_fetch_add(&report_done,1);
}
#endif
