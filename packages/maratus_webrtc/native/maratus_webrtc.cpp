#include "maratus_webrtc.h"

#include <rtc/rtc.hpp>

#include <cstddef>
#include <cstdint>
#include <iterator>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

enum EventType : int32_t {
  kNone = 0,
  kDescription = 1,
  kCandidate = 2,
  kLaneOpened = 3,
  kMessage = 4,
  kClosed = 5,
};

// Candidates found before their description are held back, so that
// signaling carries the description first.
constexpr size_t kMaxHeldCandidates = 256;

struct Event {
  int32_t type = kNone;
  int32_t connection = 0;
  int32_t lane = 0;
  std::vector<uint8_t> data;
  std::string mid;
  bool has_mid = false;
};

// State shared with libdatachannel's threads. Its callbacks hold weak
// references, so they do nothing once a connection or the driver is gone.
struct Shared {
  explicit Shared(size_t max_queued_bytes)
      : max_queued_bytes(max_queued_bytes) {}

  std::mutex mutex;
  std::deque<Event> events;
  const size_t max_queued_bytes;
};

struct Connection {
  int32_t id = 0;
  std::shared_ptr<rtc::PeerConnection> peer;
  std::vector<std::shared_ptr<rtc::DataChannel>> lanes;
  // Guarded by Shared::mutex.
  bool ended = false;
  bool described = false;
  size_t queued_bytes = 0;
  std::vector<Event> held_candidates;
};

void Push(Shared &shared, Event event) {
  shared.events.push_back(std::move(event));
}

// Reports a connection's end once; it reports nothing afterwards.
void End(Shared &shared, Connection &connection) {
  if (connection.ended) return;
  connection.ended = true;
  connection.held_candidates.clear();
  Event event;
  event.type = kClosed;
  event.connection = connection.id;
  Push(shared, std::move(event));
}

// Runs a callback under the shared lock while the connection is live.
template <typename Callback>
void WhileLive(const std::weak_ptr<Shared> &weak_shared,
               const std::weak_ptr<Connection> &weak_connection,
               Callback &&callback) {
  auto shared = weak_shared.lock();
  auto connection = weak_connection.lock();
  if (!shared || !connection) return;
  std::lock_guard<std::mutex> lock(shared->mutex);
  if (connection->ended) return;
  callback(*shared, *connection);
}

void Release(const std::shared_ptr<Connection> &connection) {
  // Callbacks are removed before closing, so closing reports nothing.
  try {
    for (auto &lane : connection->lanes) lane->resetCallbacks();
    connection->peer->resetCallbacks();
  } catch (...) {
  }
  try {
    connection->peer->close();
  } catch (...) {
  }
}

}  // namespace

struct MaratusWebRtc {
  explicit MaratusWebRtc(size_t max_queued_bytes)
      : shared(std::make_shared<Shared>(max_queued_bytes)) {}

  std::shared_ptr<Connection> Find(int32_t id) {
    auto found = connections.find(id);
    return found == connections.end() ? nullptr : found->second;
  }

  std::shared_ptr<Shared> shared;
  std::unordered_map<int32_t, std::shared_ptr<Connection>> connections;
  int32_t next_id = 1;
  Event current;
  MaratusWebRtcEvent view{};
};

