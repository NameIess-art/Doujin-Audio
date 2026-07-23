import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/music_track.dart';
import 'package:nameless_audio/features/asmr/domain/asmr_models.dart';
import 'package:nameless_audio/features/library/domain/library_node.dart';
import 'package:nameless_audio/features/player/domain/audio_effects.dart';

void main() {
  test('value objects copy and protect collection inputs', () {
    final tags = <String>['rain'];
    final metadata = <String, Object?>{
      'nested': <Object?>['quiet'],
    };
    final track = MusicTrack(
      path: '/music/rain.mp3',
      displayName: 'Rain',
      groupKey: '/music',
      groupTitle: 'Music',
      groupSubtitle: '',
      isSingle: true,
      tags: tags,
      remoteMetadata: metadata,
    );

    tags.add('night');
    (metadata['nested'] as List<Object?>).add('sleep');

    expect(track.tags, ['rain']);
    expect(track.remoteMetadata?['nested'], ['quiet']);
    expect(() => track.tags.add('blocked'), throwsUnsupportedError);
    expect(
      () => (track.remoteMetadata?['nested'] as List<Object?>).add('blocked'),
      throwsUnsupportedError,
    );
  });

  test('copyWith and nested domain collections remain immutable', () {
    final roots = <AsmrTrackFile>[];
    final work = AsmrWork(
      id: 1,
      title: 'Work',
      circleName: 'Circle',
      sourceId: 'RJ000001',
      sourceType: 'asmr',
      sourceUrl: '',
      coverUrl: '',
      thumbnailUrl: '',
      mainCoverUrl: '',
      releaseDate: null,
      createDate: null,
      duration: Duration.zero,
      dlCount: 0,
      reviewCount: 0,
      rating: 0,
      voiceActors: const <String>['A'],
      tags: const <String>['B'],
    );
    final file = AsmrTrackFile(
      hash: 'hash',
      title: 'track.mp3',
      type: 'audio',
      streamUrl: null,
      downloadUrl: null,
      lowQualityUrl: null,
      duration: Duration.zero,
      size: 1,
      children: roots,
      workId: work.id,
      workTitle: work.title,
      sourceId: work.sourceId,
      relativePath: 'track.mp3',
    );

    roots.add(file);
    expect(file.children, isEmpty);
    expect(() => file.children.add(file), throwsUnsupportedError);
    expect(() => work.tags[0] = 'blocked', throwsUnsupportedError);
  });

  test('FolderNode exposes read-only children and invalidates metrics', () {
    final folder = FolderNode('Folder', '/folder');
    folder.addChild(
      TrackNode(
        MusicTrack(
          path: '/folder/one.mp3',
          displayName: 'One',
          groupKey: '/folder',
          groupTitle: 'Folder',
          groupSubtitle: '',
          isSingle: false,
          duration: const Duration(minutes: 1),
        ),
      ),
    );
    expect(folder.totalTrackCount, 1);
    expect(folder.totalDuration, const Duration(minutes: 1));

    folder.addChild(
      TrackNode(
        MusicTrack(
          path: '/folder/two.mp3',
          displayName: 'Two',
          groupKey: '/folder',
          groupTitle: 'Folder',
          groupSubtitle: '',
          isSingle: false,
          duration: const Duration(minutes: 2),
        ),
      ),
    );

    expect(folder.totalTrackCount, 2);
    expect(folder.totalDuration, const Duration(minutes: 3));
    expect(
      () => folder.children.add(TrackNode(folder.allTracks.first)),
      throwsUnsupportedError,
    );
  });

  test('effect state maps are immutable', () {
    final levels = <int, double>{1000: 2};
    final state = AudioEffectsState(eqBandLevels: levels);
    levels[2000] = 3;

    expect(state.eqBandLevels, {1000: 2});
    expect(() => state.eqBandLevels[3000] = 4, throwsUnsupportedError);
  });
}
