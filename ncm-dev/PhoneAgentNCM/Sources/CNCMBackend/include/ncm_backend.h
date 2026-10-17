/* SPDX-License-Identifier: GPL-3.0-only */
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define NCM_BACKEND_ABI 1
#define NCM_ALLOW_SCREEN 1u
#define NCM_ALLOW_MEDIA 2u
#define NCM_ALLOW_INPUT 4u
#define NCM_ALLOW_EXISTING_VERIFY 8u
/* All pointers are borrowed only for start(); caller owns/clears its secrets.
 * No disk/keychain lookup, identity generation, pairing or logging occurs. */
typedef struct { const uint8_t *data; size_t size; } ncm_bytes;
typedef struct {
    ncm_bytes seed, controller_id, peer_id, peer_public_key, alt_irk, peer_udid, peer_model;
} ncm_identity;
typedef struct { uint32_t abi,interface_index,generation,endpoint_index,permissions; } ncm_config;
enum ncm_failure_stage { NCM_STAGE_IDENTITY=1, NCM_STAGE_NCM_CONNECT=2, NCM_STAGE_PAIR_VERIFY=3, NCM_STAGE_TUNNEL_LISTENER=4, NCM_STAGE_TLS_TUNNEL=5, NCM_STAGE_RSD=6, NCM_STAGE_DEVELOPER_MODE=7, NCM_STAGE_DEVELOPER_IMAGE=8, NCM_STAGE_SCREENSHOT=9, NCM_STAGE_MEDIA=10, NCM_STAGE_INPUT=11, NCM_STAGE_CLOSED=12, NCM_STAGE_VIDEO_RECEIVER=13, NCM_STAGE_VIDEO_SERVICE=14, NCM_STAGE_VIDEO_NEGOTIATION=15, NCM_STAGE_VIDEO_ANSWER=16, NCM_STAGE_VIDEO_PACKETS=17, NCM_STAGE_TOUCH_SERVICE=18, NCM_STAGE_SCREENSHOT_CONNECTION=19, NCM_STAGE_SCREENSHOT_RESPONSE=20, NCM_STAGE_APPLICATIONS=21 };
enum ncm_failure_cause { NCM_CAUSE_PROTOCOL=1, NCM_CAUSE_TIMEOUT=2, NCM_CAUSE_INVALID=3, NCM_CAUSE_MISSING_SERVICE=4, NCM_CAUSE_UNPREPARED=5, NCM_CAUSE_MEDIA_INACTIVE=6, NCM_CAUSE_DELIVERY_UNCERTAIN=7 };
typedef struct { uint64_t request_id; uint32_t kind,stage,cause,reserved; size_t size; } ncm_event;
/* Return codes: 0 success/queued, 1 invalid, 2 busy, 3 closed, 4 empty,
 * 5 buffer too small (event retained), 6 not ready. Errors contain no payloads.
 * Events: 1 ready (JSON service names), 2 operation written/completed,
 * 3 stage/cause failure, 4 PNG (memory only). Input event 2 never proves visible effect.
 * 10 touch video preparation failure (stage/cause, no payload): no touch has
 * been sent; scoped preparation resources closed, existing session retained.
 * 16 recovery timing (request/stage/cause 0): 1..8 records, each LE u32
 * stage, LE u32 failed (0/1), LE u64 elapsed ns. Stages in increasing order:
 * 1 pair socket, 2 PairVerify, 3 pair validation, 4 tunnel listener,
 * 5 tunnel socket, 6 tunnel TLS, 7 service socket, 8 service discovery.
 * One bounded event before ready/failure; contains no protocol data.
 * At most 2 process sessions, 1 queued request and 1 pending event per session.
 * Tokens are monotonically allocated handles, never C pointers. */
/* Independent media poll: kind 13 = complete HEVC sample, 14 = decoder reset.
 * No command receipts consumed. SCREEN permission required. Uses poll status
 * codes (EMPTY/SMALL/CLOSED). Sample = 4 LE u64 (serial, epoch, age_ms, revision),
 * 8 LE u32 (RTP timestamp, flags, width, height, VPS/SPS/PPS/AU lengths),
 * flags: bit0 sync; bit1 adds 2 LE u32 display width/height after the header.
 * Geometry is scoped to the selected peer display and validated against SPS.
 * Followed by VPS, SPS, PPS and 4-byte length-prefixed AU. Max 8 MiB. */
typedef struct {
    uint64_t datagrams, rtp, rejected, frames, discontinuities, overflows, refreshes, source_port;
} ncm_video_status;
/* SCREEN-gated snapshot; does not consume frame or command queues. */
int32_t ncm_backend_video_get_status(uint64_t handle, ncm_video_status *status);
/* A post-request sender report confirms the latest complete picture even when
 * the screen is static. serial=0 means incomplete, unsynchronized or unconfirmed. */
