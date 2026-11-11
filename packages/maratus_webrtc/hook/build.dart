import 'dart:io';
import 'dart:math';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _libdatachannel = 'native/libdatachannel-0.24.6';
const _mbedtls = 'native/mbedtls-3.6.7';
const _usrsctp = 'native/usrsctp/usrsctplib';
const _libjuice = 'native/libjuice';
const _plog = 'native/plog/include';

/// Builds libdatachannel with Mbed TLS, usrsctp, and libjuice, and links them
/// with the package's adapter into one shared library.
void main(List<String> arguments) async {
  await build(arguments, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    final windows = os == OS.windows;
    final apple = os == OS.macOS || os == OS.iOS;
    final root = input.packageRoot;

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

    final dependencies = [
      _Unit(
        'mbedtls',
        sources: sources('$_mbedtls/library', '.c'),
        includes: ['native', '$_mbedtls/include'],
        defines: {
          ...mbedtlsConfig,
          if (windows) '_CRT_SECURE_NO_WARNINGS': null,
        },
      ),
      _Unit(
        'usrsctp',
        sources: sources(_usrsctp, '.c'),
        includes: [_usrsctp],
        defines: {
          ...platform,
          '__Userspace__': null,
          'SCTP_SIMPLE_ALLOCATOR': null,
          'SCTP_PROCESS_LEVEL_LOCKS': null,
        },
        flags: [if (!windows) '-Wno-address-of-packed-member'],
      ),
      _Unit(
        'juice',
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
      ),
    ];
    final libdatachannel = _Unit(
      'libdatachannel',
      sources: sources('$_libdatachannel/src', '.cpp'),
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
      flags: [
        if (windows) ...['/EHsc', '/bigobj', '/utf-8'],
      ],
      language: Language.cpp,
    );
    final library = _Library(
      adapter: root.resolve('native/maratus_webrtc.cpp').toFilePath(),
      libraries: [
        if (windows) ...['ws2_32', 'iphlpapi', 'bcrypt', 'advapi32'],
        if (os == OS.linux) ...['stdc++', 'm', 'pthread'],
      ],
      linkFlags: [
        if (os == OS.linux || os == OS.android) ...[
          // Keeps a statically linked C++ library's symbols private.
          '-Wl,--exclude-libs,ALL',
          '-Wl,--gc-sections',
        ],
        if (apple) '-Wl,-dead_strip',
      ],
    );

    if (windows) {
      await _buildWithMsvc(
        input,
        output,
        dependencies,
        libdatachannel,
        library,
      );
    } else {
      await _buildWithClang(input, output, [
        libdatachannel,
        ...dependencies,
      ], library);
    }

    output.dependencies.addAll([
      for (final directory in [_libdatachannel, _plog, 'native/usrsctp'])
        for (final entry in Directory.fromUri(
          root.resolve('$directory/'),
        ).listSync(recursive: true))
          if (entry is File) entry.uri,
      root.resolve('native/maratus_mbedtls_config.h'),
      root.resolve('native/maratus_webrtc.h'),
      root.resolve('native/maratus_webrtc.cpp'),
    ]);
  });
}

/// Sources compiled with the same settings.
final class _Unit {
  const _Unit(
    this.name, {
    required this.sources,
    required this.includes,
    required this.defines,
    this.flags = const [],
    this.language = Language.c,
  });

  final String name;
  final List<String> sources;
  final List<String> includes;
  final Map<String, String?> defines;
  final List<String> flags;
  final Language language;
}

/// The shared library: the adapter linked with every unit.
final class _Library {
  const _Library({
    required this.adapter,
    required this.libraries,
    required this.linkFlags,
  });

  final String adapter;
  final List<String> libraries;
  final List<String> linkFlags;
}

const _name = 'maratus_webrtc';
const _assetName = 'src/webrtc_driver_native.dart';

/// Builds each dependency as a static library and links them with
/// libdatachannel. `cl.exe` compiles each library's sources in parallel.
Future<void> _buildWithMsvc(
  BuildInput input,
  BuildOutputBuilder output,
  List<_Unit> dependencies,
  _Unit libdatachannel,
  _Library library,
) async {
  final outDir = input.outputDirectory;

  // native_toolchain_c runs MSVC through cmd.exe, which limits the length of
  // a command and would read angle brackets as redirections. cl.exe reads
  // sources and definitions from a response file instead.
  Future<List<String>> respond(
    String name,
    _Unit unit,
    List<String> sources,
  ) async {
    await File.fromUri(outDir.resolve('$name.rsp')).writeAsString(
      [
        for (final MapEntry(:key, :value) in unit.defines.entries)
          value == null ? '/D$key' : '/D$key=$value',
        for (final source in sources) '"$source"',
      ].join('\n'),
    );
    output.dependencies.addAll(unit.sources.map(Uri.file));
    return ['/MP', ...unit.flags, '@$name.rsp'];
  }

  for (final unit in dependencies) {
    final name = 'maratus_${unit.name}';
    // The archiver collects every object file in the output directory.
    await _removeFiles(outDir, '.obj');
    await CBuilder.library(
      name: name,
      sources: const [],
      includes: unit.includes,
      flags: await respond(name, unit, unit.sources),
      linkModePreference: LinkModePreference.static,
    ).run(input: input, output: output);
  }

  // libdatachannel reuses file names across directories, and MSVC names
  // objects after their sources, so each is compiled through a uniquely
  // named wrapper.
  final wrappers = Directory.fromUri(outDir.resolve('libdatachannel/'));
  await wrappers.create(recursive: true);
  final base = input.packageRoot.resolve('$_libdatachannel/src/').toFilePath();
  final wrapped = <String>[library.adapter];
  for (final source in libdatachannel.sources) {
    final name = source
        .substring(base.length)
        .replaceAll(RegExp(r'[\\/]'), '_');
    final wrapper = File.fromUri(wrappers.uri.resolve('ldc_$name'));
    final content = '#include "${source.replaceAll(r'\', '/')}"\n';
    if (!wrapper.existsSync() || wrapper.readAsStringSync() != content) {
      await wrapper.writeAsString(content);
    }
    wrapped.add(wrapper.path);
  }
  await _removeFiles(outDir, '.obj');
  await CBuilder.library(
    name: _name,
    assetName: _assetName,
    sources: const [],
    includes: libdatachannel.includes,
    flags: await respond(_name, libdatachannel, wrapped),
    language: Language.cpp,
    std: 'c++17',
    libraries: [
      for (final unit in dependencies) 'maratus_${unit.name}',
      ...library.libraries,
    ],
  ).run(input: input, output: output);
}

