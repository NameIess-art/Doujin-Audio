import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_tag_interest.dart';

void main() {
  test(
    'directory preserves distinct online ids sharing a translated alias',
    () {
      final state = AsmrTagPreferences();
      state.mergeTag(
        AsmrTag(key: 'online:1', name: 'a', onlineId: 1, aliases: ['shared']),
      );
      state.mergeTag(
        AsmrTag(key: 'online:2', name: 'b', onlineId: 2, aliases: ['shared']),
      );
      expect(state.tags.keys, containsAll(['online:1', 'online:2']));
    },
  );

  test(
    'removal lowers weight and recovers only after enough new listening',
    () {
      final state = AsmrTagPreferences();
      final key = state.resolve('Sleep');
      state.weights[key] = 200;
      state.setInterested(key, false);
      expect(state.weights[key], 180);
      expect(state.interests, isEmpty);
      state.recordListeningBatch('android:epoch:1', [
        (tags: ['Sleep'], duration: const Duration(minutes: 19)),
      ]);
      expect(state.interests, isEmpty);
      state.recordListeningBatch('android:epoch:2', [
        (tags: ['Sleep'], duration: const Duration(minutes: 1)),
      ]);
      expect(state.interests.single.weight, 200);
    },
  );

  test(
    'all selected interests persist while listening determines the top twenty',
    () {
      final state = AsmrTagPreferences();
      for (var i = 0; i < 22; i++) {
        final key = state.resolve('tag$i');
        state.weights[key] = 50.0 + i;
        state.learned[key] = i.toDouble();
      }
      final key = state.resolve('new tag');
      state.setInterested(key, true);
      expect(state.interests, hasLength(23));
      expect(state.interests.map((e) => e.tag.key), contains(key));
      expect(
        state.interests.take(20).map((e) => e.tag.key),
        isNot(contains(key)),
      );
      expect(state.weights[key], 1);
      final restored = AsmrTagPreferences.fromJson(state.toJson());
      expect(restored.interests, hasLength(23));
      restored.recordListeningBatch('test:1', [
        (tags: ['new tag'], duration: const Duration(minutes: 100)),
      ]);
      expect(restored.interests.first.tag.key, key);
      state.setInterested(key, false);
      state.setInterested(key, true);
      expect(state.hiddenUntil.containsKey(key), isFalse);
    },
  );

  test(
    'listening divides unique tag minutes and round trips batch cursors',
    () {
      var state = AsmrTagPreferences();
      final batch = [
        (tags: ['a', 'A', 'b'], duration: const Duration(minutes: 20)),
        (tags: ['b'], duration: const Duration(minutes: 5)),
      ];
      expect(state.recordListeningBatch('windows:epoch:1', batch), isTrue);
      state = AsmrTagPreferences.fromJson(state.toJson());
      expect(state.recordListeningBatch('windows:epoch:1', batch), isFalse);
      expect(state.weights[state.resolve('a')], 10);
      expect(state.weights[state.resolve('b')], 15);
      expect(state.recordListeningBatch('windows:other:1', batch), isTrue);
      expect(state.consumedSequences.length, 2);
    },
  );

  test('online aliases migrate local signals, removal and exclusions', () {
    final state = AsmrTagPreferences();
    final key = state.resolve('耳かき');
    state.weights[key] = 100;
    state.setInterested(key, false);
    state.excluded.add(key);
    state.mergeTag(
      AsmrTag(
        key: 'online:3',
        name: '耳かき',
        onlineId: 3,
        aliases: ['挖耳', 'Ear Cleaning'],
      ),
    );
    expect(state.tags.containsKey(key), isFalse);
    expect(state.weights['online:3'], 90);
    expect(state.hiddenUntil['online:3'], 10);
    expect(state.resolve('ear cleaning'), 'online:3');
    expect(state.excludes(names: ['挖耳']), isTrue);
    expect(state.excludes(names: [], ids: [3]), isTrue);
    state.excluded.clear();
    expect(state.excludes(names: ['挖耳']), isFalse);
    expect(state.recommendationWeights['ear cleaning'], 90);
  });
}
