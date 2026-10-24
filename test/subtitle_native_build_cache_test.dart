import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/build_subtitle_native.dart';

void main() {
  late Directory output;
  const libraries = ['crispasr.dll', 'ggml.dll'];

  String identity({
    String recipe = 'source and patch',
    String abi = 'x64',
    String platform = 'windows',
    String toolchain = 'compiler 1',
  }) => subtitleNativeBuildIdentity(
    scriptBytes: recipe.codeUnits,
    platform: platform,
    abi: abi,
    toolchain: toolchain,
  );

  setUp(() async {
    output = await Directory.systemTemp.createTemp('subtitle_build_cache_');
    for (final library in libraries) {
      await File('${output.path}/$library').writeAsBytes([1, 2, 3]);
    }
  });
  tearDown(() async => output.delete(recursive: true));

  test('legacy binaries without build identity must be rebuilt', () {
    expect(
      hasSubtitleNativeOutputs(output.path, libraries, identity()),
      isFalse,
    );
  });

  test('matching complete outputs are reused', () async {
    await File('${output.path}/build-identity.json').writeAsString(identity());
    expect(
      hasSubtitleNativeOutputs(output.path, libraries, identity()),
      isTrue,
    );
  });

  test(
    'source patch configuration ABI and toolchain changes reject old outputs',
    () async {
      await File(
        '${output.path}/build-identity.json',
      ).writeAsString(identity());
      for (final changed in [
        identity(recipe: 'new source'),
        identity(recipe: 'new alignment patch'),
        identity(recipe: 'new CMake options'),
        identity(abi: 'arm64-v8a'),
        identity(platform: 'android'),
        identity(toolchain: 'compiler 2'),
      ]) {
        expect(
          hasSubtitleNativeOutputs(output.path, libraries, changed),
          isFalse,
        );
      }
    },
  );

  test(
    'missing empty or uncommitted partial outputs cannot be reused',
    () async {
      final marker = File('${output.path}/build-identity.json');
      await marker.writeAsString(identity());
      final library = File('${output.path}/${libraries.last}');
      await library.delete();
      expect(
        hasSubtitleNativeOutputs(output.path, libraries, identity()),
        isFalse,
      );
      await library.writeAsBytes([]);
      expect(
        hasSubtitleNativeOutputs(output.path, libraries, identity()),
        isFalse,
      );
      await library.writeAsBytes([1]);
      await marker.delete();
      expect(
        hasSubtitleNativeOutputs(output.path, libraries, identity()),
        isFalse,
      );
    },
  );
}
