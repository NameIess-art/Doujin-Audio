import 'dart:async';

import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/dlsite_metadata.dart';
import 'package:doujin_audio/features/library/application/dlsite_metadata_batch_session.dart';
import 'package:doujin_audio/features/library/application/dlsite_metadata_service.dart';
import 'package:doujin_audio/features/library/domain/audio_library_category.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AudioLibraryCategoryEntry entry(String id) {
    final target = AudioDetailTarget.libraryRootFolder('/library/$id');
    return AudioLibraryCategoryEntry(
      target: target,
      title: id,
      path: target.targetPath,
      isFolder: true,
      detail: AudioDetail.empty(target).copyWith(rjCode: 'RJ000$id'),
      tracks: const [],
    );
  }

  DlsiteMetadata metadata(String id) => DlsiteMetadata(
    rjCode: 'RJ000$id',
    workTitle: 'Work $id',
    circleName: 'Circle',
    voiceActors: const [],
    tags: const [],
  );

  test('maps lookup outcomes to found, not found, and failed states', () async {
    final searching = Completer<List<DlsiteMetadata>>();
    final session = DlsiteMetadataBatchSession(
      entries: [entry('001'), entry('002'), entry('003'), entry('004')],
      lookup: (query) => switch (query.rjCode) {
        'RJ000001' => Future<List<DlsiteMetadata>>.value([metadata('001')]),
        'RJ000002' => Future<List<DlsiteMetadata>>.error(
          const DlsiteMetadataException(
            'not found',
            kind: DlsiteMetadataFailureKind.notFound,
          ),
        ),
        'RJ000003' => Future<List<DlsiteMetadata>>.error(StateError('offline')),
        _ => searching.future,
      },
    );
    addTearDown(session.dispose);

    session.start();
    await Future<void>.delayed(Duration.zero);

    expect(session.items[0].status, DlsiteMetadataBatchLookupStatus.found);
    expect(session.items[1].status, DlsiteMetadataBatchLookupStatus.notFound);
    expect(session.items[2].status, DlsiteMetadataBatchLookupStatus.failed);
    expect(session.items[3].status, DlsiteMetadataBatchLookupStatus.searching);
    expect(session.hasPendingLookups, isTrue);

    searching.complete([metadata('004')]);
    await Future<void>.delayed(Duration.zero);
    expect(session.items[3].status, DlsiteMetadataBatchLookupStatus.found);
    expect(session.hasPendingLookups, isFalse);
  });

  test('keeps at most three lookups active and retries failures', () async {
    final pending = <String, Completer<List<DlsiteMetadata>>>{};
    final calls = <String, int>{};
    final session = DlsiteMetadataBatchSession(
      entries: [entry('001'), entry('002'), entry('003'), entry('004')],
      lookup: (query) {
        final id = query.rjCode!;
        calls[id] = (calls[id] ?? 0) + 1;
        return (pending[id] ??= Completer<List<DlsiteMetadata>>()).future;
      },
    );
    addTearDown(session.dispose);

    session.start();
    await Future<void>.delayed(Duration.zero);
    expect(calls.keys, unorderedEquals(['RJ000001', 'RJ000002', 'RJ000003']));

    pending['RJ000001']!.complete([metadata('001')]);
    await Future<void>.delayed(Duration.zero);
    expect(calls.keys, contains('RJ000004'));

    pending['RJ000002']!.completeError(StateError('offline'));
    await Future<void>.delayed(Duration.zero);
    expect(session.items[1].status, DlsiteMetadataBatchLookupStatus.failed);

    pending.remove('RJ000002');
    session.retry(1);
    await Future<void>.delayed(Duration.zero);
    expect(calls['RJ000002'], 2);
  });

  test('retains confirmed metadata and saves only confirmed works', () async {
    final saved = <DlsiteMetadataBatchItem>[];
    final session = DlsiteMetadataBatchSession(
      entries: [entry('001'), entry('002')],
      lookup: (query) async => [metadata(query.rjCode!.substring(5))],
      apply: (item) async {
        saved.add(item);
      },
    );
    addTearDown(session.dispose);

    session.start();
    await Future<void>.delayed(Duration.zero);
    final confirmed = metadata('001').copyWith(workTitle: 'Edited work');
    session.confirm(0, metadata: confirmed, saveCover: true);

    expect(session.items[0].status, DlsiteMetadataBatchLookupStatus.confirmed);
    expect(session.items[0].reviewCandidates.first.workTitle, 'Edited work');
    expect(session.confirmedCount, 1);

    final result = await session.applyConfirmed();
    expect(result.savedCount, 1);
    expect(result.skippedCount, 1);
    expect(result.failedCount, 0);
    expect(saved.single.entry.title, '001');
    expect(saved.single.confirmedMetadata?.workTitle, 'Edited work');
  });

  test(
    'summarizes saved, skipped, and failed batch metadata results',
    () async {
      final session = DlsiteMetadataBatchSession(
        entries: [entry('001'), entry('002'), entry('003'), entry('004')],
        maxConcurrentLookups: 4,
        lookup: (query) => switch (query.rjCode) {
          'RJ000003' => Future<List<DlsiteMetadata>>.error(
            StateError('offline'),
          ),
          _ => Future<List<DlsiteMetadata>>.value([
            metadata(query.rjCode!.substring(5)),
          ]),
        },
        apply: (item) {
          if (item.entry.title == '004') {
            return Future<void>.error(StateError('storage unavailable'));
          }
          return Future<void>.value();
        },
      );
      addTearDown(session.dispose);

      session.start();
      await Future<void>.delayed(Duration.zero);
      session.confirm(0, metadata: metadata('001'), saveCover: false);
      session.confirm(3, metadata: metadata('004'), saveCover: false);

      final result = await session.applyConfirmed();

      expect(result.savedCount, 1);
      expect(result.skippedCount, 1);
      expect(result.failedCount, 2);
      expect(
        result.savedCount + result.skippedCount + result.failedCount,
        session.items.length,
      );
    },
  );

  test('toggleExcluded excludes and restores item, updating lookups and counts', () async {
    final pending = Completer<List<DlsiteMetadata>>();
    final session = DlsiteMetadataBatchSession(
      entries: [entry('001'), entry('002')],
      lookup: (query) => switch (query.rjCode) {
        'RJ000001' => Future<List<DlsiteMetadata>>.value([metadata('001')]),
        _ => pending.future,
      },
    );
    addTearDown(session.dispose);

    session.start();
    await Future<void>.delayed(Duration.zero);

    expect(session.items[0].status, DlsiteMetadataBatchLookupStatus.found);
    expect(session.items[1].status, DlsiteMetadataBatchLookupStatus.searching);
    expect(session.hasPendingLookups, isTrue);

    // Exclude item 1 (still searching)
    var notified = false;
    session.addListener(() => notified = true);
    session.toggleExcluded(1);

    expect(session.items[1].isExcluded, isTrue);
    expect(notified, isTrue);
    // Since item 1 is excluded, hasPendingLookups should be false
    expect(session.hasPendingLookups, isFalse);

    // Confirm item 0 then exclude it
    session.confirm(0, metadata: metadata('001'), saveCover: false);
    expect(session.confirmedCount, 1);
    session.toggleExcluded(0);
    expect(session.items[0].isExcluded, isTrue);
    expect(session.items[0].isReviewable, isFalse);
    expect(session.confirmedCount, 0);

    // Restore item 0
    session.toggleExcluded(0);
    expect(session.items[0].isExcluded, isFalse);
    expect(session.items[0].isReviewable, isTrue);
    expect(session.confirmedCount, 1);
  });

  test('applyConfirmed skips excluded items and does not save them', () async {
    final saved = <DlsiteMetadataBatchItem>[];
    final session = DlsiteMetadataBatchSession(
      entries: [entry('001'), entry('002')],
      lookup: (query) async => [metadata(query.rjCode!.substring(5))],
      apply: (item) async {
        saved.add(item);
      },
    );
    addTearDown(session.dispose);

    session.start();
    await Future<void>.delayed(Duration.zero);
    session.confirm(0, metadata: metadata('001'), saveCover: false);
    session.confirm(1, metadata: metadata('002'), saveCover: false);
    expect(session.confirmedCount, 2);

    // Exclude item 1
    session.toggleExcluded(1);
    expect(session.confirmedCount, 1);

    final result = await session.applyConfirmed();
    expect(result.savedCount, 1);
    expect(result.skippedCount, 1);
    expect(saved.length, 1);
    expect(saved.single.entry.title, '001');
  });
}
