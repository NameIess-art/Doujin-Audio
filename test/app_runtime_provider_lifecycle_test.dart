import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/state/app_runtime_providers.dart';
import 'package:nameless_audio/core/ui/ui_operation_service.dart';

final class _DisposalObserver extends ProviderObserver {
  final Set<Object> disposedProviders = <Object>{};

  @override
  void didDisposeProvider(ProviderObserverContext context) {
    disposedProviders.add(context.provider);
  }
}

void main() {
  test(
    'parameterized runtime providers dispose after their listeners close',
    () async {
      final observer = _DisposalObserver();
      final operations = UiOperationService();
      final container = ProviderContainer(
        observers: <ProviderObserver>[observer],
        overrides: [uiOperationServiceProvider.overrideWithValue(operations)],
      );
      addTearDown(container.dispose);
      addTearDown(operations.dispose);
      const scope = UiOperationScope('test:lifecycle');
      final operationProvider = uiOperationForScopeProvider(scope);
      final downloadProvider = asmrDownloadTaskProvider(42);

      final operationSubscription = container.listen(
        operationProvider,
        (_, _) {},
        fireImmediately: true,
      );
      final downloadSubscription = container.listen(
        downloadProvider,
        (_, _) {},
        fireImmediately: true,
      );

      operationSubscription.close();
      downloadSubscription.close();
      await container.pump();
      await container.pump();

      expect(observer.disposedProviders, contains(operationProvider));
      expect(observer.disposedProviders, contains(downloadProvider));
    },
  );

  test('scope provider ignores changes from unrelated operations', () async {
    final operations = UiOperationService();
    final container = ProviderContainer(
      overrides: [uiOperationServiceProvider.overrideWithValue(operations)],
    );
    addTearDown(container.dispose);
    addTearDown(operations.dispose);
    const watchedScope = UiOperationScope('test:watched');
    const unrelatedScope = UiOperationScope('test:unrelated');
    var notifications = 0;
    final subscription = container.listen(
      uiOperationForScopeProvider(watchedScope),
      (_, _) => notifications += 1,
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    await operations.run<void>(
      scope: unrelatedScope,
      labelKey: 'unrelated',
      task: (_) async {},
    );
    await container.pump();

    expect(notifications, 1);
  });
}
