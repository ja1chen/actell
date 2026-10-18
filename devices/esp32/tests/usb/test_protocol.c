#include "protocol.h"
#include "hid_motion.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static pa_command parse(const char *line) { pa_command c; assert(pa_parse(line,&c)); return c; }
static pa_report transfer(pa_motion *m,int64_t now) {
    pa_report r; assert(pa_motion_next(m,now,&r)); pa_motion_sent(m,&r,now);
    assert(!pa_motion_next(m,now+1,&r)); pa_motion_ack(m,now+10); return r;
}
int main(void) {
    const char *invalid[]={"0 PING","01 PING","4294967296 PING","-1 PING","1 PING ","1 TAP 1 65536 0","1 TAP 1 true 0","1 TAP 1 1 2 3","1 DRAG 1 0 0 1 1 99","1 DRAG 1 0 0 1 1 2001","1 STOP", "1 STOP 0", "1 STOP 01", "1 STOP 4294967296", "1 STOP 1 2", "1 TAP 0 0 0", "1\tSTOP","1 STOP\n","1 tap 0 0","1 TAP 1 00 1"};
    for (size_t i=0;i<sizeof(invalid)/sizeof(invalid[0]);i++) { pa_command c; assert(!pa_parse(invalid[i],&c)); }
    pa_command edge=parse("4294967295 TAP 1 65535 65535"); assert(edge.id==UINT32_MAX && edge.x==65535);
    pa_ledger l={0}; pa_receipt *r;
    pa_command c=parse("1 TAP 1 0 65535");
    assert(pa_accept(&l,&c,&r)==1 && r->phase==PA_RECEIVED);
    assert(pa_accept(&l,&c,&r)==0 && r->phase==PA_RECEIVED);
    c.y=1; assert(pa_accept(&l,&c,&r)==-1); c.y=65535;
    pa_complete(&l,1); assert(pa_accept(&l,&c,&r)==0 && r->phase==PA_EXECUTED);
    for (uint32_t i=2;i<40;i++) { pa_command ping={.id=i,.kind=PA_PING}; assert(pa_accept(&l,&ping,&r)==1); pa_complete(&l,i); }
    assert(pa_accept(&l,&c,&r)==-1); // evicted IDs can never execute again
    pa_ledger pending={0}; assert(pa_accept(&pending,&c,&r)==1);
    for (uint32_t i=2;i<=32;i++) { pa_command ping={.id=i,.kind=PA_PING}; assert(pa_accept(&pending,&ping,&r)==1); pa_complete(&pending,i); }
    pa_command wrap={.id=33,.kind=PA_PING}; assert(pa_accept(&pending,&wrap,&r)==-1);
    pa_ledger cancelled={0}; assert(pa_accept(&cancelled,&c,&r)==1);
    pa_cancel(&cancelled,c.id); assert(pa_accept(&cancelled,&c,&r)==0 && r->phase==PA_CANCELLED);
    c.generation++; assert(pa_accept(&cancelled,&c,&r)==-1); c.generation--;
    assert(parse("7 STOP 4294967295").generation==UINT32_MAX);
    puts("PASS strict parsing, bounded receipts, duplicates, conflicts, replay, unfinished eviction");

    pa_motion m={0}; assert(pa_motion_start(&m,&c));
    assert(!pa_motion_start(&m,&c));
    pa_report report=transfer(&m,0); assert(!report.buttons && report.y==65535);
    report=transfer(&m,20); assert(report.buttons==1 && !m.completed);
    assert(pa_motion_next(&m,40,&report)); assert(!report.buttons); pa_motion_sent(&m,&report,40);
    assert(!m.completed); pa_motion_ack(&m,50); assert(m.completed==1 && m.phase==HID_IDLE);
    c=parse("2 DRAG 1 65535 0 0 65535 100"); assert(pa_motion_start(&m,&c));
    transfer(&m,60); transfer(&m,80); // pressed at 90
    report=transfer(&m,140); assert(report.x==32768 && report.y==32767 && report.buttons==1);
    report=transfer(&m,190); assert(report.x==0 && report.y==65535 && report.buttons==1);
    assert(!m.completed); report=transfer(&m,210); assert(!report.buttons && m.completed==2);
    puts("PASS tap/drag ordering, endpoints, executed only after release transfer completion");

    assert(pa_motion_start(&m,&c)); transfer(&m,230); transfer(&m,250);
    pa_motion_cancel(&m); report=transfer(&m,270); assert(!report.buttons && !report.keyboard && !m.completed);
    report=transfer(&m,290); assert(report.keyboard && m.phase==HID_IDLE && !m.completed);
    assert(pa_motion_start(&m,&c)); assert(pa_motion_next(&m,320,&report)); pa_motion_sent(&m,&report,320);
    assert(pa_motion_next(&m,571,&report)); assert(!report.buttons && m.phase==HID_CANCEL_MOUSE && !m.completed);
    puts("PASS cancel releases mouse and keys; transfer timeout never acknowledges execution");
    return 0;
}