/// Compiles chunks of every unit concurrently and links their objects.
///
/// native_toolchain_c compiles a static library one source at a time. Each
/// chunk is compiled as a separate static library in its own directory, so
/// that chunks can run in parallel. The final link takes the chunks' object
/// files directly, so references between chunks need no archive order.
Future<void> _buildWithClang(
  BuildInput input,
  BuildOutputBuilder output,
  List<_Unit> units,
  _Library library,
) async {
  const common = [
    '-pthread',
    // Only the adapter's API is exported, so the bundled libraries cannot
    // clash with other copies loaded by the application.
    '-fvisibility=hidden',
    '-ffunction-sections',
    '-fdata-sections',
  ];
  final cpp = units.firstWhere((unit) => unit.language == Language.cpp);
  final android = input.config.code.targetOS == OS.android;

  // C++ sources take longest, so they come first, in smaller chunks.
  final jobs = [
    for (final unit in units)
      for (
        var start = 0, size = unit.language == Language.cpp ? 3 : 12;
        start < unit.sources.length;
        start += size
      )
        (
          unit: unit,
          name: '${unit.name}_${start ~/ size}',
          sources: unit.sources.sublist(
            start,
            min(start + size, unit.sources.length),
          ),
        ),
  ];
  final objects = List<List<String>>.filled(jobs.length, const []);
  var next = 0;
  Future<void> work() async {
    while (next < jobs.length) {
      final index = next++;
      final job = jobs[index];
      final chunkInput = BuildInput({
        ...input.json,
        'out_dir_shared': input.outputDirectory
            .resolve('chunks/${job.name}/')
            .toFilePath(),
      });
      final directory = chunkInput.outputDirectory;
      await _removeFiles(directory, '.o');
      await CBuilder.library(
        name: job.name,
        sources: job.sources,
        includes: job.unit.includes,
        defines: job.unit.defines,
        flags: [
          ...common,
          if (job.unit.language == Language.cpp) '-fvisibility-inlines-hidden',
          ...job.unit.flags,
        ],
        language: job.unit.language,
        std: job.unit.language == Language.cpp ? 'c++17' : null,
        linkModePreference: LinkModePreference.static,
      ).run(input: chunkInput, output: output);
      objects[index] = [
        for (final entry in Directory.fromUri(directory).listSync())
          if (entry is File && entry.path.endsWith('.o')) entry.path,
      ]..sort();
    }
  }

  await Future.wait([
    for (var worker = 0; worker < max(1, Platform.numberOfProcessors); worker++)
      work(),
  ]);
  // The objects' paths would exceed the command length limit on Windows
  // hosts, so the compiler reads them from a response file.
  final responses = File.fromUri(input.outputDirectory.resolve('objects.rsp'));
  await responses.writeAsString(
    [
      for (final chunk in objects)
        for (final object in chunk) '"${object.replaceAll(r'\', '/')}"',
    ].join('\n'),
  );

  await CBuilder.library(
    name: _name,
    assetName: _assetName,
    sources: [library.adapter],
    includes: cpp.includes,
    defines: cpp.defines,
    flags: [
      ...common,
      '-fvisibility-inlines-hidden',
      ...library.linkFlags,
      // The objects are linked as they are, not compiled as C++ sources.
      '-x',
      'none',
      '@${responses.path.replaceAll(r'\', '/')}',
    ],
    language: Language.cpp,
    std: 'c++17',
    cppLinkStdLib: android ? 'c++_static' : null,
    libraries: library.libraries,
  ).run(input: input, output: output);
}

Future<void> _removeFiles(Uri directory, String extension) async {
  final folder = Directory.fromUri(directory);
  if (!folder.existsSync()) return;
  await for (final entry in folder.list()) {
    if (entry is File && entry.path.toLowerCase().endsWith(extension)) {
      await entry.delete();
    }
  }
}
