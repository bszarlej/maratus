#include "maratus_enet.h"

#include <stdlib.h>
#include <string.h>

#include "enet/enet.h"

/* ENet's timeout disconnects carry zero, unlike explicit graceful shutdown. */
#define MARATUS_ENET_GRACEFUL 0x4d415201U

typedef struct MaratusEnetCompletion {
  struct MaratusEnetCompletion *next;
  MaratusEnetHost *owner;
  uint64_t peer;
  int64_t token;
} MaratusEnetCompletion;

struct MaratusEnetHost {
  ENetHost *host;
  uint64_t *peer_ids;
  uint64_t next_id;
  MaratusEnetEvent event;
  ENetPacket *received;
  MaratusEnetCompletion *completed_first;
  MaratusEnetCompletion *completed_last;
  int destroying;
};

static uint64_t next_id(MaratusEnetHost *host) {
  /* Dart VM integers are signed. Never wrap and accidentally reuse an ID. */
  if (host->next_id == INT64_MAX) return 0;
  return ++host->next_id;
}

static ENetPeer *find_peer(MaratusEnetHost *host, uint64_t id) {
  size_t i;
  if (!id) return NULL;
  for (i = 0; i < host->host->peerCount; ++i) {
    if (host->peer_ids[i] == id) return &host->host->peers[i];
  }
  return NULL;
}

/* Each tracked send allocates its completion before ENet takes ownership.
 * Releasing packets, including during reset, never needs another allocation.
 * Dart bounds accepted sends; the completion list retains only their tokens. */
static void ENET_CALLBACK packet_released(ENetPacket *packet) {
  MaratusEnetCompletion *completion = packet->userData;
  MaratusEnetHost *host = completion->owner;
  if (host->destroying) {
    free(completion);
    return;
  }
  completion->next = NULL;
  if (host->completed_last) {
    host->completed_last->next = completion;
  } else {
    host->completed_first = completion;
  }
  host->completed_last = completion;
}

static void discard_completions(MaratusEnetHost *host, uint64_t peer) {
  MaratusEnetCompletion **entry = &host->completed_first;
  MaratusEnetCompletion *previous = NULL;
  while (*entry) {
    MaratusEnetCompletion *completion = *entry;
    if (!peer || completion->peer == peer) {
      *entry = completion->next;
      free(completion);
    } else {
      previous = completion;
      entry = &completion->next;
    }
  }
  host->completed_last = previous;
}

MaratusEnetHost *maratus_enet_create(
    const char *address, uint16_t port, size_t max_connections,
    size_t channel_count, size_t max_packet_bytes, size_t max_waiting_bytes) {
  MaratusEnetHost *host;
  ENetAddress bind_address;
  if (!max_connections || max_connections > ENET_PROTOCOL_MAXIMUM_PEER_ID ||
      !channel_count || channel_count > ENET_PROTOCOL_MAXIMUM_CHANNEL_COUNT ||
      !max_packet_bytes || !max_waiting_bytes) {
    return NULL;
  }
  memset(&bind_address, 0, sizeof(bind_address));
  bind_address.port = port;
  if (address && enet_address_set_host_ip(&bind_address, address) < 0) {
    return NULL;
  }
  /* Windows keeps a reference count for WSAStartup/WSACleanup. Balancing each
   * host independently also avoids a process-global, racy reference counter. */
  if (enet_initialize() < 0) return NULL;
  host = calloc(1, sizeof(*host));
  if (!host) {
    enet_deinitialize();
    return NULL;
  }
  host->peer_ids = calloc(max_connections, sizeof(*host->peer_ids));
  if (!host->peer_ids) {
    free(host);
    enet_deinitialize();
    return NULL;
  }
  host->host = enet_host_create(address ? &bind_address : NULL,
                                max_connections, channel_count, 0, 0);
  if (!host->host) {
    free(host->peer_ids);
    free(host);
    enet_deinitialize();
    return NULL;
  }
  host->host->maximumPacketSize = max_packet_bytes;
  host->host->maximumWaitingData = max_waiting_bytes;
  return host;
}

uint16_t maratus_enet_port(MaratusEnetHost *host) {
  ENetAddress address;
  if (enet_socket_get_address(host->host->socket, &address) < 0) return 0;
  return address.port;
}

uint64_t maratus_enet_connect(MaratusEnetHost *host, const char *address,
                             uint16_t port, size_t channel_count) {
  ENetAddress remote;
  ENetPeer *peer;
  uint64_t id;
  if (!channel_count || channel_count > host->host->channelLimit) return 0;
  memset(&remote, 0, sizeof(remote));
  remote.port = port;
  if (enet_address_set_host_ip(&remote, address) < 0) return 0;
  id = next_id(host);
  if (!id) return 0;
  peer = enet_host_connect(host->host, &remote, channel_count, 0);
  if (!peer) return 0;
  host->peer_ids[peer - host->host->peers] = id;
  return id;
}

