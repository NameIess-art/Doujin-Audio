import 'dart:async';

import 'package:doujin_audio/core/ui/undoable_removal_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stage hides immediately and rejects a duplicate key', () async {
    final service = UndoableRemovalService();
    addTearDown(service.dispose);
    const key = UndoableRemovalKey('test', 'one');
    final releasePrepare = Completer<void>();
    final first = service.stage(
      UndoableRemovalAction(
        key: key,
        prepare: () async {
          await releasePrepare.future;
          return true;
        },
        commit: () {},
        undo: () {},
      ),
    );

    expect(service.state.isHidden(key), isTrue);
    expect(
      await service.stage(
        UndoableRemovalAction(key: key, commit: () {}, undo: () {}),
      ),
      isFalse,
    );
    releasePrepare.complete();
    expect(await first, isTrue);
    expect(service.state.pendingCount, 1);
  });

  test('undo restores a merged batch in reverse order', () async {
    final service = UndoableRemovalService();
    addTearDown(service.dispose);
    final calls = <String>[];
    for (final id in <String>['one', 'two']) {
      await service.stage(
        UndoableRemovalAction(
          key: UndoableRemovalKey('test', id),
          commit: () => calls.add('commit:$id'),
          undo: () => calls.add('undo:$id'),
        ),
      );
    }

    expect(service.state.pendingCount, 2);
    expect(await service.undoPending(), 0);
    expect(calls, <String>['undo:two', 'undo:one']);
    expect(service.state.hiddenKeys, isEmpty);
  });

  test('commit keeps keys hidden and restores only failed actions', () async {
    final service = UndoableRemovalService();
    addTearDown(service.dispose);
    final releaseFirst = Completer<void>();
    var failedUndoCount = 0;
    const firstKey = UndoableRemovalKey('test', 'one');
    const failedKey = UndoableRemovalKey('test', 'two');
    await service.stage(
      UndoableRemovalAction(
        key: firstKey,
        commit: () => releaseFirst.future,
        undo: () {},
      ),
    );
    await service.stage(
      UndoableRemovalAction(
        key: failedKey,
        commit: () => throw StateError('failed'),
        undo: () => failedUndoCount++,
      ),
    );

    final commit = service.commitPending();
    await Future<void>.delayed(Duration.zero);
    expect(service.state.isHidden(firstKey), isTrue);
    expect(service.state.isHidden(failedKey), isTrue);
    releaseFirst.complete();

    expect(await commit, 1);
    expect(failedUndoCount, 1);
    expect(service.state.hiddenKeys, isEmpty);
  });
}
