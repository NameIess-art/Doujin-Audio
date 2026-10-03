import 'dart:io';

import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/presentation/library_card_artwork.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';

// Observe the public lookup boundary while retaining real invalidation,
// Riverpod subscriptions and the thumbnail's deferred lookup scheduling.
class _LookupCountingCoverCache extends CoverArtworkCacheService {
  _LookupCountingCoverCache(Directory directory)
    : super(
        libraryService: LibraryService(),
        persistentDirectory: () async => directory,
        temporaryDirectory: () async => directory,
      );

  final List<String> folderLookups = [];

  @override
  Future<String?> futureForFolder(String folderPath) {
    folderLookups.add(folderPath);
    return SynchronousFuture<String?>(null);
  }
}

Future<void> _drainCoverFrames(WidgetTester tester) async {
  // Requests are admitted after layout and completed through the real UI queue.
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  testWidgets('folder thumbnail refreshes only when its cover scope changes', (
    tester,
  ) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('cover_scope_widget_'),
    ))!;
    final covers = _LookupCountingCoverCache(directory);
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: covers,
    );
    addTearDown(() => tester.runAsync(() => directory.delete(recursive: true)));
    addTearDown(fixture.dispose);
    const work = 'E:/library/work';
    await tester.pumpWidget(
      fixture.build(
        const Scaffold(body: LibraryCoverThumbnail(folderPath: work)),
      ),
    );
    await _drainCoverFrames(tester);
    expect(covers.folderLookups, [work]);

    await tester.runAsync(() async {
      covers.invalidateFolder('E:/library/other');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await _drainCoverFrames(tester);
    expect(
      covers.folderLookups,
      [work],
      reason: 'Unrelated import keeps the existing cover lookup.',
    );

    await tester.runAsync(() async {
      covers.invalidateFolder(work);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await _drainCoverFrames(tester);
    expect(covers.folderLookups, [
      work,
      work,
    ], reason: 'The affected cover is requested again.');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
