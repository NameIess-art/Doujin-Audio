import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  test(
    'presentation does not access project platform or persistence boundaries',
    () {
      final roots = <Directory>[
        Directory(path.join('lib', 'features')),
        Directory(path.join('lib', 'core', 'widgets')),
      ];
      final violations = <String>[];
      for (final root in roots) {
        for (final entity in root.listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          if (root.path.endsWith('features') &&
              !path.split(entity.path).contains('presentation')) {
            continue;
          }
          final source = entity.readAsStringSync();
          for (final forbidden in <String>[
            'FilePicker.platform',
            'MethodChannel(',
            'AppDatabase(',
          ]) {
            if (source.contains(forbidden)) {
              violations.add('${entity.path}: $forbidden');
            }
          }
        }
      }
      expect(violations, isEmpty);
    },
  );
}