void maratus_enet_release_packet(MaratusEnetHost *host) {
  if (host->received) {
    enet_packet_destroy(host->received);
    host->received = NULL;
    host->event.data = NULL;
    host->event.length = 0;
  }
}

const MaratusEnetEvent *maratus_enet_poll(MaratusEnetHost *host) {
  ENetEvent event;
  int status;
  size_t slot;
  maratus_enet_release_packet(host);
  memset(&host->event, 0, sizeof(host->event));
  if (host->completed_first) {
    MaratusEnetCompletion *completion = host->completed_first;
    host->completed_first = completion->next;
    if (!host->completed_first) host->completed_last = NULL;
    host->event.type = 4;
    host->event.peer = completion->peer;
    host->event.token = completion->token;
    free(completion);
    return &host->event;
  }
  status = enet_host_service(host->host, &event, 0);
  if (status < 0) {
    host->event.type = -1;
    return &host->event;
  }
  if (!status) return &host->event;
  slot = event.peer - host->host->peers;
  if (event.type == ENET_EVENT_TYPE_CONNECT) {
    if (!host->peer_ids[slot]) host->peer_ids[slot] = next_id(host);
    if (!host->peer_ids[slot]) {
      enet_peer_reset(event.peer);
      host->event.type = -1;
      return &host->event;
    }
    host->event.type = 1;
    host->event.peer = host->peer_ids[slot];
    host->event.channel = (int32_t)event.peer->channelCount;
  } else if (event.type == ENET_EVENT_TYPE_RECEIVE) {
    host->received = event.packet;
    host->event.type = 2;
    host->event.peer = host->peer_ids[slot];
    host->event.channel = event.channelID;
    host->event.data = event.packet->data;
    host->event.length = event.packet->dataLength;
  } else if (event.type == ENET_EVENT_TYPE_DISCONNECT) {
    host->event.type = 3;
    host->event.peer = host->peer_ids[slot];
    host->event.token = event.data == MARATUS_ENET_GRACEFUL;
    host->peer_ids[slot] = 0;
  }
  return &host->event;
}

int32_t maratus_enet_send(MaratusEnetHost *host, uint64_t id, uint8_t channel,
                          const uint8_t *data, size_t length, int32_t mode,
                          int32_t has_token, int64_t token) {
  ENetPeer *peer = find_peer(host, id);
  ENetPacket *packet;
  enet_uint32 flags;
  if (!peer || peer->state != ENET_PEER_STATE_CONNECTED ||
      channel >= peer->channelCount || length > host->host->maximumPacketSize) {
    return 0;
  }
  switch (mode) {
    case 0:
      flags = ENET_PACKET_FLAG_RELIABLE;
      break;
    case 1:
      flags = ENET_PACKET_FLAG_UNRELIABLE_FRAGMENT;
      break;
    case 2:
      flags = ENET_PACKET_FLAG_UNSEQUENCED | ENET_PACKET_FLAG_UNRELIABLE_FRAGMENT;
      break;
    default:
      return 0;
  }
  packet = enet_packet_create(data, length, flags);
  if (!packet) return -1;
  if (has_token) {
    MaratusEnetCompletion *completion = malloc(sizeof(*completion));
    if (!completion) {
      enet_packet_destroy(packet);
      return -1;
    }
    completion->owner = host;
    completion->peer = id;
    completion->token = token;
    completion->next = NULL;
    packet->userData = completion;
    packet->freeCallback = packet_released;
  }
  if (enet_peer_send(peer, channel, packet) < 0) {
    /* A rejected send never reports a later release for its token. */
    free(packet->userData);
    packet->userData = NULL;
    packet->freeCallback = NULL;
    enet_packet_destroy(packet);
    return -1;
  }
  return 1;
}

void maratus_enet_disconnect(MaratusEnetHost *host, uint64_t id) {
  ENetPeer *peer = find_peer(host, id);
  if (!peer) return;
  enet_peer_disconnect_later(peer, MARATUS_ENET_GRACEFUL);
  /* Cancelling an unestablished outgoing connection resets ENet immediately,
   * without a disconnect event. Do not attach its identity to the next peer
   * that ENet admits into this slot. */
  if (peer->state == ENET_PEER_STATE_DISCONNECTED) {
    host->peer_ids[peer - host->host->peers] = 0;
    discard_completions(host, id);
  }
}

void maratus_enet_reset(MaratusEnetHost *host, uint64_t id) {
  ENetPeer *peer = find_peer(host, id);
  if (!id) return;
  if (peer) {
    enet_peer_reset(peer);
    host->peer_ids[peer - host->host->peers] = 0;
  }
  discard_completions(host, id);
}

void maratus_enet_destroy(MaratusEnetHost *host) {
  if (!host) return;
  host->destroying = 1;
  maratus_enet_release_packet(host);
  enet_host_destroy(host->host);
  discard_completions(host, 0);
  free(host->peer_ids);
  free(host);
  enet_deinitialize();
}
