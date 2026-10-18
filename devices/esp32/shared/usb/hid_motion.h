#pragma once
#include "protocol.h"
typedef enum { HID_IDLE, HID_CANCEL_MOUSE, HID_CANCEL_KEYS, HID_POSITION, HID_PRESS, HID_DRAG, HID_RELEASE } pa_hid_phase;
typedef struct { bool keyboard; uint8_t buttons; uint16_t x,y; pa_hid_phase after_ack; } pa_report;
typedef struct {
    pa_hid_phase phase,after_ack;
    pa_command command;
    bool waiting;
    int64_t started,sent_at;
    uint16_t x,y;
    uint32_t completed;
} pa_motion;
void pa_motion_cancel(pa_motion *m);
bool pa_motion_start(pa_motion *m,const pa_command *c);
bool pa_motion_next(pa_motion *m,int64_t now,pa_report *report);
void pa_motion_sent(pa_motion *m,const pa_report *report,int64_t now);
void pa_motion_ack(pa_motion *m,int64_t now);
