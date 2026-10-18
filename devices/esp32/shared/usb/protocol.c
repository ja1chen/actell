#include "protocol.h"
#include <string.h>
#include <limits.h>
static bool number(const char **s, uint32_t *n) {
    if (**s < '0' || **s > '9') return false;
    *n=0;
    if (**s=='0' && (*s)[1]>='0' && (*s)[1]<='9') return false;
    while (**s>='0' && **s<='9') {
        unsigned digit=(unsigned)(*(*s)++-'0');
        if (*n > (UINT32_MAX-digit)/10) return false;
        *n=*n*10+digit;
    }
    return true;
}
bool pa_parse(const char *s, pa_command *c) {
    memset(c,0,sizeof(*c));
    if (!number(&s,&c->id) || !c->id || *s++!=' ') return false;
    if (!strcmp(s,"PING")) { c->kind=PA_PING; return true; }
    if (!strncmp(s,"STOP ",5)) {
        c->kind=PA_STOP; s+=5;
        return number(&s,&c->generation) && c->generation && !*s;
    }
    size_t count;
    if (!strncmp(s,"TAP ",4)) { c->kind=PA_TAP; s+=4; count=2; }
    else if (!strncmp(s,"DRAG ",5)) { c->kind=PA_DRAG; s+=5; count=5; }
    else return false;
    if (!number(&s,&c->generation) || !c->generation || *s++!=' ') return false;
    uint32_t values[5]={0};
    for (size_t i=0;i<count;i++) {
        if (!number(&s,&values[i]) || values[i]>65535) return false;
        if (i+1<count && *s++!=' ') return false;
    }
    if (*s) return false;
    c->x=values[0]; c->y=values[1]; c->tx=values[2]; c->ty=values[3]; c->duration=values[4];
    return c->kind==PA_TAP || (c->duration>=100 && c->duration<=2000);
}
static bool same(const pa_command *a,const pa_command *b) {
    return a->id==b->id && a->generation==b->generation && a->kind==b->kind && a->x==b->x && a->y==b->y && a->tx==b->tx && a->ty==b->ty && a->duration==b->duration;
}
int pa_accept(pa_ledger *l,const pa_command *c,pa_receipt **receipt) {
    for (size_t i=0;i<PA_HISTORY;i++) if (l->entries[i].valid && l->entries[i].command.id==c->id) {
        *receipt=&l->entries[i]; return same(&l->entries[i].command,c) ? 0 : -1;
    }
    if (!c->id || c->id<=l->highest) return -1;
    // Never evict an input that has not reached a terminal ACK.
    pa_receipt *r=&l->entries[l->cursor];
    if (r->valid && r->phase==PA_RECEIVED) return -1;
    l->highest=c->id; l->cursor=(l->cursor+1)%PA_HISTORY;
    *r=(pa_receipt){.valid=true,.command=*c}; *receipt=r; return 1;
}
void pa_complete(pa_ledger *l,uint32_t id) {
    for (size_t i=0;i<PA_HISTORY;i++) if (l->entries[i].valid && l->entries[i].command.id==id) l->entries[i].phase=PA_EXECUTED;
}
void pa_cancel(pa_ledger *l,uint32_t id) {
    for (size_t i=0;i<PA_HISTORY;i++) if (l->entries[i].valid && l->entries[i].command.id==id) l->entries[i].phase=PA_CANCELLED;
}
const char *pa_phase_name(pa_phase phase) {
    return phase==PA_EXECUTED ? "executed" : (phase==PA_CANCELLED ? "cancelled":"received");
}
