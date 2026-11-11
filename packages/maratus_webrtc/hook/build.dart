import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _libdatachannel = 'native/libdatachannel-0.24.6';
const _mbedtls = 'native/mbedtls-3.6.7';
const _usrsctp = 'native/usrsctp/usrsctplib';
const _libjuice = 'native/libjuice';
const _plog = 'native/plog/include';

/// Builds Mbed TLS, usrsctp, and libjuice as static libraries, then links
/// libdatachannel and the package's adapter into one shared library.
void main(List<String> arguments) async {
  await build(arguments, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    final windows = os == OS.windows;
    final apple = os == OS.macOS || os == OS.iOS;
    final root = input.packageRoot;
    final outDir = input.outputDirectory;

    List<String> sources(String directory, String extension) {
      final found = [
        for (final entry in Directory.fromUri(
          root.resolve('$directory/'),
        ).listSync(recursive: true))
          if (entry is File && entry.path.endsWith(extension))
            entry.uri.toFilePath(),
      ]..sort();
      if (found.isEmpty) {
        throw StateError('No $extension sources in $directory');
      }
      return found;
    }

    // Shared by usrsctp and libdatachannel, whose structures must agree.
    final platform = <String, String?>{
      if (windows) ...{
        'WIN32_LEAN_AND_MEAN': null,
        'NOMINMAX': null,
        '_CRT_SECURE_NO_WARNINGS': null,
      },
      if (os == OS.linux) '_GNU_SOURCE': null,
      if (os == OS.linux || os == OS.android) ...{
        'HAVE_LINUX_IF_ADDR_H': null,
        'HAVE_LINUX_RTNETLINK_H': null,
      },
      if (!windows) ...{
        'HAVE_SYS_QUEUE_H': null,
        'HAVE_NETINET_IP_ICMP_H': null,
        'HAVE_NET_ROUTE_H': null,
        'HAVE_STDATOMIC_H': null,
      },
      if (apple) ...{
        '__APPLE_USE_RFC_2292': null,
        'HAVE_SA_LEN': null,
        'HAVE_SIN_LEN': null,
        'HAVE_SIN6_LEN': null,
        'HAVE_SCONN_LEN': null,
      },
    };
    const mbedtlsConfig = {
      'MBEDTLS_USER_CONFIG_FILE': '<maratus_mbedtls_config.h>',
    };

    Future<void> compile(
      String name, {
      String? assetName,
      required List<String> sources,
      required List<String> includes,
      required Map<String, String?> defines,
      List<String> flags = const [],
      Language language = Language.c,
      List<String> libraries = const [],
    }) async {
      final static = assetName == null;
      // MSVC archives every object file in the shared output directory.
      if (windows) await _removeObjects(outDir);
      var compiled = sources;
      var defined = defines;
      final extra = <String>[];
      if (windows) {
        // MSVC runs through cmd.exe, which limits the length of a command
        // and would read angle brackets as redirections. cl.exe reads these
        // arguments from a response file instead.
        final responses = File.fromUri(outDir.resolve('$name.rsp'));
        await responses.writeAsString(
          [
            for (final MapEntry(:key, :value) in defines.entries)
              value == null ? '/D$key' : '/D$key=$value',
            for (final source in sources) '"$source"',
          ].join('\n'),
        );
        extra.add('@$name.rsp');
        compiled = const [];
        defined = const {};
        output.dependencies.addAll(sources.map(Uri.file));
      }
      await CBuilder.library(
        name: name,
        assetName: assetName,
        sources: compiled,
        includes: includes,
        defines: defined,
        flags: [
          if (windows)
            '/MP'
          else ...[
            '-pthread',
            // Only the adapter's API is exported, so the bundled libraries
            // cannot clash with other copies loaded by the application.
            '-fvisibility=hidden',
            if (language == Language.cpp) '-fvisibility-inlines-hidden',
            '-ffunction-sections',
            '-fdata-sections',
          ],
          ...flags,
          ...extra,
        ],
        language: language,
        std: language == Language.cpp ? 'c++17' : null,
        cppLinkStdLib: language == Language.cpp && os == OS.android
            ? 'c++_static'
            : null,
        libraries: libraries,
        linkModePreference: static ? LinkModePreference.static : null,
      ).run(input: input, output: output);
    }

    await compile(
      'maratus_mbedtls',
      sources: sources('$_mbedtls/library', '.c'),
      includes: ['native', '$_mbedtls/include'],
      defines: {...mbedtlsConfig, if (windows) '_CRT_SECURE_NO_WARNINGS': null},
    );
    await compile(
      'maratus_usrsctp',
      sources: sources(_usrsctp, '.c'),
      includes: [_usrsctp],
      defines: {
        ...platform,
        '__Userspace__': null,
        'SCTP_SIMPLE_ALLOCATOR': null,
        'SCTP_PROCESS_LEVEL_LOCKS': null,
      },
      flags: [if (!windows) '-Wno-address-of-packed-member'],
    );
    await compile(
      'maratus_juice',
      sources: sources('$_libjuice/src', '.c'),
      includes: ['$_libjuice/include', '$_libjuice/include/juice'],
      defines: {
        if (windows) ...{
          'WIN32_LEAN_AND_MEAN': null,
          'NOMINMAX': null,
          '_CRT_SECURE_NO_WARNINGS': null,
        },
        'JUICE_STATIC': null,
        'USE_NETTLE': '0',
        'RELEASE': '1',
      },
    );

    // libdatachannel reuses file names across directories. MSVC names
    // objects after their sources, so each is compiled through a uniquely
    // named wrapper.
    final wrappers = Directory.fromUri(outDir.resolve('libdatachannel/'));
    await wrappers.create(recursive: true);
    final base = root.resolve('$_libdatachannel/src/').toFilePath();
    final libdatachannel = <String>[];
    for (final source in sources('$_libdatachannel/src', '.cpp')) {
      final name = source
          .substring(base.length)
          .replaceAll(RegExp(r'[\\/]'), '_');
      final wrapper = File.fromUri(wrappers.uri.resolve('ldc_$name'));
      final content = '#include "${source.replaceAll(r'\', '/')}"\n';
      if (!wrapper.existsSync() || wrapper.readAsStringSync() != content) {
        await wrapper.writeAsString(content);
      }
      libdatachannel.add(wrapper.path);
    }

    await compile(
      'maratus_webrtc',
      assetName: 'src/webrtc_driver_native.dart',
      sources: [
        root.resolve('native/maratus_webrtc.cpp').toFilePath(),
        ...libdatachannel,
      ],
      includes: [
        'native',
        '$_libdatachannel/include',
        '$_libdatachannel/include/rtc',
        '$_libdatachannel/src',
        _plog,
        '$_libjuice/include',
        _usrsctp,
        '$_mbedtls/include',
      ],
      defines: {
        ...platform,
        ...mbedtlsConfig,
        'RTC_STATIC': null,
        'RTC_ENABLE_MEDIA': '0',
        'RTC_ENABLE_WEBSOCKET': '0',
        'RTC_SYSTEM_JUICE': '0',
        'RTC_SYSTEM_SRTP': '0',
        'USE_MBEDTLS': '1',
        'USE_GNUTLS': '0',
        'USE_NICE': '0',
        'JUICE_STATIC': null,
      },
      language: Language.cpp,
      flags: [
        if (windows) ...['/EHsc', '/bigobj', '/utf-8'],
        if (os == OS.linux || os == OS.android) ...[
          '-Wl,--exclude-libs,ALL',
          '-Wl,--gc-sections',
        ],
        if (apple) '-Wl,-dead_strip',
      ],
      libraries: [
        'maratus_juice',
        'maratus_usrsctp',
        'maratus_mbedtls',
        if (windows) ...['ws2_32', 'iphlpapi', 'bcrypt', 'advapi32'],
        if (os == OS.linux) ...['stdc++', 'pthread'],
      ],
    );

    output.dependencies.addAll([
      for (final directory in [_libdatachannel, _plog, 'native/usrsctp'])
        for (final entry in Directory.fromUri(
          root.resolve('$directory/'),
        ).listSync(recursive: true))
          if (entry is File) entry.uri,
      root.resolve('native/maratus_mbedtls_config.h'),
      root.resolve('native/maratus_webrtc.h'),
    ]);
  });
}

Future<void> _removeObjects(Uri directory) async {
  await for (final entry in Directory.fromUri(directory).list()) {
    if (entry is File && entry.path.toLowerCase().endsWith('.obj')) {
      await entry.delete();
    }
  }
}
