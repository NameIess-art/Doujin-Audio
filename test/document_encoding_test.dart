import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('README and docs stay valid UTF-8 without replacement characters', () {
    final docs =
        Directory('docs')
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.md'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    final files = [File('README.md'), File('release_notes.md'), ...docs];

    expect(files, isNotEmpty);
    for (final file in files) {
      final text = file.readAsStringSync();
      expect(text, isNot(contains('\uFFFD')), reason: file.path);
    }

    final readme = File('README.md').readAsStringSync();
    expect(readme, contains('Nameless Audio 是一款'));
    expect(readme, contains('当前版本'));
    expect(readme, contains('发布页'));
    expect(readme, contains('GitHub Release'));
  });
}
