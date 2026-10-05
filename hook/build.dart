// Copyright 2026 The webcrypto.dart authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0

/// Builds package:webcrypto's vendored BoringSSL wrapper as a Dart Native
/// Asset on every supported native target.
///
/// Web builds do not request code assets, so this hook intentionally does
/// nothing for them. With package:native_prebuilt, a native build downloads
/// the library from a release when native_artifacts/prebuilt.json matches
/// the sources (user define `native_build`: auto, download or source).
/// Otherwise it builds from source into a content-addressed, process-locked
/// cache because compiling BoringSSL for every hook invocation is expensive.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_prebuilt/native_prebuilt.dart';
import 'package:native_toolchain_cmake/native_toolchain_cmake.dart';
import 'package:path/path.dart' as p;

const _assetName = 'webcrypto.dart';
const _cacheSchema = 'webcrypto-native-assets-v4';

void main(List<String> args) async {
  final hookLog = _HookLogBuffer('webcrypto');
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final hookStopwatch = Stopwatch()..start();
    final code = input.config.code;
    _validateTarget(code.targetOS, code.targetArchitecture);

    final logger = Logger('')
      ..level = Level.ALL
      ..onRecord.listen((record) => hookLog.add(record.message));

    await NativePrebuilt(input: input, output: output, log: logger.info).run((
      source,
    ) async {
      await _buildFromSource(
        input: input,
        output: output,
        sourceKey: source.sourceKey.key,
        logger: logger,
      );
    });
    logger.info('Hook completed in ${_formatDuration(hookStopwatch.elapsed)}');
  }).whenComplete(hookLog.flush);
}

Future<void> _buildFromSource({
  required BuildInput input,
  required BuildOutputBuilder output,
  required String sourceKey,
  required Logger logger,
}) async {
  final code = input.config.code;
  final defines = <String, String>{
    'CMAKE_BUILD_TYPE': 'Release',
    'CMAKE_POSITION_INDEPENDENT_CODE': 'ON',
  };
  final buildKey = await _computeBuildKey(
    code: code,
    defines: defines,
    sourceKey: sourceKey,
  );

  final libraryFileName = _libraryFileName(code.targetOS);
  final cacheDir = _cacheDirectory(buildKey);
  final cachedLibrary = File(p.join(cacheDir.path, libraryFileName));
  final cachedDigest = File('${cachedLibrary.path}.sha256');
  final lockFile = File('${cacheDir.path}.lock');

  logger.info('Build key: $buildKey');
  logger.info('Cache: ${cacheDir.path}');

  final cacheHit = await _validLibrary(cachedLibrary, cachedDigest);
  if (!cacheHit) {
    final lockAndBuildStopwatch = Stopwatch()..start();
    await _withExclusiveLock(lockFile, () async {
      if (await _validLibrary(cachedLibrary, cachedDigest)) {
        logger.info(
          'Build completed by another process while waiting for the lock',
        );
        return;
      }
      await _buildIntoCache(
        input: input,
        output: output,
        defines: defines,
        cacheDir: cacheDir,
        cachedLibrary: cachedLibrary,
        cachedDigest: cachedDigest,
        libraryFileName: libraryFileName,
        logger: logger,
      );
    }, logger: logger);

    if (!await _validLibrary(cachedLibrary, cachedDigest)) {
      throw StateError(
        'webcrypto cache publication failed for ${code.targetOS.name}/'
        '${code.targetArchitecture.name}: ${cachedLibrary.path}',
      );
    }
    logger.info(
      'Cache miss resolved in '
      '${_formatDuration(lockAndBuildStopwatch.elapsed)}',
    );
  }

  final publishStopwatch = Stopwatch()..start();
  final publishedLibrary = await _publish(
    cachedLibrary,
    input.outputDirectory,
    libraryFileName,
  );
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: _assetName,
      linkMode: DynamicLoadingBundled(),
      file: publishedLibrary.uri,
    ),
  );
  logger.info(
    cacheHit
        ? 'Published the cached build '
              '(${_formatDuration(publishStopwatch.elapsed)})'
        : 'Published the new build '
              '(${_formatDuration(publishStopwatch.elapsed)})',
  );
}

/// Collects logger records so hooks_runner receives one newline-normalized
/// stderr message instead of adding a blank line after every streamed chunk.
final class _HookLogBuffer {
  _HookLogBuffer(this.tag);

  final String tag;
  final List<String> _lines = [];

  void add(String message) {
    final normalized = message.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    for (final line in normalized.split('\n')) {
      if (line.trim().isEmpty) continue;
      _lines.add('[$tag] $line');
    }
  }

  void flush() {
    if (_lines.isEmpty) return;
    // hooks_runner adds the terminating newline while capturing this chunk.
    stderr.write(_lines.join('\n'));
  }
}

