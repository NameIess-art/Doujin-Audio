import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/theme/theme_provider.dart';
import 'package:doujin_audio/core/ui/ui_operation_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:doujin_audio/features/settings/application/app_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _DisposalObserver extends ProviderObserver {
  final Set<Object> disposedProviders = <Object>{};

  @override
  void didDisposeProvider(ProviderObserverContext context) {
    disposedProviders.add(context.provider);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test(
    'language, theme, and download streams emit current and later values',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      await AppPreferences.init();
      final language = _TrackingLanguageProvider();
      final theme = _TrackingThemeProvider();
      final downloads = _TrackingDownloadManager();
      final container = ProviderContainer(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(language),
          themeProviderInstanceProvider.overrideWith((ref) => theme),
          asmrDownloadManagerProvider.overrideWithValue(downloads),
        ],
      );
      final languageValues = <AppLanguageState>[];
      final themeValues = <ThemeProvider>[];
      final downloadValues = <List<int>>[];
      final subscriptions = [
        container.listen(appLanguageStateProvider, (_, next) {
          if (next case AsyncData(:final value)) languageValues.add(value);
        }),
        container.listen(themeProviderInstanceProvider, (_, next) {
          themeValues.add(next);
        }, fireImmediately: true),
        container.listen(asmrDownloadTaskIdsProvider, (_, next) {
          if (next case AsyncData(:final value)) downloadValues.add(value);
        }),
      ];

      await container.pump();
      expect(languageValues.single.language, language.language);
      expect(themeValues.single.themeMode, ThemeMode.system);
      expect(downloadValues.single, isEmpty);

      await language.setLanguage(AppLanguage.en);
      await theme.setDifferentiateAsmrTheme(false);
      downloads.emit(const <int>[42]);
      await container.pump();
      expect(languageValues.last.language, AppLanguage.en);
      expect(themeValues.last.differentiateAsmrTheme, isFalse);
      expect(downloadValues.last, const <int>[42]);

      for (final subscription in subscriptions) {
        subscription.close();
      }
      container.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(language.removeListenerCalls, 1);
      expect(theme.removeListenerCalls, 1);
      expect(downloads.cancelCalls, 1);
      language.dispose();
      downloads.dispose();
    },
  );
}

mixin _TracksListeners on ChangeNotifier {
  int removeListenerCalls = 0;

  @override
  void removeListener(VoidCallback listener) {
    removeListenerCalls++;
    super.removeListener(listener);
  }
}

final class _TrackingLanguageProvider extends AppLanguageProvider
    with _TracksListeners {}

final class _TrackingThemeProvider extends ThemeProvider
    with _TracksListeners {}

final class _TrackingDownloadManager extends AsmrDownloadManager {
  _TrackingDownloadManager() : super(persistTasks: false) {
    _taskIdsController = StreamController<List<int>>.broadcast(
      sync: true,
      onCancel: () => cancelCalls++,
    );
  }

  late final StreamController<List<int>> _taskIdsController;
  int cancelCalls = 0;

  @override
  Stream<List<int>> get taskIdsStream async* {
    yield const <int>[];
    yield* _taskIdsController.stream;
  }

  void emit(List<int> taskIds) => _taskIdsController.add(taskIds);

  @override
  void dispose() {
    unawaited(_taskIdsController.close());
    super.dispose();
  }
}
