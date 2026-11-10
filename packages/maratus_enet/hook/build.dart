import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> arguments) async {
  await build(arguments, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final windows = input.config.code.targetOS == OS.windows;
    final builder = CBuilder.library(
      name: 'maratus_enet',
      assetName: 'src/enet_driver_native.dart',
      sources: [
        'native/maratus_enet.c',
        for (final name in [
          'callbacks',
          'compress',
          'host',
          'list',
          'packet',
          'peer',
          'protocol',
          windows ? 'win32' : 'unix',
        ])
          'native/enet-1.3.18/$name.c',
      ],
      includes: ['native', 'native/enet-1.3.18/include'],
      libraries: [
        if (windows) ...['ws2_32', 'winmm'],
      ],
      defines: {
        if (!windows) ...{
          'HAS_FCNTL': '1',
          'HAS_POLL': '1',
          'HAS_INET_PTON': '1',
          'HAS_INET_NTOP': '1',
          'HAS_MSGHDR_FLAGS': '1',
          'HAS_SOCKLEN_T': '1',
          'HAS_GETADDRINFO': '1',
          'HAS_GETNAMEINFO': '1',
        },
      },
    );
    await builder.run(input: input, output: output);
  });
}
