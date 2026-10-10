import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/features/library/domain/audio_library_category.dart';

void main() {
  test('splitTerms handles Chinese and English commas with dedupe', () {
    expect(
      AudioLibraryCategorySnapshot.splitTerms(['癒し，ASMR', 'ASMR,バイノーラル', '  ']),
      ['癒し', 'ASMR', 'バイノーラル'],
    );
  });

  test('sortTermsByFrequency sorts by count then name', () {
    expect(
      AudioLibraryCategorySnapshot.sortTermsByFrequency({
        'Beta': 1,
        'alpha': 2,
        'Gamma': 2,
      }),
      ['alpha', 'Gamma', 'Beta'],
    );
  });

  test('snapshot indexes entries by equivalent detail target', () {
    final firstTarget = AudioDetailTarget.libraryRootFolder('/music/first');
    final lastTarget = AudioDetailTarget.singleAudioFile('/music/last.mp3');
    final firstEntry = _entry(firstTarget, 'First');
    final lastEntry = _entry(lastTarget, 'Last');
    final snapshot = AudioLibraryCategorySnapshot(
      entries: <AudioLibraryCategoryEntry>[firstEntry, lastEntry],
      tagTerms: const <String>[],
      voiceActorTerms: const <String>[],
      circleTerms: const <String>[],
      structureRevision: 1,
      detailRevision: 2,
    );

    final equivalentTarget = AudioDetailTarget.singleAudioFile(
      '/music/last.mp3',
    );
    expect(snapshot.entryFor(equivalentTarget), same(lastEntry));
    expect(snapshot.detailFor(equivalentTarget), same(lastEntry.detail));
    expect(
      snapshot.detailFor(
        AudioDetailTarget.singleAudioFile('/music/missing.mp3'),
      ),
      isNull,
    );
  });

  test('snapshot keeps the first entry for a duplicate target', () {
    final target = AudioDetailTarget.libraryRootFolder('/music/duplicate');
    final firstEntry = _entry(target, 'First');
    final duplicateEntry = _entry(target, 'Duplicate');
    final snapshot = AudioLibraryCategorySnapshot(
      entries: <AudioLibraryCategoryEntry>[firstEntry, duplicateEntry],
      tagTerms: const <String>[],
      voiceActorTerms: const <String>[],
      circleTerms: const <String>[],
      structureRevision: 1,
      detailRevision: 1,
    );

    expect(snapshot.entryFor(target), same(firstEntry));
  });

  test(
    'detail changes count only changed entries and preserve old snapshots',
    () {
      final firstTarget = AudioDetailTarget.libraryRootFolder('/music/first');
      final secondTarget = AudioDetailTarget.libraryRootFolder('/music/second');
      final first = _CountingCategoryEntry(firstTarget, ['Shared,Old', 'Old']);
      final second = _CountingCategoryEntry(secondTarget, ['Shared']);
      final snapshot = AudioLibraryCategorySnapshot(
        entries: [first, second],
        structureRevision: 1,
        detailRevision: 1,
      );
      first.termReads = second.termReads = 0;

      final updated = snapshot.withDetailChanges({
        firstTarget: first.detail.copyWith(
          tags: ['New,New', 'New'],
          voiceActors: const ['New voice'],
          circleName: '',
        ),
        AudioDetailTarget.libraryRootFolder(
          '/music/missing',
        ): AudioDetail.empty(
          AudioDetailTarget.libraryRootFolder('/music/missing'),
        ),
      }, detailRevision: 2);

      expect(first.termReads, 3);
      expect(second.termReads, 0);
      expect(updated.entries.last, same(second));
      expect(updated.tagTerms, ['New', 'Shared']);
      expect(updated.voiceActorTerms, ['New voice', 'Voice']);
      expect(updated.circleTerms, ['Circle']);
      expect(snapshot.tagTerms, ['Shared', 'Old']);
      expect(snapshot.detailFor(firstTarget), same(first.detail));
      expect(updated.detailRevision, 2);

      final cleared = updated.withDetailChanges({
        secondTarget: AudioDetail.empty(secondTarget),
      }, detailRevision: 3);
      expect(cleared.tagTerms, ['New']);
      expect(cleared.voiceActorTerms, ['New voice']);
      expect(cleared.circleTerms, isEmpty);
    },
  );

  test('detail changes update all duplicate targets without losing counts', () {
    final target = AudioDetailTarget.libraryRootFolder('/music/duplicate');
    final first = _CountingCategoryEntry(target, ['Old']);
    final duplicate = _CountingCategoryEntry(target, ['Other']);
    final snapshot = AudioLibraryCategorySnapshot(
      entries: [first, duplicate],
      structureRevision: 1,
      detailRevision: 1,
    );
    final detail = first.detail.copyWith(tags: ['New']);
    final updated = snapshot.withDetailChanges({
      target: detail,
    }, detailRevision: 2);
    expect(
      updated.entries.map((entry) => entry.detail),
      everyElement(same(detail)),
    );
    expect(updated.entryFor(target), same(updated.entries.first));
    expect(updated.tagTerms, ['New']);
  });
}

class _CountingCategoryEntry extends AudioLibraryCategoryEntry {
  _CountingCategoryEntry(AudioDetailTarget target, List<String> tags)
    : super(
        target: target,
        title: target.targetPath,
        path: target.targetPath,
        isFolder: true,
        detail: AudioDetail.empty(target).copyWith(
          tags: tags,
          voiceActors: const ['Voice'],
          circleName: 'Circle',
        ),
        tracks: const [],
      );

  int termReads = 0;

  @override
  List<String> termsForCategory(AudioLibraryCategoryType type) {
    termReads++;
    return super.termsForCategory(type);
  }
}

AudioLibraryCategoryEntry _entry(AudioDetailTarget target, String title) {
  return AudioLibraryCategoryEntry(
    target: target,
    title: title,
    path: target.targetPath,
    isFolder: target.isLibraryRootFolder,
    detail: AudioDetail(
      target: target,
      rjCode: '',
      workTitle: title,
      circleName: '',
      voiceActors: const <String>[],
      tags: const <String>[],
    ),
    tracks: const [],
  );
}
