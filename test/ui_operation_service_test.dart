import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/ui/ui_operation_service.dart';

void main() {
  group('UiOperationService', () {
    late UiOperationService service;

    setUp(() {
      service = UiOperationService();
    });

    tearDown(() async {
      await service.dispose();
    });

    test('publishes running, progress, and success states', () async {
      const scope = UiOperationScope('test:progress');
      final states = <UiOperationState>[];
      final subscription = service.changes
          .where((changedScope) => changedScope == scope)
          .listen((_) => states.add(service.operationFor(scope)));

      final result = await service.run<int>(
        scope: scope,
        labelKey: 'loading_dot',
        task: (progress) async {
          progress.report(0.4);
          return 7;
        },
      );

      await subscription.cancel();

      expect(result, 7);
      expect(
        states.map((state) => state.phase),
        contains(UiOperationPhase.running),
      );
      expect(states.map((state) => state.progress), contains(0.4));
      expect(service.operationFor(scope).phase, UiOperationPhase.succeeded);
      expect(service.operationFor(scope).progress, 1);
      expect(service.isBusy(scope), isFalse);
      expect(service.progressFor(scope), 1);
    });

    test('stable public scopes use distinct operation keys', () {
      expect(
        UiOperationScope.audioDetail('folder|a'),
        isNot(UiOperationScope.audioDetail('folder|b')),
      );
      expect(
        UiOperationScope.metadataReview('folder|a'),
        isNot(UiOperationScope.metadataBatch),
      );
      expect(
        UiOperationScope.pageOpen('settings'),
        isNot(UiOperationScope.videoConverterPick),
      );
    });

    test('keeps the latest operation result for the same scope', () async {
      const scope = UiOperationScope('test:latest');
      final firstCompleter = Completer<String>();
      final secondCompleter = Completer<String>();

      final first = service.run<String>(
        scope: scope,
        labelKey: 'first',
        task: (_) => firstCompleter.future,
      );
      final firstOperationId = service.operationFor(scope).operationId;

      final second = service.run<String>(
        scope: scope,
        labelKey: 'second',
        task: (_) => secondCompleter.future,
      );
      final secondOperationId = service.operationFor(scope).operationId;

      expect(firstOperationId, isNot(secondOperationId));
      expect(service.operationFor(scope).labelKey, 'second');

      firstCompleter.complete('old');
      await first;

      expect(service.operationFor(scope).operationId, secondOperationId);
      expect(service.operationFor(scope).phase, UiOperationPhase.running);

      secondCompleter.complete('new');
      await second;

      expect(service.operationFor(scope).operationId, secondOperationId);
      expect(service.operationFor(scope).phase, UiOperationPhase.succeeded);
      expect(service.operationFor(scope).labelKey, 'second');
    });

    test('records failure only for the current operation', () async {
      const scope = UiOperationScope('test:failure');
      final firstCompleter = Completer<void>();
      final secondCompleter = Completer<void>();

      final first = service.run<void>(
        scope: scope,
        labelKey: 'first',
        task: (_) => firstCompleter.future,
      );
      final second = service.run<void>(
        scope: scope,
        labelKey: 'second',
        task: (_) => secondCompleter.future,
      );

      firstCompleter.completeError(
        StateError('old failure'),
        StackTrace.current,
      );
      await expectLater(first, throwsStateError);

      expect(service.operationFor(scope).labelKey, 'second');
      expect(service.operationFor(scope).phase, UiOperationPhase.running);
      expect(service.operationFor(scope).error, isNull);

      secondCompleter.completeError(
        StateError('new failure'),
        StackTrace.current,
      );
      await expectLater(second, throwsStateError);

      expect(service.operationFor(scope).labelKey, 'second');
      expect(service.operationFor(scope).phase, UiOperationPhase.failed);
      expect(service.operationFor(scope).error, isA<StateError>());
    });

    test('publishes only the scope that changed', () async {
      const firstScope = UiOperationScope('test:first-scope');
      const secondScope = UiOperationScope('test:second-scope');
      final changes = <UiOperationScope>[];
      final subscription = service.changes.listen(changes.add);

      await service.run<void>(
        scope: firstScope,
        labelKey: 'first',
        task: (_) async {},
      );

      expect(changes, everyElement(firstScope));
      expect(changes, hasLength(2));
      expect(changes, isNot(contains(secondScope)));
      await subscription.cancel();
    });

    test('retains only the newest completed operations', () async {
      await service.dispose();
      service = UiOperationService(maxRetainedCompletedOperations: 2);
      const scopes = <UiOperationScope>[
        UiOperationScope('test:completed-1'),
        UiOperationScope('test:completed-2'),
        UiOperationScope('test:completed-3'),
      ];

      for (final scope in scopes) {
        await service.run<void>(
          scope: scope,
          labelKey: scope.value,
          task: (_) async {},
        );
      }

      expect(service.operationFor(scopes[0]).phase, UiOperationPhase.idle);
      expect(service.operationFor(scopes[1]).phase, UiOperationPhase.succeeded);
      expect(service.operationFor(scopes[2]).phase, UiOperationPhase.succeeded);
    });

    test('never evicts running operations', () async {
      await service.dispose();
      service = UiOperationService(maxRetainedCompletedOperations: 1);
      const runningScope = UiOperationScope('test:running');
      final runningCompleter = Completer<void>();
      final running = service.run<void>(
        scope: runningScope,
        labelKey: 'running',
        task: (_) => runningCompleter.future,
      );

      for (var index = 0; index < 3; index++) {
        await service.run<void>(
          scope: UiOperationScope('test:completed-$index'),
          labelKey: 'completed',
          task: (_) async {},
        );
      }

      expect(
        service.operationFor(runningScope).phase,
        UiOperationPhase.running,
      );
      runningCompleter.complete();
      await running;
    });
  });
}
