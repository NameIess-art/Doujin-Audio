import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'published root docs stay valid UTF-8 without replacement characters',
    () {
      final files = [File('README.md'), File('release_notes.md')];

      expect(files, isNotEmpty);
      for (final file in files) {
        final text = file.readAsStringSync();
        expect(text, isNot(contains('\uFFFD')), reason: file.path);
      }
    },
  );
}