String _formatDuration(Duration duration) {
  final millis = duration.inMilliseconds;
  if (millis < 1000) return '${millis}ms';
  final seconds = duration.inSeconds;
  final remainderMillis = millis - seconds * 1000;
  if (seconds < 60) {
    return '$seconds.${(remainderMillis ~/ 100).toString()}s';
  }
  final minutes = seconds ~/ 60;
  final remainderSeconds = seconds % 60;
  return '${minutes}m ${remainderSeconds}s';
}

Future<void> _buildIntoCache({
  required BuildInput input,
  required BuildOutputBuilder output,
  required Map<String, String> defines,
  required Directory cacheDir,
  required File cachedLibrary,
  required File cachedDigest,
  required String libraryFileName,
  required Logger logger,
}) async {
  await cacheDir.create(recursive: true);
  final buildDir = Directory(p.join(cacheDir.path, 'build'));
  if (await buildDir.exists()) await buildDir.delete(recursive: true);
  await buildDir.create(recursive: true);

  final code = input.config.code;
  try {
    final builder = CMakeBuilder.create(
      name: 'webcrypto',
      sourceDir: input.packageRoot.resolve('src/'),
      outDir: buildDir.uri,
      defines: defines,
      targets: const ['webcrypto'],
      buildLocal: false,
      parallelUseAllProcessors: true,
      logger: logger,
    );
    final cmakeStopwatch = Stopwatch()..start();
    await builder.run(input: input, output: output, logger: logger);
    logger.info(
      'CMake build finished in ${_formatDuration(cmakeStopwatch.elapsed)}',
    );

    final builtLibrary = await _findLibrary(buildDir, libraryFileName);
    if (builtLibrary == null || !await _validNonEmptyFile(builtLibrary)) {
      throw StateError(
        'CMake reported success but did not produce a non-empty '
        '$libraryFileName. Build output:\n${await _listBuildOutput(buildDir)}',
      );
    }

    // Publish library and digest under the exclusive build-key lock. The
    // digest lets later invocations reject truncated/corrupt cache entries.
    final temporaryLibrary = File(
      p.join(cacheDir.path, '.$libraryFileName.$pid.tmp'),
    );
    final temporaryDigest = File('${temporaryLibrary.path}.sha256');
    if (await temporaryLibrary.exists()) await temporaryLibrary.delete();
    if (await temporaryDigest.exists()) await temporaryDigest.delete();
    await builtLibrary.copy(temporaryLibrary.path);
    final digest = await _sha256File(temporaryLibrary);
    await temporaryDigest.writeAsString('$digest\n', flush: true);
    if (await cachedLibrary.exists()) await cachedLibrary.delete();
    await temporaryLibrary.rename(cachedLibrary.path);
    if (await cachedDigest.exists()) await cachedDigest.delete();
    await temporaryDigest.rename(cachedDigest.path);
  } catch (error, stackTrace) {
    throw StateError(
      'Failed to build package:webcrypto for ${code.targetOS.name}/'
      '${code.targetArchitecture.name} using the Native Assets target '
      'toolchain. Build directory: ${buildDir.path}. Error: $error\n'
      '$stackTrace',
    );
  }
}

void _validateTarget(OS os, Architecture architecture) {
  final supported = switch (os) {
    OS.android => const {
      Architecture.arm,
      Architecture.arm64,
      Architecture.ia32,
      Architecture.x64,
    },
    OS.iOS => const {Architecture.arm64, Architecture.x64},
    OS.linux => const {Architecture.arm64, Architecture.x64},
    OS.macOS => const {Architecture.arm64, Architecture.x64},
    OS.windows => const {
      Architecture.arm64,
      Architecture.ia32,
      Architecture.x64,
    },
    _ => const <Architecture>{},
  };
  if (!supported.contains(architecture)) {
    throw UnsupportedError(
      'package:webcrypto does not support Native Assets target '
      '${os.name}/${architecture.name}. Supported architectures for '
      '${os.name}: ${supported.map((value) => value.name).join(', ')}.',
    );
  }
}

String _libraryFileName(OS os) => switch (os) {
  OS.windows => 'webcrypto.dll',
  OS.iOS || OS.macOS => 'libwebcrypto.dylib',
  OS.android || OS.linux => 'libwebcrypto.so',
  _ => throw UnsupportedError('package:webcrypto does not support ${os.name}.'),
};

