#ifndef MARATUS_WEBRTC_H
#define MARATUS_WEBRTC_H

#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#define MARATUS_WEBRTC_API __declspec(dllexport)
#else
#define MARATUS_WEBRTC_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MaratusWebRtc MaratusWebRtc;

/* This small ABI shields Dart from libdatachannel's C++ types. */
typedef struct MaratusWebRtcEvent {
  int32_t type; /* 0 none, 1 description, 2 candidate, 3 lane opened,
                   4 message, 5 closed */
  int32_t connection;
  int32_t lane;
  int32_t has_mid; /* whether mid is set for a candidate */
  const uint8_t *data; /* message bytes, or UTF-8 description or candidate */
  size_t length;
  const char *mid;
} MaratusWebRtcEvent;

/* Creates a driver. Each connection may hold at most max_queued_bytes of
   received messages that have not been polled. */
MARATUS_WEBRTC_API MaratusWebRtc *maratus_webrtc_create(
    size_t max_queued_bytes);

/* Creates a connection with lane_count negotiated data channels and returns
   its identifier, or 0 on failure. Each ICE server is a URL with an optional
   user name and credential; unsupported URLs are skipped. */
MARATUS_WEBRTC_API int32_t maratus_webrtc_open(
    MaratusWebRtc *driver, int32_t lane_count, const char *const *urls,
    const char *const *usernames, const char *const *credentials,
    int32_t server_count);

/* Each returns 0 on success and -1 on failure. */
MARATUS_WEBRTC_API int32_t maratus_webrtc_create_offer(
    MaratusWebRtc *driver, int32_t connection);
MARATUS_WEBRTC_API int32_t maratus_webrtc_accept_offer(
    MaratusWebRtc *driver, int32_t connection, const char *sdp);
MARATUS_WEBRTC_API int32_t maratus_webrtc_accept_answer(
    MaratusWebRtc *driver, int32_t connection, const char *sdp);
MARATUS_WEBRTC_API int32_t maratus_webrtc_add_candidate(
    MaratusWebRtc *driver, int32_t connection, const char *candidate,
    const char *mid);
MARATUS_WEBRTC_API int32_t maratus_webrtc_send(
    MaratusWebRtc *driver, int32_t connection, int32_t lane,
    const uint8_t *data, size_t length);

/* Returns the bytes queued on a lane, or -1 on failure. */
MARATUS_WEBRTC_API int64_t maratus_webrtc_buffered_amount(
    MaratusWebRtc *driver, int32_t connection, int32_t lane);

/* Closes a connection. No further events are reported for it. */
MARATUS_WEBRTC_API void maratus_webrtc_close(
    MaratusWebRtc *driver, int32_t connection);

/* Returns the next event, valid until the next poll or destroy. */
MARATUS_WEBRTC_API const MaratusWebRtcEvent *maratus_webrtc_poll(
    MaratusWebRtc *driver);

/* Closes every connection and releases the driver. */
MARATUS_WEBRTC_API void maratus_webrtc_destroy(MaratusWebRtc *driver);

#ifdef __cplusplus
}
#endif

#endif
