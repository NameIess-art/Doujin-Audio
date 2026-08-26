import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('library facade remains a thin entry below the line budget', () {
    final source = File(
      'lib/features/library/application/library_facade.dart',
    ).readAsStringSync();
    final nonEmptyLines = source
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().isNotEmpty)
        .length;

    expect(nonEmptyLines, lessThanOrEqualTo(1200));
    expect(source, isNot(contains(RegExp(r'^part\s', multiLine: true))));
  });

  test('library coordinators do not depend on the facade', () {
    const coordinatorFiles = <String>[
      'library_persistence_coordinator.dart',
      'library_metadata_coordinator.dart',
      'library_mutation_coordinator.dart',
      'library_startup_maintenance_coordinator.dart',
    ];

    for (final fileName in coordinatorFiles) {
      final source = File(
        'lib/features/library/application/$fileName',
      ).readAsStringSync();
      expect(
        source,
        allOf(
          isNot(contains('LibraryFacade')),
          isNot(contains('library_facade.dart')),
        ),
        reason: fileName,
      );
    }
  });

  test('startup duration maintenance has no presentation-side trigger', () {
    final source = File(
      'lib/features/library/presentation/library_tab.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('backfillMissingLibraryDurations')));
  });
}
