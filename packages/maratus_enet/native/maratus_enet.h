#ifndef MARATUS_ENET_H
#define MARATUS_ENET_H

#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#define MARATUS_ENET_API __declspec(dllexport)
#else
#define MARATUS_ENET_API __attribute__((visibility("default")))
#endif

typedef struct MaratusEnetHost MaratusEnetHost;

/* This small ABI shields Dart from ENet's platform-dependent structures. */
typedef struct MaratusEnetEvent {
  int32_t type; /* -1 error, 0 none, 1 connect, 2 receive, 3 disconnect, 4 sent */
  int32_t channel; /* negotiated count for connect, channel ID for receive */
  uint64_t peer;
  int64_t token; /* completion token, or graceful marker for disconnect */
  const uint8_t *data;
  size_t length;
} MaratusEnetEvent;

MARATUS_ENET_API MaratusEnetHost *maratus_enet_create(
    const char *address, uint16_t port, size_t max_connections,
    size_t channel_count, size_t max_packet_bytes, size_t max_waiting_bytes);
MARATUS_ENET_API uint16_t maratus_enet_port(MaratusEnetHost *host);
MARATUS_ENET_API uint64_t maratus_enet_connect(
    MaratusEnetHost *host, const char *address, uint16_t port,
    size_t channel_count);
MARATUS_ENET_API const MaratusEnetEvent *maratus_enet_poll(MaratusEnetHost *host);
MARATUS_ENET_API void maratus_enet_release_packet(MaratusEnetHost *host);
MARATUS_ENET_API int32_t maratus_enet_send(
    MaratusEnetHost *host, uint64_t peer, uint8_t channel, const uint8_t *data,
    size_t length, int32_t mode, int32_t has_token, int64_t token);
MARATUS_ENET_API void maratus_enet_disconnect(MaratusEnetHost *host, uint64_t peer);
MARATUS_ENET_API void maratus_enet_reset(MaratusEnetHost *host, uint64_t peer);
MARATUS_ENET_API void maratus_enet_destroy(MaratusEnetHost *host);

#endif
