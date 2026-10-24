import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_tag_interest.dart';

void main() {
  test(
    'recommendations use automatic top twenty plus unlimited manual additions',
    () {
      final state = AsmrTagPreferences();
      for (var i = 0; i < 25; i++) {
        state.learned[state.resolve('tag$i')] = i + 1.0;
      }
      final ranking = state.interests.map((e) => e.tag.key).toList();
      expect(state.recommendationWeights, hasLength(20));
      expect(state.recommendationWeights, isNot(contains('tag0')));
      state.setInterested('local:tag0', true);
      expect(state.recommendationWeights, hasLength(21));
      expect(state.interests.map((e) => e.tag.key), ranking);
      state.setInterested('local:tag0', false);
      state.recordListeningBatch('test:1', [
        (tags: ['tag0'], duration: const Duration(minutes: 100)),
      ]);
      expect(state.manualInterests, isEmpty);
      expect(state.interests.first.tag.key, 'local:tag0');
      expect(state.recommendationWeights, contains('tag0'));
    },
  );

  test(
    'listening ranking is independent of unlimited manual recommendation choices',
    () {
      final state = AsmrTagPreferences();
      for (var i = 0; i < 25; i++) {
        final key = state.resolve('tag$i');
        state.setInterested(key, true);
        state.learned[key] = i + 1.0;
      }
      final original = state.interests.map((e) => e.tag.key).toList();
      expect(original, hasLength(20));
      expect(original.first, 'local:tag24');
      expect(original.last, 'local:tag5');
      state.setInterested('local:tag24', false);
      final newKey = state.resolve('never listened');
      state.setInterested(newKey, true);
      expect(state.interests.map((e) => e.tag.key), original);
      expect(state.manualInterests, hasLength(25));
      final restored = AsmrTagPreferences.fromJson(state.toJson());
      expect(restored.manualInterests, state.manualInterests);
      expect(restored.interests.map((e) => e.tag.key), original);
      expect(restored.recommendationWeights['never listened'], 1);
      restored.setInterested(newKey, false);
      expect(restored.recommendationWeights, isNot(contains('never listened')));
      restored.recordListeningBatch('test:1', [
        (tags: ['tag0'], duration: const Duration(minutes: 100)),
      ]);
      expect(restored.interests.first.tag.key, 'local:tag0');
    },
  );

  test(
    'manual choices fill only vacancies, without changing listening minutes',
    () {
      final state = AsmrTagPreferences();
      final a = state.resolve('A');
      final b = state.resolve('B');
      state.setInterested(a, true);
      state.setInterested(b, true);
      expect(state.interests.map((e) => e.tag.key), [a, b]);
      expect(state.listenedInterests, isEmpty);
      state.recordListeningBatch('test:1', [
        (tags: ['B'], duration: const Duration(minutes: 1)),
      ]);
      expect(state.interests.map((e) => e.tag.key), [b, a]);
      state.setInterested(b, false);
      expect(state.interests.map((e) => e.tag.key), [b, a]);
      expect(state.learned[b], 1);
      expect(state.recommendationWeights['b'], 1);
      state.setInterested(a, false);
      expect(state.interests.map((e) => e.tag.key), [b]);
      state.recordListeningBatch('test:2', [
        (tags: ['A'], duration: const Duration(minutes: 2)),
      ]);
      expect(state.manualInterests, isEmpty);
      expect(state.interests.first.tag.key, a);
    },
  );

  test(
    'legacy selections migrate without treating mixed weights as listening',
    () {
      final state = AsmrTagPreferences.fromJson({
        'tags': [
          AsmrTag(key: 'a', name: 'A').toJson(),
          AsmrTag(key: 'b', name: 'B').toJson(),
        ],
        'weights': {'a': 100, 'b': 90},
        'hiddenUntil': {'b': 10},
        'learned': {'b': 5},
      });
      expect(state.manualInterests, {'a'});
      expect(state.listenedInterests.single.tag.key, 'b');
      expect(state.listenedInterests.single.weight, 5);
      state.setInterested('a', false);
      final restored = AsmrTagPreferences.fromJson(state.toJson());
      expect(restored.manualInterests, isEmpty);
      expect(restored.interests.single.tag.key, 'b');
    },
  );

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
      expect(state.learned[state.resolve('a')], 10);
      expect(state.learned[state.resolve('b')], 15);
      expect(state.manualInterests, isEmpty);
      expect(state.recordListeningBatch('windows:other:1', batch), isTrue);
      expect(state.consumedSequences.length, 2);
    },
  );

  test(
    'online aliases migrate listening, manual choices and exclusions independently',
    () {
      final state = AsmrTagPreferences();
      final key = state.resolve('耳かき');
      state.learned[key] = 100;
      state.setInterested(key, true);
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
      expect(state.learned['online:3'], 100);
      expect(state.manualInterests, {'online:3'});
      expect(state.resolve('ear cleaning'), 'online:3');
      expect(state.excludes(names: ['挖耳']), isTrue);
      expect(state.excludes(names: [], ids: [3]), isTrue);
      state.excluded.clear();
      expect(state.excludes(names: ['挖耳']), isFalse);
      expect(state.recommendationWeights['ear cleaning'], 1);
    },
  );
}
