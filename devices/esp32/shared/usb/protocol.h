#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define PA_LINE_MAX 256
#define PA_HISTORY 32
#define PA_LEASE_MS 750

typedef enum { PA_PING, PA_STOP, PA_TAP, PA_DRAG } pa_kind;
typedef struct { uint32_t id, generation; pa_kind kind; uint16_t x,y,tx,ty,duration; } pa_command;
typedef enum { PA_RECEIVED, PA_EXECUTED, PA_CANCELLED } pa_phase;
typedef struct { bool valid; pa_phase phase; pa_command command; } pa_receipt;
typedef struct { uint32_t highest; pa_receipt entries[PA_HISTORY]; size_t cursor; } pa_ledger;
// 1=new, 0=identical duplicate (receipt returned), -1=replay/conflict/invalid.
int pa_accept(pa_ledger *ledger, const pa_command *command, pa_receipt **receipt);
bool pa_parse(const char *body, pa_command *command);
void pa_complete(pa_ledger *ledger, uint32_t id);
void pa_cancel(pa_ledger *ledger, uint32_t id);
const char *pa_phase_name(pa_phase phase);
