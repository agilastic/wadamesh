#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace CompanionRetryPolicy {

// These are the companion defaults from MeshCore's keymindCascade branch.
// Tuned for ~10 min total DM retry window / ~5 min channel retry window
// at typical T-Deck airtime (~500 ms @ SF10/BW250).
static const uint8_t DIRECT_MAX_ATTEMPTS = 30;
static const uint8_t FLOOD_MAX_ATTEMPTS = 20;

inline uint32_t directDelay(uint32_t packet_airtime_ms, uint8_t attempt_idx) {
  // Starts at ~2 s, grows ~1.2 s per attempt → ~10 min total across 30 attempts at 500 ms airtime
  return 2000UL + (7UL * packet_airtime_ms) + (1241UL * attempt_idx);
}

inline uint32_t floodDelay(uint32_t max_packet_airtime_ms,
                           uint32_t packet_airtime_ms,
                           uint32_t jitter_percent,
                           uint8_t attempt_idx = 0) {
  // Starts at ~3 s, grows ~1.3 s per attempt → ~5 min total across 20 attempts at 500 ms airtime
  return max_packet_airtime_ms + (6UL * packet_airtime_ms)
      + (1263UL * attempt_idx)
      + ((packet_airtime_ms * jitter_percent) / 100UL);
}

inline bool isDirectEcho(uint8_t original_path_count, uint8_t received_path_count) {
  return received_path_count < original_path_count;
}

inline bool isFloodEcho(uint8_t original_path_count, uint8_t received_path_count) {
  return received_path_count > original_path_count;
}

inline bool keyIsSet(const uint8_t* key, size_t key_size) {
  if (!key) return false;
  for (size_t i = 0; i < key_size; i++) {
    if (key[i] != 0) return true;
  }
  return false;
}

inline bool keysEqual(const uint8_t* first, const uint8_t* second, size_t key_size) {
  return first && second && memcmp(first, second, key_size) == 0;
}

inline bool shouldReplacePendingText(uint32_t pending_ack,
                                     const uint8_t* pending_fingerprint,
                                     const uint8_t* new_fingerprint,
                                     size_t fingerprint_size) {
  return pending_ack != 0
      && keysEqual(pending_fingerprint, new_fingerprint, fingerprint_size);
}

inline bool ackMatches(uint32_t expected_ack, const uint8_t received_ack[4]) {
  return expected_ack != 0 && received_ack
      && memcmp(received_ack, &expected_ack, sizeof(expected_ack)) == 0;
}

// Wrap-safe for deadlines less than INT32_MAX milliseconds away. Retry delays
// are measured in seconds, so they remain comfortably inside that window.
inline uint32_t wakeDelay(uint32_t now_millis, uint32_t deadline_millis) {
  const int32_t signed_delay = static_cast<int32_t>(deadline_millis - now_millis);
  return signed_delay > 0 ? static_cast<uint32_t>(signed_delay) : 0;
}

}  // namespace CompanionRetryPolicy
