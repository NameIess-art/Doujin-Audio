import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_tag_interest.dart';

void main() {
  test(
    'batch directory merge retains sequential aliases and preference signals',
    () {
      AsmrTagPreferences seed() {
        final state = AsmrTagPreferences();
        for (final name in ['First', 'Second', 'Third']) {
          final key = state.resolve(name);
          state.learned[key] = 3;
          state.manualInterests.add(key);
          state.excluded.add(key);
        }
        return state;
      }

      final incoming = [
        AsmrTag(key: 'online:1', name: 'First', aliases: ['Second']),
        AsmrTag(key: 'online:2', name: 'Third', aliases: ['Second']),
        AsmrTag(key: 'online:1', name: 'Renamed', aliases: ['Other']),
      ];
      final sequential = seed();
      for (final tag in incoming) {
        sequential.mergeTag(tag);
      }
      final batch = seed()..mergeTags(incoming);
      expect(batch.toJson(), sequential.toJson());
      expect(batch.learned, {'online:1': 6, 'online:2': 3});
      expect(batch.manualInterests, {'online:1', 'online:2'});
      expect(batch.excluded, {'online:1', 'online:2'});
      expect(
        batch.tags['online:1']!.aliases,
        containsAll(['First', 'Second', 'Other']),
      );
      expect(batch.tags['online:2']!.aliases, containsAll(['Third', 'Second']));
    },
  );

  for (final count in [1000, 5000, 20000]) {
    test('$count directory entries migrate local aliases in one batch', () {
      final state = AsmrTagPreferences();
      for (var index = 0; index < count; index++) {
        final key = 'local:$index';
        state.tags[key] = AsmrTag(key: key, name: 'Alias $index');
        state.learned[key] = index + 1.0;
      }
      state.mergeTags([
        for (var index = 0; index < count; index++)
          AsmrTag(
            key: 'online:$index',
            name: 'Name $index',
            aliases: ['Alias $index'],
          ),
      ]);
      expect(state.tags, hasLength(count));
      expect(state.tags.keys.every((key) => key.startsWith('online:')), isTrue);
      expect(state.learned['online:${count - 1}'], count.toDouble());
    });
  }

  test(
    'recommendation weights use relative listening time and manual choices',
    () {
      final state = AsmrTagPreferences();
      state.recordListeningBatch('test:1', [
        (tags: ['Frequent'], duration: const Duration(minutes: 120)),
        (tags: ['Occasional'], duration: const Duration(minutes: 30)),
      ]);
      final manual = state.resolve('Manual');
      state.setInterested(manual, true);
      expect(state.recommendationWeights, {
        'frequent': 1,
        'occasional': 0.25,
        'manual': 1,
      });
      state.setInterested(state.resolve('Occasional'), true);
      expect(state.recommendationWeights['occasional'], 1);
      state.setInterested(state.resolve('Occasional'), false);
      expect(state.recommendationWeights['occasional'], 0.25);
      expect(state.interests.map((interest) => interest.weight), [120, 30]);
    },
  );

  test(
    'excluded interests and their aliases never supply positive weights',
    () {
      final state = AsmrTagPreferences();
      state.mergeTag(
        AsmrTag(key: 'online:1', name: 'Blocked', aliases: ['Excluded alias']),
      );
      state.learned['online:1'] = 200;
      state.setInterested('online:1', true);
      state.excluded.add('online:1');
      state.learned[state.resolve('Allowed')] = 50;
      state.learned[state.resolve('Secondary')] = 10;
      expect(state.recommendationWeights, {'allowed': 1, 'secondary': 0.2});
      state.excluded.clear();
      expect(state.recommendationWeights, {
        'blocked': 1,
        'excluded alias': 1,
        'allowed': 0.25,
        'secondary': 0.05,
      });
    },
  );

  test('recommendation aliases retain their strongest normalized weight', () {
    final state = AsmrTagPreferences();
    state.mergeTag(AsmrTag(key: 'a', name: 'A', aliases: [' Shared ']));
    state.mergeTag(AsmrTag(key: 'b', name: 'B', aliases: ['SHARED']));
    state.learned.addAll({'a': 100, 'b': 25});
    expect(state.recommendationWeights, {'a': 1, 'b': 0.25, 'shared': 1});
  });

  test('voice tastes share playback ranking and independent cursors', () {
    final voices = AsmrTagPreferences();
    final tags = AsmrTagPreferences();
    for (var i = 0; i < 15; i++) {
      voices.setInterested(voices.resolve('Voice $i'), true);
    }
    expect(voices.interests, isEmpty);
    expect(voices.manualInterests, hasLength(15));
    expect(voices.listenedInterests, isEmpty);
    const batch = (
      tags: ['Voice 14', 'Voice 13'],
      duration: Duration(minutes: 20),
    );
    expect(voices.recordListeningBatch('epoch:1', [batch]), isTrue);
    expect(voices.recordListeningBatch('epoch:1', [batch]), isFalse);
    expect(tags.recordListeningBatch('epoch:1', [batch]), isTrue);
    expect(voices.interests.take(2).map((e) => e.weight), [20, 20]);
    final restored = AsmrTagPreferences.fromJson(voices.toJson());
    expect(restored.limit, 20);
    expect(
      restored.interests.map((e) => e.tag.key),
      voices.interests.map((e) => e.tag.key),
    );
    restored.mergeTag(AsmrTag(key: 'online:uuid', name: 'Voice 14'));
    expect(restored.learned['online:uuid'], 20);
    expect(restored.manualInterests, contains('online:uuid'));
    expect(restored.learned, isNot(contains('local:voice 14')));
  });
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
    'manual choices never fill playback rankings or change listening minutes',
    () {
      final state = AsmrTagPreferences();
      final a = state.resolve('A');
      final b = state.resolve('B');
      state.setInterested(a, true);
      state.setInterested(b, true);
      expect(state.interests, isEmpty);
      expect(state.listenedInterests, isEmpty);
      state.recordListeningBatch('test:1', [
        (tags: ['B'], duration: const Duration(minutes: 1)),
      ]);
      expect(state.interests.map((e) => e.tag.key), [b]);
      state.setInterested(b, false);
      expect(state.interests.map((e) => e.tag.key), [b]);
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
    'listening credits full time to unique tags and round trips batch cursors',
    () {
      var state = AsmrTagPreferences();
      final batch = [
        (tags: ['a', 'A', 'b'], duration: const Duration(minutes: 20)),
        (tags: ['b'], duration: const Duration(minutes: 5)),
      ];
      expect(state.recordListeningBatch('windows:epoch:1', batch), isTrue);
      state = AsmrTagPreferences.fromJson(state.toJson());
      expect(state.recordListeningBatch('windows:epoch:1', batch), isFalse);
      expect(state.learned[state.resolve('a')], 20);
      expect(state.learned[state.resolve('b')], 25);
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
