# Native source provenance

The native WebRTC implementation is built from unmodified upstream sources.
`hook/build.dart` compiles them without downloading anything. Each project's
license is preserved in its directory and must accompany redistributions.

| Directory | Project | License |
| --------- | ------- | ------- |
| `libdatachannel-0.24.6/` | [libdatachannel 0.24.6](https://github.com/paullouisageneau/libdatachannel/tree/v0.24.6) | MPL-2.0 |
| `libjuice/` | [libjuice](https://github.com/paullouisageneau/libjuice/tree/b89c792e3612faf2f12cf35bcc56857313a06be3) at the commit libdatachannel 0.24.6 pins | MPL-2.0 |
| `usrsctp/` | [usrsctp](https://github.com/sctplab/usrsctp/tree/fec583d54493f879d2ae44a743423bf8a04371ab) at the commit libdatachannel 0.24.6 pins | BSD-3-Clause |
| `plog/` | [plog](https://github.com/SergiusTheBest/plog/tree/94899e0b926ac1b0f4750bfbd495167b4a6ae9ef) at the commit libdatachannel 0.24.6 pins | MIT |
| `mbedtls-3.6.7/` | [Mbed TLS 3.6.7](https://github.com/Mbed-TLS/mbedtls/releases/tag/mbedtls-3.6.7) | Apache-2.0, used under Apache-2.0 (also GPL-2.0-or-later) |

The MPL-2.0 sources are distributed here in source form, unmodified.

## Source archives

| Archive | SHA-256 |
| ------- | ------- |
| `https://codeload.github.com/paullouisageneau/libdatachannel/tar.gz/refs/tags/v0.24.6` | `22a66aebebd8dae561d8e5181da96f2fcc203e067c5b2186c07b39af913464c0` |
| `https://codeload.github.com/paullouisageneau/libjuice/tar.gz/b89c792e3612faf2f12cf35bcc56857313a06be3` | `713b22174e8cb2e06538fa9bac2650bda21b83c86f5128813ab4dcf8f5bea9ed` |
| `https://codeload.github.com/sctplab/usrsctp/tar.gz/fec583d54493f879d2ae44a743423bf8a04371ab` | `e5c114afe73c9a0ec419fab5f5b3f63f3ce57b09b90d06ea85e63dca8aed3e7c` |
| `https://codeload.github.com/SergiusTheBest/plog/tar.gz/94899e0b926ac1b0f4750bfbd495167b4a6ae9ef` | `92a08bce559b5f28aa88d3fd9071567414b9f43a83fe2a05a6dd14f1da536072` |
| `https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.7/mbedtls-3.6.7.tar.bz2` | `a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6` |

The Mbed TLS checksum matches the release's published
`mbedtls-3.6.7-sha256sum.txt`. Mbed TLS keeps generated sources out of its
repository, so the release archive is used instead of a tag snapshot.

## Vendored files

Only the C and C++ sources and headers needed to build each library are
vendored, plus the license files:

- libdatachannel: `src/` and `include/`.
- libjuice: `src/` and `include/`.
- usrsctp: `usrsctplib/`.
- plog: `include/`.
- Mbed TLS: `library/` and `include/`.

Build files, tests, examples, documentation, and media dependencies such as
libSRTP are omitted.

## Package files

`maratus_webrtc.cpp` and `maratus_webrtc.h` are the package's own ABI
adapter. They give Dart a polled event queue over libdatachannel's threaded
callbacks, hold candidates back until their description has been reported,
and bound the received data a connection queues before Dart polls it.

`maratus_mbedtls_config.h` adds `MBEDTLS_SSL_DTLS_SRTP` to the default Mbed
TLS configuration, because libdatachannel configures DTLS-SRTP profiles even
when media support is disabled.
