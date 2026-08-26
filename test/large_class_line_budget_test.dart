import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('large coordinators stay within their non-empty line budgets', () {
    const budgets = <String, int>{
      'lib/features/library/application/library_facade.dart': 1200,
      'lib/features/player/application/playback_facade.dart': 1200,
      'lib/features/asmr/application/asmr_download_manager.dart': 900,
      'lib/features/asmr/application/asmr_download_task_store.dart': 550,
      'android/app/src/main/kotlin/com/doujin/audio/player/service/'
              'NativePlaybackService.kt':
          1500,
    };

    for (final entry in budgets.entries) {
      final nonEmptyLines = File(
        entry.key,
      ).readAsLinesSync().where((line) => line.trim().isNotEmpty).length;
      expect(
        nonEmptyLines,
        lessThanOrEqualTo(entry.value),
        reason: <Object>[
          entry.key,
          ' has ',
          nonEmptyLines,
          ' non-empty lines',
        ].join(),
      );
    }
  });

  test('ASMR task state is a composed store rather than a manager part', () {
    final managerSource = File(
      'lib/features/asmr/application/asmr_download_manager.dart',
    ).readAsStringSync();
    final storeSource = File(
      'lib/features/asmr/application/asmr_download_task_store.dart',
    ).readAsStringSync();

    expect(
      managerSource,
      isNot(contains("part 'asmr_download_task_store.dart'")),
    );
    expect(storeSource, contains('final class AsmrDownloadTaskStore'));
    expect(storeSource, isNot(contains('part of')));
    expect(storeSource, isNot(contains('extension AsmrDownloadTaskStore')));
  });
}
