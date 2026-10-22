import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/player/application/playback_usage_ledger.dart';

void main() {
  var tick = Duration.zero;
  var wall = DateTime(2026, 10, 22, 23, 59, 58);
  late PlaybackUsageLedger ledger;
  final item = <String, Object?>{
    'uri': 'file:///RJ123456/a.mp3',
    'title': 'RJ123456',
  };

  void advance(int milliseconds) {
    tick += Duration(milliseconds: milliseconds);
    wall = wall.add(Duration(milliseconds: milliseconds));
  }

  setUp(() {
    tick = Duration.zero;
    wall = DateTime(2026, 10, 22, 23, 59, 58);
    ledger = PlaybackUsageLedger(elapsed: () => tick, now: () => wall);
  });

  test('overlapping sessions count union and deduplicate the same work', () {
    ledger.update('a', item);
    advance(1000);
    ledger.update('b', item);
    advance(1000);
    ledger.update('a', null);
    advance(1000);
    ledger.update('b', null);
    advance(10000);
    final days = ledger.read().single.days;
    expect(days.map((e) => e.totalMs), [2000, 1000]);
    expect(days.expand((e) => e.works).map((e) => e.milliseconds), [
      2000,
      1000,
    ]);
    expect(days.first.works.single.key, 'rj:RJ123456');
  });

  test(
    'different works receive time independently while total remains a union',
    () {
      ledger.update('a', item);
      ledger.update('b', {
        'uri': 'https://example.com/RJ999999/b.mp3',
        'title': 'RJ999999',
      });
      advance(1500);
      final day = ledger.read().single.days.single;
      expect(day.totalMs, 1500);
      expect(day.works.map((e) => e.milliseconds), [1500, 1500]);
    },
  );

  test('read retries retain stable batches and exact acknowledgements', () {
    ledger.update('a', item);
    advance(1000);
    ledger.update('a', null);
    final first = ledger.read().single;
    expect(ledger.read().single.id, first.id);
    ledger.acknowledge(['unknown']);
    expect(ledger.read().single.id, first.id);
    ledger.acknowledge([first.id]);
    expect(ledger.read(), isEmpty);
  });

  test(
    'reset discards previous contributions and establishes a fresh boundary',
    () {
      ledger.update('a', item);
      advance(1000);
      ledger.reset();
      advance(500);
      expect(ledger.read().single.days.single.totalMs, 500);
    },
  );

  test(
    'disk state restores pending batches and continues stable epoch sequence',
    () {
      ledger.update('a', item);
      advance(1000);
      ledger.update('a', null);
      final original = ledger.read().single;
      final state = ledger.exportState();
      final restored = PlaybackUsageLedger(elapsed: () => tick, now: () => wall)
        ..restoreState(state);
      expect(restored.read().single.id, original.id);
      restored.acknowledge([original.id]);
      restored.update('a', item);
      advance(1000);
      final next = restored.read().single;
      expect(
        next.id.substring(0, next.id.lastIndexOf(':')),
        original.id.substring(0, original.id.lastIndexOf(':')),
      );
      expect(
        int.parse(next.id.split(':').last),
        greaterThan(int.parse(original.id.split(':').last)),
      );
    },
  );

  test('wall clock adjustments never amplify monotonic duration', () {
    ledger.update('a', item);
    tick += const Duration(seconds: 1);
    wall = wall.add(const Duration(days: 30));
    ledger.update('a', null);
    final day = ledger.read().single.days.single;
    expect(day.totalMs, 1000);
    expect(day.date, '2026-10-22');
  });
}