extern "C" {

MaratusWebRtc *maratus_webrtc_create(size_t max_queued_bytes) {
  try {
    return new MaratusWebRtc(max_queued_bytes);
  } catch (...) {
    return nullptr;
  }
}

int32_t maratus_webrtc_open(MaratusWebRtc *driver, int32_t lane_count,
                            const char *const *urls,
                            const char *const *usernames,
                            const char *const *credentials,
                            int32_t server_count) {
  if (driver == nullptr || lane_count < 1 || lane_count > 1024 ||
      driver->next_id == INT32_MAX) {
    return 0;
  }
  try {
    rtc::Configuration configuration;
    configuration.disableAutoNegotiation = true;
    for (int32_t index = 0; index < server_count; index++) {
      try {
        rtc::IceServer server(urls[index]);
        if (usernames[index] != nullptr) server.username = usernames[index];
        if (credentials[index] != nullptr) {
          server.password = credentials[index];
        }
        configuration.iceServers.push_back(std::move(server));
      } catch (...) {
        // Schemes such as stuns: are unsupported; other servers remain.
      }
    }

    auto connection = std::make_shared<Connection>();
    connection->id = driver->next_id;
    connection->peer = std::make_shared<rtc::PeerConnection>(configuration);
    std::weak_ptr<Shared> weak_shared = driver->shared;
    std::weak_ptr<Connection> weak_connection = connection;

    connection->peer->onLocalDescription(
        [weak_shared, weak_connection](rtc::Description description) {
          WhileLive(weak_shared, weak_connection,
                    [&](Shared &shared, Connection &connection) {
                      if (connection.described) return;
                      connection.described = true;
                      const std::string sdp = std::string(description);
                      Event event;
                      event.type = kDescription;
                      event.connection = connection.id;
                      event.data.assign(sdp.begin(), sdp.end());
                      Push(shared, std::move(event));
                      for (auto &held : connection.held_candidates) {
                        Push(shared, std::move(held));
                      }
                      connection.held_candidates.clear();
                    });
        });
    connection->peer->onLocalCandidate(
        [weak_shared, weak_connection](rtc::Candidate candidate) {
          WhileLive(weak_shared, weak_connection,
                    [&](Shared &shared, Connection &connection) {
                      const std::string line = candidate.candidate();
                      Event event;
                      event.type = kCandidate;
                      event.connection = connection.id;
                      event.data.assign(line.begin(), line.end());
                      event.mid = candidate.mid();
                      event.has_mid = true;
                      if (connection.described) {
                        Push(shared, std::move(event));
                      } else if (connection.held_candidates.size() <
                                 kMaxHeldCandidates) {
                        connection.held_candidates.push_back(std::move(event));
                      }
                    });
        });
    connection->peer->onStateChange(
        [weak_shared, weak_connection](rtc::PeerConnection::State state) {
          if (state != rtc::PeerConnection::State::Failed &&
              state != rtc::PeerConnection::State::Closed) {
            return;
          }
          WhileLive(weak_shared, weak_connection, End);
        });

    for (int32_t lane = 0; lane < lane_count; lane++) {
      rtc::DataChannelInit init;
      init.negotiated = true;
      init.id = static_cast<uint16_t>(lane);
      if (lane % 2 == 1) {
        init.reliability.unordered = true;
        init.reliability.maxRetransmits = 0;
      }
      auto channel = connection->peer->createDataChannel(
          "maratus-" + std::to_string(lane), init);
      channel->onOpen([weak_shared, weak_connection, lane]() {
        WhileLive(weak_shared, weak_connection,
                  [&](Shared &shared, Connection &connection) {
                    Event event;
                    event.type = kLaneOpened;
                    event.connection = connection.id;
                    event.lane = lane;
                    Push(shared, std::move(event));
                  });
      });
      channel->onMessage(
          [weak_shared, weak_connection, lane](rtc::binary data) {
            WhileLive(weak_shared, weak_connection,
                      [&](Shared &shared, Connection &connection) {
                        const size_t size = data.size();
                        if (size > shared.max_queued_bytes ||
                            connection.queued_bytes >
                                shared.max_queued_bytes - size) {
                          // Unordered lanes may lose data; reliable ones
                          // must not, so the connection ends instead.
                          if (lane % 2 == 0) End(shared, connection);
                          return;
                        }
                        connection.queued_bytes += size;
                        Event event;
                        event.type = kMessage;
                        event.connection = connection.id;
                        event.lane = lane;
                        const auto *bytes =
                            reinterpret_cast<const uint8_t *>(data.data());
                        event.data.assign(bytes, bytes + size);
                        Push(shared, std::move(event));
                      });
          },
          [weak_shared, weak_connection](rtc::string) {
            // Text is not part of the protocol.
            WhileLive(weak_shared, weak_connection, End);
          });
      channel->onClosed([weak_shared, weak_connection]() {
        WhileLive(weak_shared, weak_connection, End);
      });
      channel->onError([weak_shared, weak_connection](std::string) {
        WhileLive(weak_shared, weak_connection, End);
      });
      connection->lanes.push_back(std::move(channel));
    }

    driver->connections[connection->id] = connection;
    return driver->next_id++;
  } catch (...) {
    return 0;
  }
}

int32_t maratus_webrtc_create_offer(MaratusWebRtc *driver,
                                    int32_t connection) {
  if (driver == nullptr) return -1;
  auto found = driver->Find(connection);
  if (!found) return -1;
  try {
    found->peer->setLocalDescription(rtc::Description::Type::Offer);
    return 0;
  } catch (...) {
    return -1;
  }
}

int32_t maratus_webrtc_accept_offer(MaratusWebRtc *driver, int32_t connection,
                                    const char *sdp) {
  if (driver == nullptr || sdp == nullptr) return -1;
  auto found = driver->Find(connection);
  if (!found) return -1;
  try {
    found->peer->setRemoteDescription(
        rtc::Description(sdp, rtc::Description::Type::Offer));
    found->peer->setLocalDescription(rtc::Description::Type::Answer);
    return 0;
  } catch (...) {
    return -1;
  }
}

int32_t maratus_webrtc_accept_answer(MaratusWebRtc *driver,
                                     int32_t connection, const char *sdp) {
  if (driver == nullptr || sdp == nullptr) return -1;
  auto found = driver->Find(connection);
  if (!found) return -1;
  try {
    found->peer->setRemoteDescription(
        rtc::Description(sdp, rtc::Description::Type::Answer));
    return 0;
  } catch (...) {
    return -1;
  }
}

int32_t maratus_webrtc_add_candidate(MaratusWebRtc *driver, int32_t connection,
                                     const char *candidate, const char *mid) {
  if (driver == nullptr || candidate == nullptr) return -1;
  auto found = driver->Find(connection);
  if (!found) return -1;
  try {
    found->peer->addRemoteCandidate(
        mid == nullptr ? rtc::Candidate(candidate)
                       : rtc::Candidate(candidate, mid));
    return 0;
  } catch (...) {
    return -1;
  }
}

int32_t maratus_webrtc_send(MaratusWebRtc *driver, int32_t connection,
                            int32_t lane, const uint8_t *data, size_t length) {
  if (driver == nullptr || (data == nullptr && length > 0)) return -1;
  auto found = driver->Find(connection);
  if (!found || lane < 0 ||
      static_cast<size_t>(lane) >= found->lanes.size()) {
    return -1;
  }
  try {
    // libdatachannel copies the data. A false result only means buffered.
    found->lanes[lane]->send(reinterpret_cast<const std::byte *>(data),
                             length);
    return 0;
  } catch (...) {
    return -1;
  }
}

int64_t maratus_webrtc_buffered_amount(MaratusWebRtc *driver,
                                       int32_t connection, int32_t lane) {
  if (driver == nullptr) return -1;
  auto found = driver->Find(connection);
  if (!found || lane < 0 ||
      static_cast<size_t>(lane) >= found->lanes.size()) {
    return -1;
  }
  try {
    return static_cast<int64_t>(found->lanes[lane]->bufferedAmount());
  } catch (...) {
    return -1;
  }
}

void maratus_webrtc_close(MaratusWebRtc *driver, int32_t connection) {
  if (driver == nullptr) return;
  auto found = driver->Find(connection);
  if (!found) return;
  driver->connections.erase(connection);
  {
    std::lock_guard<std::mutex> lock(driver->shared->mutex);
    found->ended = true;
    found->held_candidates.clear();
    auto &events = driver->shared->events;
    for (auto it = events.begin(); it != events.end();) {
      it = it->connection == connection ? events.erase(it) : std::next(it);
    }
  }
  // libdatachannel may wait for its threads, which can be waiting for the
  // shared lock in a callback, so it is released first.
  Release(found);
}

const MaratusWebRtcEvent *maratus_webrtc_poll(MaratusWebRtc *driver) {
  if (driver == nullptr) return nullptr;
  {
    std::lock_guard<std::mutex> lock(driver->shared->mutex);
    if (driver->shared->events.empty()) {
      driver->current = Event();
    } else {
      driver->current = std::move(driver->shared->events.front());
      driver->shared->events.pop_front();
      if (driver->current.type == kMessage) {
        auto found = driver->Find(driver->current.connection);
        if (found) found->queued_bytes -= driver->current.data.size();
      }
    }
  }
  const Event &event = driver->current;
  driver->view.type = event.type;
  driver->view.connection = event.connection;
  driver->view.lane = event.lane;
  driver->view.has_mid = event.has_mid ? 1 : 0;
  driver->view.data = event.data.empty() ? nullptr : event.data.data();
  driver->view.length = event.data.size();
  driver->view.mid = event.has_mid ? event.mid.c_str() : nullptr;
  return &driver->view;
}

void maratus_webrtc_destroy(MaratusWebRtc *driver) {
  if (driver == nullptr) return;
  std::vector<std::shared_ptr<Connection>> connections;
  for (auto &entry : driver->connections) connections.push_back(entry.second);
  driver->connections.clear();
  {
    std::lock_guard<std::mutex> lock(driver->shared->mutex);
    for (auto &connection : connections) connection->ended = true;
    driver->shared->events.clear();
  }
  for (auto &connection : connections) Release(connection);
  delete driver;
}

}  // extern "C"
