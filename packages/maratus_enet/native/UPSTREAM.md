# ENet source provenance

`enet-1.3.18/` contains the unmodified C source and headers needed to build
[ENet 1.3.18](https://github.com/lsalzman/enet/tree/v1.3.18), plus its MIT license.
The original license is preserved at `enet-1.3.18/LICENSE` and must accompany
redistributions. ENet is copyright Lee Salzman.

Source archive:
`https://codeload.github.com/lsalzman/enet/tar.gz/refs/tags/v1.3.18`

Archive SHA-256:
`28603c895f9ed24a846478180ee72c7376b39b4bb1287b73877e5eae7d96b0dd`

The package vendors `callbacks.c`, `compress.c`, `host.c`, `list.c`, `packet.c`,
`peer.c`, `protocol.c`, `unix.c`, `win32.c`, `include/enet/`, and `LICENSE`.
Build files, upstream examples, documentation, and the archive are omitted.
`hook/build.dart` compiles these sources without downloading anything.

`maratus_enet.c` and `maratus_enet.h` are the package's own ABI adapter. They
provide connection identities that survive ENet slot reuse, bounded packet
configuration, and packet-release notifications without exposing ENet structures
to Dart. Each tracked outgoing packet owns one completion node until Dart polls
it; the Dart transport's outgoing queue limits bound the number of such nodes.
