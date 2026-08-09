import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/immutable_collections.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/features/player/domain/audio_effects.dart';

void main() {
  test('immutable collection helpers detach external read-only views', () {
    final listBacking = <String>['one'];
    final mapBacking = <String, int>{'one': 1};
    final setBacking = <String>{'one'};

    final listSnapshot = immutableList<String>(
      UnmodifiableListView<String>(listBacking),
    );
    final mapSnapshot = immutableMap<String, int>(
      UnmodifiableMapView<String, int>(mapBacking),
    );
    final setSnapshot = immutableSet<String>(
      UnmodifiableSetView<String>(setBacking),
    );

    listBacking.add('two');
    mapBacking['two'] = 2;
    setBacking.add('two');

    expect(listSnapshot, <String>['one']);
    expect(mapSnapshot, <String, int>{'one': 1});
    expect(setSnapshot, <String>{'one'});
    expect(() => listSnapshot.add('blocked'), throwsUnsupportedError);
    expect(() => mapSnapshot['blocked'] = 3, throwsUnsupportedError);
    expect(() => setSnapshot.add('blocked'), throwsUnsupportedError);
    expect(immutableList<String>(listSnapshot), same(listSnapshot));
    expect(immutableMap<String, int>(mapSnapshot), same(mapSnapshot));
    expect(immutableSet<String>(setSnapshot), same(setSnapshot));
  });

  test('immutableJsonMap recursively detaches external read-only views', () {
    final listBacking = <Object?>['one'];
    final mapBacking = <Object?, Object?>{'one': 1};
    final setBacking = <Object?>{'one'};
    final jsonBacking = <String, Object?>{
      'list': UnmodifiableListView<Object?>(listBacking),
      'map': UnmodifiableMapView<Object?, Object?>(mapBacking),
      'set': UnmodifiableSetView<Object?>(setBacking),
    };

    final shallowSnapshot = immutableMap<String, Object?>(jsonBacking);
    final snapshot = immutableJsonMap(shallowSnapshot)!;

    expect(snapshot, isNot(same(shallowSnapshot)));

    listBacking.add('two');
    mapBacking['two'] = 2;
    setBacking.add('two');
    jsonBacking['late'] = true;

    expect(snapshot['list'], <Object?>['one']);
    expect(snapshot['map'], <Object?, Object?>{'one': 1});
    expect(snapshot['set'], <Object?>{'one'});
    expect(snapshot, isNot(contains('late')));
    expect(
      () => (snapshot['list'] as List<Object?>).add('blocked'),
      throwsUnsupportedError,
    );
    expect(
      () => (snapshot['map'] as Map<Object?, Object?>)['blocked'] = true,
      throwsUnsupportedError,
    );
    expect(
      () => (snapshot['set'] as Set<Object?>).add('blocked'),
      throwsUnsupportedError,
    );
    expect(immutableJsonMap(snapshot), same(snapshot));
  });

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