typedef struct { uint64_t report, epoch, serial; } ncm_video_snapshot;
int32_t ncm_backend_video_get_snapshot(uint64_t handle, ncm_video_snapshot *snapshot);
int32_t ncm_backend_video_refresh(uint64_t handle);
int32_t ncm_backend_video_poll(uint64_t handle, ncm_event *event, uint8_t *buffer, size_t capacity);
uint32_t ncm_backend_abi(void);
/* Explicit new RemotePairing only. consent must be 1. No filesystem access.
 * Pairing events (request 0): 5 listener JSON {port,identifier,txt}, 6 PIN UTF8,
 * 7 provisional identity JSON, 8 committed identity JSON, 9 success.
 * 7/8 contain SECRET controller seed and authenticated peer binding. Caller must
 * durably save with file protection BEFORE ack(state 1/2); never log payloads.
 * Uses backend poll/close; failure stage 201. 180s total, 10s persistence gate.
 * A new identity is generated per explicit start. Preserve existing records:
 * caller must reject new pairing when a record exists. No implicit fallback. */
int32_t ncm_pairing_start(uint32_t consent,uint64_t *handle);
int32_t ncm_pairing_ack(uint64_t handle,uint32_t state);
int32_t ncm_backend_start(const ncm_config *,const ncm_identity *,uint64_t *handle);
/* VPN loopback default utun 10.7.1.1 -> 10.7.0.1. No default route fallback.
 * pairing_port must be freshly discovered on this phone. Same permissions/identity. */
int32_t ncm_local_vpn_start(uint32_t interface_index,uint16_t pairing_port,uint32_t permissions,const ncm_identity *,uint64_t *handle);
/* Explicit IPv4 values in address order: 10.7.1.1 = 0x0a070101 (host integer). */
int32_t ncm_local_vpn_start_configured(uint32_t interface_index,uint16_t pairing_port,uint32_t permissions,uint32_t local_ipv4,uint32_t peer_ipv4,const ncm_identity *,uint64_t *handle);
/* Ordinary Lockdown, independent of RemotePairing. Caller-selected plist bytes
 * and expected UDID; permissions must be exactly NCM_ALLOW_EXISTING_VERIFY.
 * Ready event 2 means StartSession + pinned mutual TLS completed (no RSD/DDI).
 * Failure stages: 101 identity, 102 connect, 103 StartSession, 104 peer rejection,
 * 105 TLS, 106 StopSession, 107 closed. No payloads/keys are returned.
 * Use existing poll/close; action 5 explicitly StopSession over established TLS.
 * close cancels transport and does not assert remote StopSession completed. */
int32_t ncm_lockdown_start(uint32_t interface_index,uint32_t permissions,ncm_bytes pairing_record,ncm_bytes expected_udid,uint64_t *handle);
/* Actions: 1 read-only developer/DDI check, 2 capture PNG, 3 start media drain,
 * 4 tap normalized x/y; 11 release owned media/HID streams (idempotent),
 * retaining the authenticated tunnel. No global stopAll. Every accepted request id must increase; no replay.
 * Touch media uses screen video only; no audio session is requested. Caller obtains consent. */
// Drag uses normalized coordinates, 100–2000 ms; uncertain delivery is never replayed.
int32_t ncm_backend_drag(uint64_t handle,uint64_t request_id,uint16_t x,uint16_t y,uint16_t end_x,uint16_t end_y,uint16_t duration_ms);
int32_t ncm_backend_submit(uint64_t handle,uint64_t request_id,uint32_t action,uint16_t x,uint16_t y);
/* 7 Home, 8 installed applications (event 11 JSON name/bundle_id/version).
 * 9 launch {bundle_id,arguments:[strings]}, 10 type {text}: all text via pasteboard + Cmd-V
 * (1..8192 UTF-8 bytes, no NUL); no virtual keyboard registration.
 * command copies bounded JSON; input permission required, no replay. Event 12
 * is a read-only app query failure retaining the authenticated session. */
int32_t ncm_backend_command(uint64_t handle,uint64_t request_id,uint32_t action,ncm_bytes payload);
int32_t ncm_backend_poll(uint64_t handle,ncm_event *,uint8_t *buffer,size_t capacity);
/* Idempotent. Immediately revokes handle and requests worker cancellation. Does
 * not block UI waiting for join or assert remote media/touch release succeeded. */
void ncm_backend_close(uint64_t handle);
/* Additive thumbnail-v2 geometry fence. Zero is invalid. */
uint64_t ncm_backend_video_geometry_generation(uint64_t handle);
uint64_t ncm_backend_video_invalidate_geometry(uint64_t handle);
uint64_t ncm_backend_video_sample_geometry(uint64_t handle,uint64_t serial,uint64_t epoch);
uint64_t ncm_backend_video_publish_geometry(uint64_t handle,uint64_t expected);
int32_t ncm_backend_input_guarded(uint64_t handle,uint64_t request_id,uint32_t action,uint16_t x,uint16_t y,uint16_t end_x,uint16_t end_y,uint16_t duration_ms,uint64_t expected_geometry);

#ifdef NCM_OFFLINE_FIXTURES
/* Exists only in the separately built test archive; always 127.0.0.1. Public
 * deterministic fixture identity, no persistent keys or real-device fallback. */
int32_t ncm_test_start_loopback(uint16_t relay_port,uint64_t *handle);
/* Synthetic recoverable preparation / uncertain delivery ownership fixture. */
int32_t ncm_test_start_media_failure(uint64_t *handle);
/* Synthetic HEVC burst, no network; absent from device archives. */
int32_t ncm_test_start_video_burst(ncm_bytes sample,uint32_t continuous,uint64_t *handle);
#endif
#ifdef __cplusplus
}
#endif
