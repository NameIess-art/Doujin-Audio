import 'dart:async';

import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/asmr/application/asmr_work_content_store.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const key = (
    workKey: 'code:RJ000001',
    contentEpoch: 0,
    authEpoch: 0,
    runtimeCacheEpoch: 0,
  );

  test(
    'pending playable conversion shares only the same context and tree',
    () async {
      final store = AsmrWorkContentStore(onChanged: () {});
    final work = AsmrWork.fromJson(const {'id': 1, 'source_id': 'RJ000001'});
      final tree = <AsmrTrackFile>[];
      final pending = Completer<List<MusicTrack>>();
      var calls = 0;
      Future<List<MusicTrack>> load() {
        calls++;
        return pending.future;
      }

      final first = store.requestPlayableTracks(key, work, tree, load);
      expect(store.requestPlayableTracks(key, work, tree, load), same(first));
      final replacement = store.requestPlayableTracks(key, work, [], load);
      final changedContext = store.requestPlayableTracks(
        (
          workKey: key.workKey,
          contentEpoch: 1,
          authEpoch: 0,
          runtimeCacheEpoch: 0,
        ),
        work,
        tree,
        load,
      );
      expect(calls, 3);
      pending.complete([]);
      await Future.wait([first, replacement, changedContext]);
      await store.requestPlayableTracks(key, work, tree, load);
      expect(calls, 4);
    },
  );

  test(
    'failed playable conversion clears its pending entry for retry',
    () async {
      final store = AsmrWorkContentStore(onChanged: () {});
    final work = AsmrWork.fromJson(const {'id': 1, 'source_id': 'RJ000001'});
      final tree = <AsmrTrackFile>[];
      var calls = 0;
      Future<List<MusicTrack>> load() async {
        if (++calls == 1) throw StateError('conversion failed');
        return [];
      }

      await expectLater(
        store.requestPlayableTracks(key, work, tree, load),
        throwsStateError,
      );
      expect(await store.requestPlayableTracks(key, work, tree, load), isEmpty);
      expect(calls, 2);
    },
  );
}
