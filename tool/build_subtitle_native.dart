import 'dart:convert';
import 'dart:io';

// Build the pinned CrispASR C ABI used by Japanese script alignment and chat.
// Outputs live in ignored build directories; no generated binary is committed.
const _sourceUrl = 'https://github.com/CrispStrobe/CrispASR.git';
const _sourceTag = 'v0.8.37';
const _sourceCommit = '4408fe0f27d7b72308fa3430a0cfac8e5a82b40d';
const _ggmlCommit = '2f5a80d258c46e6ac8eee95f1328c0f58376d7ee';
const _c2paCommit = 'e40329b83f16f67bb5ddc7bb13ae18de0a9376fc';

Future<void> _run(
  String executable,
  List<String> arguments, {
  String? cwd,
}) async {
  stdout.writeln('> $executable ${arguments.join(' ')}');
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: cwd,
    mode: ProcessStartMode.inheritStdio,
  );
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw StateError('$executable exited with $exitCode');
  }
}

Future<String> _capture(
  String executable,
  List<String> arguments, {
  String? cwd,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: cwd,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw StateError('$executable ${arguments.join(' ')}: ${result.stderr}');
  }
  return (result.stdout as String).trim();
}

String _option(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) {
    throw ArgumentError('Missing $name');
  }
  return args[index + 1];
}

Future<void> _verifySubmodule(String source, String path, String commit) async {
  final head = await _capture('git', [
    'rev-parse',
    'HEAD',
  ], cwd: '$source/$path');
  if (head != commit) {
    throw StateError('$path is at $head; expected $commit');
  }
  final changes = await _capture('git', [
    'status',
    '--porcelain',
  ], cwd: '$source/$path');
  if (changes.isNotEmpty) {
    throw StateError('$path has local changes; refusing to build');
  }
}

Future<void> _prepareSource(String source) async {
  final directory = Directory(source);
  if (directory.existsSync()) {
    final head = await _capture('git', ['rev-parse', 'HEAD'], cwd: source);
    if (head != _sourceCommit) {
      stdout.writeln('Recreating $source for $_sourceCommit (was $head)');
      await directory.delete(recursive: true);
    }
  }
  if (!directory.existsSync()) {
    await _run('git', [
      'clone',
      '--depth',
      '1',
      '--branch',
      _sourceTag,
      '--filter=blob:none',
      _sourceUrl,
      source,
    ]);
  }
  final head = await _capture('git', ['rev-parse', 'HEAD'], cwd: source);
  if (head != _sourceCommit) {
    throw StateError('CrispASR is at $head; expected $_sourceCommit');
  }
  await _run('git', [
    'submodule',
    'update',
    '--init',
    '--depth',
    '1',
  ], cwd: source);
  await _verifySubmodule(source, 'ggml', _ggmlCommit);
  await _verifySubmodule(source, 'third_party/c2pa-audio', _c2paCommit);

  // Upstream auto-romanizes all CJK input for CTC aligners. The pinned
  // Japanese Wav2Vec2 model has Japanese labels, so its reference must remain
  // in the original script. Verify the exact upstream text before patching.
  const fileName = 'src/crispasr_aligner.cpp';
  final original = await _capture('git', [
    'show',
    'HEAD:$fileName',
  ], cwd: source);
  const start =
      '    // Disable the romanized labels with CRISPASR_ALIGN_NO_ROMANIZE=1.';
  const end = '    // Restore the original-script text onto the aligned words.';
  final from = original.indexOf(start);
  final to = original.indexOf(end, from);
  if (from < 0 || to < 0 || original.indexOf(start, from + 1) >= 0) {
    throw StateError('Unexpected CrispASR aligner source layout');
  }
  final patched =
      '${original.substring(0, from)}'
      '    // Japanese CTC alignment uses original-script labels.\n'
      '    const auto orig_words = tokenise_words(transcript);\n'
      '    const auto display_words = tokenise_display_words(transcript);\n'
      '    const std::vector<std::string> label_words = orig_words;\n'
      '${original.substring(to)}\n';
  final file = File('$source/$fileName');
  final current = (await file.readAsString())
      .replaceAll('\r\n', '\n')
      .trimRight();
  if (current != original && current != patched.trimRight()) {
    throw StateError('Unexpected local modifications to $fileName');
  }
  if (current != patched.trimRight()) {
    await file.writeAsString(patched);
  }
  final changed = await _capture('git', ['diff', '--name-only'], cwd: source);
  if (changed != fileName) {
    throw StateError('Unexpected CrispASR source changes: $changed');
  }
}

File _findBuiltLibrary(String build, String name) {
  final matches = Directory(build)
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((file) => file.uri.pathSegments.last == name)
      .toList();
  if (matches.length != 1) {
    throw StateError('Expected one $name in $build, found ${matches.length}');
  }
  return matches.single;
}

