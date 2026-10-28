import 'dart:async';

import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_favorite_action.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/asmr_controller_test_fixture.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'favorite failures are reported and a retry can succeed on $platform',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        final controller = _FavoritesController(createTestAsmrServices());
        addTearDown(fixture.dispose);
        addTearDown(controller.dispose);
        final work = AsmrWork.fromJson(const {
          'id': 1,
          'title': 'Favorite work',
        });
        await tester.pumpWidget(
          fixture.build(
            Consumer(
              builder: (context, ref, _) => Scaffold(
                body: TextButton(
                  onPressed: () => unawaited(
                    setAsmrWorksFavoriteWithFeedback(context, ref, [work]),
                  ),
                  child: const Text('Favorite'),
                ),
              ),
            ),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await tester.tap(find.text('Favorite'));
        await tester.tap(find.text('Favorite'));
        await tester.pump();
        expect(controller.calls, 1);
        controller.save.completeError(StateError('disk full'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(controller.favorite, isTrue);
        expect(
          find.textContaining(
            fixture.languageProvider.tr('operation_failed_retry'),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        controller.save = Completer<void>();
        await tester.tap(find.text('Favorite'));
        await tester.pump();
        expect(controller.calls, 2);
        controller.save.complete();
        await tester.pumpAndSettle();
        expect(controller.favorite, isFalse);
        expect(
          find.textContaining(
            fixture.languageProvider.tr('asmr_favorite_removed'),
          ),
          findsOneWidget,
        );
        controller.save = Completer<void>();
        await tester.tap(
          find.textContaining(fixture.languageProvider.tr('undo')).first,
        );
        await tester.pump();
        expect(controller.calls, 3);
        controller.save.complete();
        await tester.pumpAndSettle();
        expect(controller.favorite, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'batch reservation prevents overlapping single work changes on $platform',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        final controller = _FavoritesController(createTestAsmrServices());
        addTearDown(fixture.dispose);
        addTearDown(controller.dispose);
        final works = [
          AsmrWork.fromJson(const {'id': 1, 'title': 'First'}),
          AsmrWork.fromJson(const {'id': 2, 'title': 'Second'}),
        ];
        await tester.pumpWidget(
          fixture.build(
            Consumer(
              builder: (context, ref, _) => Scaffold(
                body: Column(
                  children: [
                    TextButton(
                      onPressed: () => unawaited(
                        setAsmrWorksFavoriteWithFeedback(context, ref, works),
                      ),
                      child: const Text('Batch'),
                    ),
                    TextButton(
                      onPressed: () => unawaited(
                        setAsmrWorksFavoriteWithFeedback(context, ref, [
                          works.last,
                        ]),
                      ),
                      child: const Text('Single'),
                    ),
                  ],
                ),
              ),
            ),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await tester.tap(find.text('Batch'));
        await tester.tap(find.text('Single'));
        await tester.pump();
        expect(controller.calls, 1);
        controller.save.complete();
        await tester.pumpAndSettle();
        expect(controller.favorite, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );
  }
}

class _FavoritesController extends AsmrLibraryController {
  _FavoritesController(TestAsmrServices services)
    : super(
        preferencesStore: services.preferencesStore,
        remoteCatalogService: services.remoteCatalogService,
        accountSyncService: services.accountSyncService,
      );

  int calls = 0;
  bool favorite = true;
  Completer<void> save = Completer<void>();

  @override
  bool isFavorite(String workKey) => favorite;

  @override
  Future<void> setFavorites(
    List<AsmrWork> works, {
    required bool favorite,
  }) async {
    calls++;
    await save.future;
    this.favorite = favorite;
  }
}
