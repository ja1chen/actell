#include "hid_motion.h"
void pa_motion_cancel(pa_motion *m) {
    m->phase=HID_CANCEL_MOUSE; m->waiting=false; m->command.id=0; m->completed=0;
}
bool pa_motion_start(pa_motion *m,const pa_command *c) {
    if (m->phase!=HID_IDLE || (c->kind!=PA_TAP && c->kind!=PA_DRAG)) return false;
    m->command=*c; m->phase=HID_POSITION; m->completed=0; return true;
}
bool pa_motion_next(pa_motion *m,int64_t now,pa_report *r) {
    if (m->waiting && now-m->sent_at>250) pa_motion_cancel(m);
    if (m->waiting || m->phase==HID_IDLE) return false;
    *r=(pa_report){.x=m->x,.y=m->y};
    switch (m->phase) {
    case HID_CANCEL_MOUSE: r->after_ack=HID_CANCEL_KEYS; break;
    case HID_CANCEL_KEYS: r->keyboard=true; r->after_ack=HID_IDLE; break;
    case HID_POSITION:
        r->x=m->command.x; r->y=m->command.y; r->after_ack=HID_PRESS; break;
    case HID_PRESS:
        r->buttons=1; r->after_ack=m->command.kind==PA_DRAG ? HID_DRAG:HID_RELEASE; break;
    case HID_DRAG: {
        int64_t elapsed=now-m->started;
        if (elapsed<0) elapsed=0;
        if (elapsed>m->command.duration) elapsed=m->command.duration;
        r->x=m->command.x+((int32_t)m->command.tx-m->command.x)*elapsed/m->command.duration;
        r->y=m->command.y+((int32_t)m->command.ty-m->command.y)*elapsed/m->command.duration;
        r->buttons=1; r->after_ack=elapsed==m->command.duration ? HID_RELEASE:HID_DRAG;
        break;
    }
    case HID_RELEASE: r->after_ack=HID_IDLE; break;
    default: return false;
    }
    return true;
}
void pa_motion_sent(pa_motion *m,const pa_report *r,int64_t now) {
    m->waiting=true; m->after_ack=r->after_ack; m->sent_at=now; m->x=r->x; m->y=r->y;
}
void pa_motion_ack(pa_motion *m,int64_t now) {
    if (!m->waiting) return;
    m->waiting=false;
    if (m->phase==HID_PRESS) m->started=now;
    if (m->phase==HID_RELEASE) { m->completed=m->command.id; m->command.id=0; }
    m->phase=m->after_ack;
}
