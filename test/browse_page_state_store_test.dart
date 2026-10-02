import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/application/browse_page_state_store.dart';

void main() {
  test(
    'committed display state survives a new store without repeated writes',
    () async {
      String? disk;
      var writes = 0;
      BrowsePageStateStore create() => BrowsePageStateStore(
        read: () async => disk,
        write: (value) async {
          disk = value;
          writes++;
        },
      );
      final first = create();
      await first.initialize();
      first.update('library-search', {
        'query': '雨',
        'tags': ['ASMR'],
        'offset': 280.0,
      });
      await first.flush();
      first.update('library-search', {
        'tags': ['ASMR'],
      });
      await first.flush();
      expect(writes, 1);
      final restarted = create();
      await restarted.initialize();
      expect(restarted.stateFor('library-search')['query'], '雨');
      expect(restarted.stateFor('library-search')['offset'], 280.0);
      expect(restarted.stateFor('library-search')['tags'], ['ASMR']);
    },
  );

  test(
    'clear rejects delayed initialization and retired page writes',
    () async {
      final read = Completer<String?>();
      String? disk;
      final store = BrowsePageStateStore(
        read: () => read.future,
        write: (value) async => disk = value,
      );
      final oldEpoch = store.epoch;
      final initializing = store.initialize();
      final clearing = store.clear();
      read.complete('{"version":1,"pages":{"old":{"offset":100}}}');
      await initializing;
      await clearing;
      store.update('old', {'offset': 900}, epoch: oldEpoch);
      await store.flush();
      expect(store.stateFor('old'), isEmpty);
      expect(disk, isNull);
    },
  );

  test(
    'save failure keeps display state available and later writes recover',
    () async {
      var fail = true;
      String? disk;
      final store = BrowsePageStateStore(
        read: () async => null,
        write: (value) async {
          if (fail) throw StateError('disk unavailable');
          disk = value;
        },
      );
      store.update('work', {
        'directory': ['音声'],
      });
      await store.flush();
      expect(store.stateFor('work')['directory'], ['音声']);
      fail = false;
      store.update('work', {'offset': 180});
      await store.flush();
      expect(disk, contains('音声'));
    },
  );
  test('failed cache clear does not poison subsequent saves', () async {
    String? disk;
    final store = BrowsePageStateStore(
      read: () async => null,
      write: (value) async {
        if (value == null) throw StateError('disk unavailable');
        disk = value;
      },
    );
    await store.clear();
    store.update('new', {'offset': 120});
    await store.flush();
    expect(disk, contains('120'));
  });
}
