import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/localization/app_language_provider.dart';
import 'package:nameless_audio/app/state/app_runtime_providers.dart';
import 'package:nameless_audio/core/ui/ui_operation_service.dart';
import 'package:nameless_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:nameless_audio/core/media/music_track.dart';
import 'package:nameless_audio/features/data_support/application/storage_usage_service.dart';
import 'package:nameless_audio/features/data_support/presentation/data_support_page.dart';
import 'package:nameless_audio/features/data_support/presentation/storage_usage_card.dart';
import 'package:nameless_audio/features/settings/application/app_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cardKeys = <ValueKey<String>>[
    ValueKey('data-support-export-diagnostics'),
    ValueKey('data-support-privacy-summary'),
  ];
  late UiOperationService operationService;
  const storageChannel = MethodChannel('test/data_support_storage');
  const storageEvents = EventChannel('test/data_support_storage/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  StorageUsageService storageService({
    bool Function()? isAndroid,
    List<MusicTrack> Function()? libraryTracks,
  }) {
    return StorageUsageService(
      fileCacheGateway: FileCachePlatformGateway(
        channel: storageChannel,
        scanEvents: storageEvents,
        isAndroid: isAndroid ?? () => true,
      ),
      libraryTracks: libraryTracks ?? () => const <MusicTrack>[],
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    operationService = UiOperationService();
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      return <String, Object?>{
        'ok': true,
        'value': <String, Object?>{
          'totalBytes': 1024 * 1024 * 1024,
          'availableBytes': 512 * 1024 * 1024,
          'cacheBytes': 128 * 1024 * 1024,
        },
      };
    });
  });

  tearDown(() async {
    await operationService.dispose();
    messenger.setMockMethodCallHandler(storageChannel, null);
    messenger.setMockStreamHandler(storageEvents, null);
  });

  testWidgets(
    'busy progress keeps every data-support card and Ink response in place',
    (tester) async {
      final languageProvider = AppLanguageProvider();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(
              languageProvider,
            ),
            appUpdateServiceProvider.overrideWithValue(AppUpdateService()),
            uiOperationServiceProvider.overrideWithValue(operationService),
            dataSupportStorageUsageServiceProvider.overrideWithValue(
              storageService(),
            ),
          ],
          child: const MaterialApp(home: DataSupportPage()),
        ),
      );
      await tester.pump();
      await tester.pump();

      final appBar = tester.widget<AppBar>(find.byType(AppBar));
      expect(appBar.backgroundColor, Colors.transparent);
      expect(appBar.forceMaterialTransparency, isTrue);
      expect(
        find.byKey(const ValueKey<String>('app_page_header_blur')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('data-support-storage-card')),
        findsNothing,
      );

      expect(
        find.byKey(const ValueKey('data-support-export-backup')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('data-support-restore-backup')),
        findsNothing,
      );

      final firstCard = find.byKey(cardKeys.first);
      final firstCardContext = tester.element(firstCard);
      final firstCardIcon = tester.widget<Icon>(
        find.descendant(of: firstCard, matching: find.byType(Icon)).first,
      );
      expect(
        firstCardIcon.color,
        Theme.of(firstCardContext).colorScheme.onSurface,
      );

      final cardElements = <Key, Element>{};
      final inkElements = <Key, Element>{};
      final cardOffsets = <Key, Offset>{};
      for (final key in cardKeys) {
        final card = find.byKey(key);
        cardElements[key] = tester.element(card);
        inkElements[key] = tester.element(
          find.descendant(of: card, matching: find.byType(InkWell)),
        );
        cardOffsets[key] = tester.getTopLeft(card);
      }

      const operations = <(UiOperationScope, ValueKey<String>, String)>[
        (
          UiOperationScope.dataSupportDiagnosticsExport,
          ValueKey('data-support-export-diagnostics'),
          'export_diagnostics',
        ),
      ];
      for (final (scope, busyCardKey, labelKey) in operations) {
        final pending = Completer<void>();
        final operation = operationService.run<void>(
          scope: scope,
          labelKey: labelKey,
          task: (_) => pending.future,
          cancelPrevious: false,
        );
        expect(operationService.operationFor(scope).isBusy, isTrue);
        await tester.pump();
        await tester.pump();

        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        for (final key in cardKeys) {
          final card = find.byKey(key);
          expect(tester.element(card), same(cardElements[key]));
          expect(
            tester.element(
              find.descendant(of: card, matching: find.byType(InkWell)),
            ),
            same(inkElements[key]),
          );
          expect(tester.getTopLeft(card), cardOffsets[key]);
          expect(
            find.descendant(
              of: card,
              matching: find.byType(CircularProgressIndicator),
            ),
            key == busyCardKey ? findsOneWidget : findsNothing,
          );
        }

        pending.complete();
        await operation;
        await tester.pump();
        await tester.pump();
      }
    },
  );

  testWidgets('storage overview keeps a compact loading state', (tester) async {
    final pending = Completer<Object?>();
    messenger.setMockMethodCallHandler(storageChannel, (_) => pending.future);
    final languageProvider = AppLanguageProvider();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
          appUpdateServiceProvider.overrideWithValue(AppUpdateService()),
          uiOperationServiceProvider.overrideWithValue(operationService),
          dataSupportStorageUsageServiceProvider.overrideWithValue(
            storageService(),
          ),
        ],
        child: const MaterialApp(home: StorageUsageCard()),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('data-support-storage-loading')),
      findsOneWidget,
    );
    pending.complete(<String, Object?>{
      'ok': false,
      'errorCode': 'storage_usage_failed',
      'error': 'failed',
    });
    await tester.pumpAndSettle();
  });

  testWidgets('storage overview exposes an unavailable retry state', (
    tester,
  ) async {
    final languageProvider = AppLanguageProvider();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
          appUpdateServiceProvider.overrideWithValue(AppUpdateService()),
          uiOperationServiceProvider.overrideWithValue(operationService),
          dataSupportStorageUsageServiceProvider.overrideWithValue(
            storageService(isAndroid: () => false),
          ),
        ],
        child: const MaterialApp(home: StorageUsageCard()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('data-support-storage-unavailable')),
      findsOneWidget,
    );
    expect(
      find.byTooltip(languageProvider.tr('storage_usage_retry')),
      findsOneWidget,
    );
  });

  testWidgets('storage overview uses opaque colors and requested bar order', (
    tester,
  ) async {
    final languageProvider = AppLanguageProvider();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
          dataSupportStorageUsageServiceProvider.overrideWithValue(
            storageService(
              libraryTracks: () => [
                MusicTrack(
                  path: '/music/track.mp3',
                  displayName: 'Track',
                  groupKey: 'group',
                  groupTitle: 'Group',
                  groupSubtitle: '',
                  isSingle: true,
                  fileSizeBytes: 128 * 1024 * 1024,
                ),
              ],
            ),
          ),
        ],
        child: const MaterialApp(home: StorageUsageCard()),
      ),
    );
    await tester.pumpAndSettle();

    final segments = find.byKey(
      const ValueKey('data-support-storage-segment-app-cache'),
    );
    expect(segments, findsOneWidget);
    final segment = tester.widget<ColoredBox>(
      find.descendant(of: segments, matching: find.byType(ColoredBox)),
    );
    expect(segment.color.a, 1);
    expect(
      tester
          .getSize(
            find.descendant(of: segments, matching: find.byType(ColoredBox)),
          )
          .height,
      12,
    );
    final otherSegment = find.byKey(
      const ValueKey('data-support-storage-segment-other'),
    );
    final audioLibrarySegment = find.byKey(
      const ValueKey('data-support-storage-segment-audio-library'),
    );
    expect(otherSegment, findsOneWidget);
    expect(audioLibrarySegment, findsOneWidget);
    expect(
      tester.getCenter(otherSegment).dx,
      lessThan(tester.getCenter(audioLibrarySegment).dx),
    );
    expect(
      tester
          .getTopLeft(
            find.text(languageProvider.tr('storage_usage_audio_library')),
          )
          .dy,
      lessThan(
        tester
            .getTopLeft(find.text(languageProvider.tr('storage_usage_other')))
            .dy,
      ),
    );
  });
}