Future<void> _copyLibraries(
  String build,
  String destination,
  List<String> names,
) async {
  await Directory(destination).create(recursive: true);
  for (final name in names) {
    final source = _findBuiltLibrary(build, name);
    final output = File('$destination/$name');
    await source.copy(output.path);
    stdout.writeln('${output.path}: ${await output.length()} bytes');
  }
}

Future<void> _copyLicenses(String source, String destination) async {
  final directory = Directory('$destination/licenses');
  await directory.create(recursive: true);
  const licenses = {
    'CrispASR-LICENSE.txt': 'LICENSE',
    'ggml-LICENSE.txt': 'ggml/LICENSE',
    'c2pa-audio-LICENSE.txt': 'third_party/c2pa-audio/LICENSE',
    'micro-ecc-LICENSE.txt':
        'third_party/c2pa-audio/third_party/uecc/LICENSE.txt',
  };
  for (final entry in licenses.entries) {
    await File('$source/${entry.value}').copy('${directory.path}/${entry.key}');
  }
}

Future<void> main(List<String> args) async {
  final platform = _option(args, '--platform');
  final output = Directory(_option(args, '--output')).absolute.path;
  final root = File.fromUri(Platform.script).parent.parent.absolute.path;
  final source = '$root/.dart_tool/subtitle_sources/crispasr';
  await _prepareSource(source);

  const common = [
    '-DBUILD_SHARED_LIBS=ON',
    '-DCRISPASR_BUILD_EXAMPLES=OFF',
    '-DCRISPASR_BUILD_TESTS=OFF',
    '-DCRISPASR_BUILD_SERVER=OFF',
    '-DCRISPASR_OPUS=OFF',
    '-DCRISPASR_AMR=OFF',
    '-DGGML_CUDA=OFF',
    '-DGGML_VULKAN=OFF',
    '-DGGML_OPENMP=OFF',
  ];
  if (platform == 'windows') {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows native build requires Windows');
    }
    final build = '$source/build-msvc';
    await _run('cmake', [
      '-S',
      source,
      '-B',
      build,
      '-A',
      'x64',
      '-DCRISPASR_PORTABLE_CPU=ON',
      ...common,
    ]);
    await _run('cmake', [
      '--build',
      build,
      '--config',
      'Release',
      '--target',
      'crispasr-lib',
      '--parallel',
      '8',
    ]);
    await _copyLibraries(build, output, [
      'crispasr.dll',
      'ggml.dll',
      'ggml-base.dll',
      'ggml-cpu.dll',
    ]);
    await _copyLicenses(source, output);
  } else if (platform == 'android') {
    final ndk = _option(args, '--ndk');
    final ninja = _option(args, '--ninja');
    final assetsOutput = _option(args, '--assets-output');
    final toolchain = '$ndk/build/cmake/android.toolchain.cmake';
    if (!File(toolchain).existsSync()) {
      throw StateError('Android NDK toolchain not found: $toolchain');
    }
    final host = Platform.isWindows ? 'windows-x86_64' : 'linux-x86_64';
    final llvm = '$ndk/toolchains/llvm/prebuilt/$host';
    final strip = '$llvm/bin/llvm-strip${Platform.isWindows ? '.exe' : ''}';
    final clangVersion = Directory('$llvm/lib/clang')
        .listSync()
        .whereType<Directory>()
        .single
        .path;
    for (final abi in ['arm64-v8a', 'x86_64']) {
      final build = '$source/build-android/$abi';
      await _run('cmake', [
        '-S',
        source,
        '-B',
        build,
        '-G',
        'Ninja',
        '-DCMAKE_MAKE_PROGRAM=$ninja',
        '-DCMAKE_TOOLCHAIN_FILE=$toolchain',
        '-DANDROID_ABI=$abi',
        '-DANDROID_PLATFORM=android-24',
        '-DCMAKE_BUILD_TYPE=Release',
        '-DGGML_NATIVE=OFF',
        ...common,
      ]);
      await _run('cmake', [
        '--build',
        build,
        '--target',
        'crispasr-lib',
        '--parallel',
        '8',
      ]);
      await _copyLibraries(build, '$output/$abi', [
        'libcrispasr.so',
        'libggml.so',
        'libggml-base.so',
        'libggml-cpu.so',
      ]);
      final ompArch = abi == 'arm64-v8a' ? 'aarch64' : 'x86_64';
      await File('$clangVersion/lib/linux/$ompArch/libomp.so')
          .copy('$output/$abi/libomp.so');
      for (final name in [
        'libcrispasr.so',
        'libggml.so',
        'libggml-base.so',
        'libggml-cpu.so',
        'libomp.so',
      ]) {
        await _run(strip, ['--strip-unneeded', '$output/$abi/$name']);
      }
    }
    await _copyLicenses(source, assetsOutput);
    await File('$ndk/NOTICE.toolchain').copy(
      '$assetsOutput/licenses/Android-NDK-NOTICE.txt',
    );
  } else {
    throw ArgumentError('Unsupported platform: $platform');
  }
}
