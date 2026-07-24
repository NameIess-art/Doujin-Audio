import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/audio_detail.dart';
import 'package:nameless_audio/features/library/domain/audio_library_category.dart';

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
