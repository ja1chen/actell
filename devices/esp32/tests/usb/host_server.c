// Runs production main.c and its ledger/motion on POSIX TCP. USB is simulated.
#include "usb_device.h"
#include "developer_service.h"
#include "hid_motion.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <signal.h>
static pa_motion motion;
static bool hid_enabled;
static volatile sig_atomic_t bus_epoch, stall_release;
static void toggle_release_stall(int signal) { (void)signal; stall_release=!stall_release; }
static void suspend_resume(int signal) { (void)signal; bus_epoch++; }
int64_t esp_timer_get_time(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec*1000000LL+t.tv_nsec/1000; }
esp_err_t usb_network_start(void) { hid_enabled=getenv("PA_TEST_HID")!=NULL; return ESP_OK; }
// This harness exercises USB input only; developer-service streams have separate relay tests.
esp_err_t developer_service_start(bool (*online)(void), uint32_t (*epoch)(void), uint32_t index) {
    (void)online; (void)epoch; (void)index; return ESP_OK;
}
uint32_t usb_network_index(void) { return 1; }
uint32_t usb_epoch(void) { return (uint32_t)bus_epoch; }
bool usb_online(void) { return true; }
bool usb_hid_enabled(void) { return hid_enabled; }
bool usb_hid_start(const pa_command *c,int64_t now) { (void)now;return hid_enabled && pa_motion_start(&motion,c); }
void usb_hid_cancel(void) { pa_motion_cancel(&motion); }
void usb_hid_tick(int64_t now) {
    if (!hid_enabled) { motion.phase=HID_IDLE;return; }
    if (stall_release && (motion.phase==HID_CANCEL_MOUSE || motion.phase==HID_CANCEL_KEYS)) return;
    // Simulated USB host completes exactly one queued report per iteration.
    if (motion.waiting) pa_motion_ack(&motion,now);
    pa_report report;
    if (pa_motion_next(&motion,now,&report)) pa_motion_sent(&motion,&report,now);
}
bool usb_hid_neutral(void) { return motion.phase==HID_IDLE; }
uint32_t usb_hid_completed(void) { uint32_t id=motion.completed;motion.completed=0;return id; }
void app_main(void);
int main(void) { signal(SIGPIPE,SIG_IGN); signal(SIGUSR1,suspend_resume); signal(SIGUSR2,toggle_release_stall); app_main(); }