/// The key of the local build cache (ADR 005 D4): the source key of the
/// package and the host toolchain.
Future<String> _computeBuildKey({
  required CodeConfig code,
  required Map<String, String> defines,
  required String sourceKey,
}) async {
  final bytes = BytesBuilder(copy: false);

  void addText(String value) {
    bytes.add(utf8.encode(value));
    bytes.addByte(0);
  }

  addText(_cacheSchema);
  addText('source=$sourceKey');
  addText('os=${code.targetOS.name}');
  addText('arch=${code.targetArchitecture.name}');
  addText('link=${code.linkModePreference}');
  final compiler = code.cCompiler;
  if (compiler != null) {
    for (final tool in <String, Uri>{
      'cc': compiler.compiler,
      'ld': compiler.linker,
      'ar': compiler.archiver,
    }.entries) {
      addText('${tool.key}=${tool.value}');
      if (tool.value.scheme == 'file') {
        final file = File.fromUri(tool.value);
        if (await file.exists()) {
          final stat = await file.stat();
          addText(
            '${tool.key}Stat=${stat.size}:'
            '${stat.modified.microsecondsSinceEpoch}',
          );
        }
      }
    }
  }
  if (code.targetOS == OS.android) {
    addText('androidApi=${code.android.targetNdkApi}');
  } else if (code.targetOS == OS.iOS) {
    addText('iosSdk=${code.iOS.targetSdk}');
    addText('iosVersion=${code.iOS.targetVersion}');
  } else if (code.targetOS == OS.macOS) {
    addText('macosVersion=${code.macOS.targetVersion}');
  }
  for (final define
      in defines.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
    addText('define:${define.key}=${define.value}');
  }
  return sha256.convert(bytes.takeBytes()).toString();
}

Directory _cacheDirectory(String buildKey) {
  final xdg = Platform.environment['XDG_CACHE_HOME'];
  if (xdg != null && xdg.isNotEmpty) {
    return Directory(p.join(xdg, 'webcrypto.dart', buildKey));
  }
  if (Platform.isWindows) {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      return Directory(
        p.join(localAppData, 'webcrypto.dart', 'Cache', buildKey),
      );
    }
  }
  final home =
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      (throw StateError(
        'Cannot locate the webcrypto build cache: HOME, USERPROFILE, and '
        'XDG_CACHE_HOME are all unset.',
      ));
  return Directory(p.join(home, '.cache', 'webcrypto.dart', buildKey));
}

Future<void> _withExclusiveLock(
  File lockFile,
  Future<void> Function() body, {
  required Logger logger,
}) async {
  await lockFile.parent.create(recursive: true);
  final randomAccessFile = await lockFile.open(mode: FileMode.append);
  try {
    final lockStopwatch = Stopwatch()..start();
    await randomAccessFile.lock(FileLock.blockingExclusive);
    if (lockStopwatch.elapsedMilliseconds > 100) {
      logger.info(
        'Waited ${_formatDuration(lockStopwatch.elapsed)} for build lock',
      );
    }
    try {
      await body();
    } finally {
      await randomAccessFile.unlock();
    }
  } finally {
    await randomAccessFile.close();
  }
}

Future<bool> _validLibrary(File library, File digestFile) async {
  if (!await _validNonEmptyFile(library) || !await digestFile.exists()) {
    return false;
  }
  final expected = (await digestFile.readAsString()).trim();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expected)) return false;
  return await _sha256File(library) == expected;
}

Future<bool> _validNonEmptyFile(File file) async =>
    await file.exists() && await file.length() > 0;

Future<String> _sha256File(File file) async {
  final digestSink = _DigestSink();
  final input = sha256.startChunkedConversion(digestSink);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  return digestSink.value.toString();
}

final class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

Future<File?> _findLibrary(Directory root, String fileName) async {
  final candidates = <File>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is File && p.basename(entity.path) == fileName) {
      candidates.add(entity);
    }
  }
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) {
    final releaseA = p.split(a.path).contains('Release') ? 0 : 1;
    final releaseB = p.split(b.path).contains('Release') ? 0 : 1;
    final byConfiguration = releaseA.compareTo(releaseB);
    return byConfiguration != 0 ? byConfiguration : a.path.compareTo(b.path);
  });
  return candidates.first;
}

Future<File> _publish(
  File cachedLibrary,
  Uri outputDirectory,
  String libraryFileName,
) async {
  final output = Directory.fromUri(outputDirectory);
  await output.create(recursive: true);
  final destination = File(p.join(output.path, libraryFileName));
  final temporary = File('${destination.path}.$pid.tmp');
  if (await temporary.exists()) await temporary.delete();
  await cachedLibrary.copy(temporary.path);
  if (await destination.exists()) await destination.delete();
  return temporary.rename(destination.path);
}

Future<String> _listBuildOutput(Directory directory) async {
  final lines = <String>[];
  if (!await directory.exists()) return '  (output directory does not exist)';
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    lines.add('  ${entity.path}');
    if (lines.length == 100) {
      lines.add('  (truncated)');
      break;
    }
  }
  return lines.join('\n');
}
