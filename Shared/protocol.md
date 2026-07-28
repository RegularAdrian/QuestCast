# QuestCast UDP protocol v1

The Apple TV publishes a Bonjour service named `_questcast._udp` on UDP port `49152`. The Quest resolves the service and sends directly to the advertised address.

Every UDP datagram contains a 24-byte big-endian header followed by at most 1176 bytes of payload.

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | ASCII magic `QCTV` |
| 4 | 1 | Version, currently `1` |
| 5 | 1 | Flags |
| 6 | 2 | Header length, currently `24` |
| 8 | 4 | Frame/access-unit ID |
| 12 | 2 | Fragment index, zero based |
| 14 | 2 | Fragment count |
| 16 | 8 | Sender presentation timestamp in microseconds |
| 24 | n | H.264 Annex-B payload fragment |

Flags:

- `0x01`: codec configuration containing SPS/PPS
- `0x02`: keyframe

All fragments of an access unit repeat the same metadata. Access-unit IDs wrap naturally as unsigned 32-bit integers. The receiver must tolerate reordered packets, ignore duplicates, and expire incomplete access units quickly.

This protocol is intentionally one-way in v1. Receiver feedback, IDR requests and loss telemetry can be added as a separate message type without changing the media header.

