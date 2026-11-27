import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/app/theme/theme_provider.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/dlsite_metadata.dart';
import 'package:doujin_audio/core/widgets/file_tree_row.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/dlsite_metadata_batch_session.dart';
import 'package:doujin_audio/features/library/application/dlsite_metadata_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/domain/audio_library_category.dart';
import 'package:doujin_audio/features/library/presentation/dlsite_metadata_batch_page.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AudioLibraryCategoryEntry resultEntry(
    String id, {
    bool hasRjCode = true,
    String? title,
  }) {
    final target = AudioDetailTarget.libraryRootFolder('/library/$id');
    return AudioLibraryCategoryEntry(
      target: target,
      title: title ?? 'Work $id',
      path: target.targetPath,
      isFolder: true,
      detail: AudioDetail.empty(
        target,
      ).copyWith(rjCode: hasRjCode ? 'RJ000$id' : ''),
      tracks: const [],
    );
  }

  DlsiteMetadata resultMetadata(String id) => DlsiteMetadata(
    rjCode: 'RJ000$id',
    workTitle: 'Fetched $id',
    circleName: 'Circle',
    voiceActors: const [],
    tags: const [],
  );

  testWidgets(
    'batch review restores each confirmed cover choice',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: CoverArtworkCacheService(
          libraryService: LibraryService(),
          remoteCoverDownloader: (_) async => null,
        ),
      );
      addTearDown(fixture.dispose);
      final session = DlsiteMetadataBatchSession(
        entries: [resultEntry('001'), resultEntry('002')],
        lookup: (query) async => [
          resultMetadata(
            query.rjCode!.substring(5),
          ).copyWith(coverUrl: 'https://example.com/${query.rjCode}.jpg'),
        ],
      );
      await tester.pumpWidget(
        fixture.build(DlsiteMetadataBatchResultsPage(session: session)),
      );
      await tester.pumpAndSettle();

      final firstResult = find.byKey(
        const ValueKey<String>('batch_metadata_result_0'),
      );
      final saveCover = find.byType(SwitchListTile);
      final confirm = find.byKey(
        const ValueKey<String>('dlsite_review_confirm'),
      );

      await tester.tap(firstResult);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(saveCover).value, isTrue);
      await tester.tap(saveCover);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(session.items[0].saveCover, isFalse);

      expect(tester.widget<SwitchListTile>(saveCover).value, isFalse);
      await tester.tap(saveCover);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(session.items[1].saveCover, isTrue);

      await tester.tap(firstResult);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(saveCover).value, isFalse);

      await tester.tap(
        find.byKey(const ValueKey<String>('dlsite_review_next_work')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(saveCover).value, isTrue);

      await tester.tap(
        find.byKey(const ValueKey<String>('dlsite_review_previous_work')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(saveCover).value, isFalse);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('batch results render and update all lookup status icons', (
    tester,
  ) async {
    final pending = Completer<List<DlsiteMetadata>>();
    final session = DlsiteMetadataBatchSession(
      entries: [
        resultEntry('001'),
        resultEntry('002'),
        resultEntry('003'),
        resultEntry('004'),
      ],
      lookup: (query) => switch (query.rjCode) {
        'RJ000001' => Future<List<DlsiteMetadata>>.value([
          resultMetadata('001'),
        ]),
        'RJ000002' => Future<List<DlsiteMetadata>>.error(
          const DlsiteMetadataException(
            'not found',
            kind: DlsiteMetadataFailureKind.notFound,
          ),
        ),
        'RJ000003' => Future<List<DlsiteMetadata>>.error(StateError('offline')),
        _ => pending.future,
      },
    );
    final languageProvider = AppLanguageProvider();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
        ],
        child: MaterialApp(
          home: DlsiteMetadataBatchResultsPage(session: session),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('batch_metadata_results_header')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(HeaderTopCapsule),
        matching: find.byIcon(Icons.cloud_download_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('batch_metadata_results_done')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('batch_metadata_status_0')),
      findsOneWidget,
    );
    final pendingStatus = find.descendant(
      of: find.byKey(const ValueKey<String>('batch_metadata_status_0')),
      matching: find.byIcon(Icons.pending_rounded),
    );
    expect(pendingStatus, findsOneWidget);
    expect(
      tester.widget<Icon>(pendingStatus).color,
      AppDesignTokens.of(tester.element(pendingStatus)).warning,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('batch_metadata_status_1')),
        matching: find.byIcon(Icons.search_off_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('batch_metadata_status_2')),
        matching: find.byIcon(Icons.error_outline_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('batch_metadata_status_3')),
        matching: find.byIcon(Icons.autorenew_rounded),
      ),
      findsOneWidget,
    );

    pending.complete([resultMetadata('004')]);
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('batch_metadata_status_3')),
        matching: find.byIcon(Icons.pending_rounded),
      ),
      findsOneWidget,
    );
    session.confirm(3, metadata: resultMetadata('004'), saveCover: false);
    await tester.pump();
    final confirmedStatus = find.descendant(
      of: find.byKey(const ValueKey<String>('batch_metadata_status_3')),
      matching: find.byIcon(Icons.check_circle_rounded),
    );
    expect(confirmedStatus, findsOneWidget);
    expect(
      tester.widget<Icon>(confirmedStatus).color,
      AppDesignTokens.of(tester.element(confirmedStatus)).success,
    );
  });

  testWidgets('work picker uses floating header and completion controls', (
    tester,
  ) async {
    final languageProvider = AppLanguageProvider();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
        ],
        child: const MaterialApp(
          home: DlsiteMetadataWorkPickerPage(
            entries: <AudioLibraryCategoryEntry>[],
            initialSelection: <AudioLibraryCategoryEntry>[],
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('batch_metadata_picker_header')),
      findsOneWidget,
    );
    final title = find.widgetWithText(
      HeaderTopCapsule,
      languageProvider.tr('batch_metadata_specific'),
    );
    final search = find.byKey(
      const ValueKey<String>('batch_metadata_picker_search'),
    );
    final selectAll = find.byKey(
      const ValueKey<String>('batch_metadata_picker_select_all'),
    );
    expect(title, findsOneWidget);
    expect(
      tester.getTopLeft(search).dy,
      greaterThan(tester.getBottomLeft(title).dy),
    );
    expect(tester.getCenter(search).dy, tester.getCenter(selectAll).dy);
    expect(
      tester.getTopLeft(selectAll).dx,
      greaterThan(tester.getTopRight(search).dx),
    );
    expect(tester.getSize(selectAll), const Size(38, 38));
    expect(tester.widget<IconButton>(selectAll).onPressed, isNull);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    final searchField = tester.widget<TextField>(
      find.descendant(of: search, matching: find.byType(TextField)),
    );
    expect(searchField.textInputAction, TextInputAction.search);
    expect(
      searchField.decoration?.contentPadding,
      const EdgeInsets.only(right: 10),
    );
    expect(
      searchField.decoration?.prefixIconConstraints,
      const BoxConstraints.tightFor(width: 38, height: 38),
    );
    expect(
      tester.widget<ListView>(find.byType(ListView)).padding,
      const EdgeInsets.fromLTRB(16, 96, 16, 78),
    );
    expect(
      find.byKey(const ValueKey<String>('batch_metadata_picker_done')),
      findsOneWidget,
    );
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'batch results and picker share three-line rows at scale $scale',
      (tester) async {
        final platform = defaultTargetPlatform;
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final languageProvider = AppLanguageProvider();
        final entries = [
          resultEntry('001', title: '很长的作品名称用来验证窄窗口显示两行并省略后续文字'),
          resultEntry('002', hasRjCode: false, title: '短'),
        ];
        final session = DlsiteMetadataBatchSession(
          entries: entries,
          lookup: (_) =>
              Future<List<DlsiteMetadata>>.value([resultMetadata('001')]),
        );
        Widget app(Widget page) => ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(
              languageProvider,
            ),
          ],
          child: MaterialApp(
            theme: ThemeData(platform: platform),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: page,
          ),
        );
        await tester.pumpWidget(
          app(DlsiteMetadataBatchResultsPage(session: session)),
        );
        await tester.pumpAndSettle();
        final resultRects = [
          for (var i = 0; i < entries.length; i++)
            tester.getRect(
              find.byKey(ValueKey<String>('batch_metadata_result_$i')),
            ),
        ];
        final capsule = find.byType(HeaderTopCapsule);
        final compactProgress = find.descendant(
          of: capsule,
          matching: find.text('${session.completedLookupCount}/2·0'),
        );
        expect(compactProgress, findsOneWidget);
        expect(
          tester.getTopRight(compactProgress).dx,
          closeTo(tester.getTopRight(capsule).dx - 14, 0.5),
        );
        expect(resultRects[0].height, greaterThan(48));
        expect(resultRects[1].height, resultRects[0].height);
        expect(resultRects[1].top, resultRects[0].bottom);
        final longTitle = find.text(entries[0].title);
        final shortTitle = find.text(entries[1].title);
        for (final title in [longTitle, shortTitle]) {
          expect(tester.widget<Text>(title).maxLines, 2);
        }
        expect(
          tester.getSize(longTitle).height,
          greaterThan(tester.getSize(shortTitle).height),
        );
        expect(tester.widget<Text>(find.text('RJ000001')).maxLines, 1);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(
          app(
            DlsiteMetadataWorkPickerPage(
              entries: entries,
              initialSelection: const [],
            ),
          ),
        );
        await tester.pumpAndSettle();
        final pickerRows = find.byType(FileTreeRow);
        final pickerRects = [
          for (var i = 0; i < entries.length; i++)
            tester.getRect(pickerRows.at(i)),
        ];
        expect(pickerRects[0].height, resultRects[0].height);
        expect(pickerRects[1].height, pickerRects[0].height);
        expect(pickerRects[1].top, pickerRects[0].bottom);
        expect(pickerRects[0].left, resultRects[0].left);
        expect(pickerRects[0].right, resultRects[0].right);
        for (final title in [longTitle, shortTitle]) {
          expect(tester.widget<Text>(title).maxLines, 2);
        }
        expect(tester.widget<Text>(find.text('RJ000001')).maxLines, 1);
        await tester.enterText(find.byType(TextField), 'RJ000001');
        await tester.pump();
        expect(find.byType(FileTreeRow), findsOneWidget);
        expect(
          tester.getSize(find.byType(FileTreeRow)).height,
          pickerRects[0].height,
        );
        final rjText = tester.widget<RichText>(
          find.descendant(
            of: find.byType(FileTreeRow),
            matching: find.text('RJ000001', findRichText: true),
          ),
        );
        expect(
          (rjText.text as TextSpan).children!.first.style!.fontWeight,
          FontWeight.w900,
        );
        await tester.tap(find.byIcon(Icons.clear_rounded));
        await tester.pump();
        await tester.tap(find.text(entries[0].title));
        await tester.pump();
        expect(
          tester.widget<Checkbox>(find.byType(Checkbox).first).value,
          isTrue,
        );
        await tester.tap(find.byType(Checkbox).first);
        await tester.pump();
        expect(
          tester.widget<Checkbox>(find.byType(Checkbox).first).value,
          isFalse,
        );
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets('batch results wait for all lookups before saving', (
    tester,
  ) async {
    final pending = Completer<List<DlsiteMetadata>>();
    final session = DlsiteMetadataBatchSession(
      entries: [resultEntry('001')],
      lookup: (_) => pending.future,
      apply: (_) async {},
    );
    final languageProvider = AppLanguageProvider();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
        ],
        child: MaterialApp(
          home: DlsiteMetadataBatchResultsPage(session: session),
        ),
      ),
    );
    await tester.pump();

    final doneButton = find.byKey(
      const ValueKey<String>('batch_metadata_results_done'),
    );
    expect(
      tester
          .widget<InkWell>(
            find.descendant(of: doneButton, matching: find.byType(InkWell)),
          )
          .onTap,
      isNull,
    );
  });

  testWidgets('batch results show completion counts after saving', (
    tester,
  ) async {
    final session = DlsiteMetadataBatchSession(
      entries: [resultEntry('001'), resultEntry('002')],
      lookup: (query) => Future<List<DlsiteMetadata>>.value([
        resultMetadata(query.rjCode!.substring(5)),
      ]),
      apply: (_) async {},
    );
    final languageProvider = AppLanguageProvider();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
        ],
        child: MaterialApp(
          home: DlsiteMetadataBatchResultsPage(session: session),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // Tapping Save with 0 confirmed items shows hint instead of popping.
    await tester.tap(
      find.byKey(const ValueKey<String>('batch_metadata_results_done')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('batch_metadata_completion_dialog')),
      findsNothing,
    );
    expect(
      find.text(languageProvider.tr('batch_results_none_confirmed')),
      findsOneWidget,
    );

    session.confirm(0, metadata: resultMetadata('001'), saveCover: false);
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('batch_metadata_results_done')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('batch_metadata_completion_dialog')),
      findsOneWidget,
    );
    expect(
      find.text(
        languageProvider.tr('batch_metadata_completion_saved', {'count': '1'}),
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        languageProvider.tr('batch_metadata_completion_skipped', {
          'count': '1',
        }),
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        languageProvider.tr('batch_metadata_completion_failed', {'count': '0'}),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'batch results filter, confirm matched, retry failed, and confirm leave',
    (tester) async {
      final theme = ThemeProvider(loadPersistedState: false);
      addTearDown(theme.dispose);
      var failThird = true;
      final session = DlsiteMetadataBatchSession(
        entries: [resultEntry('001'), resultEntry('002'), resultEntry('003')],
        lookup: (query) {
          if (query.rjCode == 'RJ000003' && failThird) {
            return Future<List<DlsiteMetadata>>.error(StateError('offline'));
          }
          return Future<List<DlsiteMetadata>>.value([
            resultMetadata(query.rjCode!.substring(5)),
          ]);
        },
        apply: (_) async {},
      );
      final languageProvider = AppLanguageProvider();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(
              languageProvider,
            ),
          ],
          child: MaterialApp(
            theme: theme.lightTheme,
            home: Builder(
              builder: (context) => FilledButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        DlsiteMetadataBatchResultsPage(session: session),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final allFilter = find.text(languageProvider.tr('batch_filter_all'));
      final failedFilter = find.text(
        languageProvider.tr('batch_filter_failed'),
      );
      final categoryBar = find.byWidgetPredicate(
        (widget) => widget is HeaderSegmentedCategoryBar,
      );
      final categorySurface = find.descendant(
        of: categoryBar,
        matching: find.byType(HeaderFloatingSurface),
      );
      final confirm = find.byKey(
        const ValueKey<String>('batch_metadata_confirm_found'),
      );
      final confirmSurface = find.ancestor(
        of: confirm,
        matching: find.byType(HeaderFloatingButton),
      );
      final capsule = find.byType(HeaderTopCapsule);
      final progress = find.descendant(
        of: capsule,
        matching: find.text(
          languageProvider.tr('batch_results_progress', {
            'done': '3',
            'total': '3',
            'confirmed': '0',
          }),
        ),
      );
      expect(progress, findsOneWidget);
      expect(
        tester.getTopLeft(categorySurface).dy,
        greaterThan(tester.getBottomLeft(capsule).dy),
      );
      expect(
        tester.getTopLeft(confirmSurface).dx,
        greaterThan(tester.getTopRight(categorySurface).dx),
      );
      expect(
        tester.getCenter(confirmSurface).dy,
        tester.getCenter(categorySurface).dy,
      );
      expect(tester.getSize(confirmSurface), const Size.square(38));
      final firstRow = find.byKey(
        const ValueKey<String>('batch_metadata_result_0'),
      );
      expect(
        tester.getTopLeft(firstRow).dy,
        greaterThan(tester.getBottomLeft(categorySurface).dy),
      );
      final allSize = tester.getSize(allFilter);
      final failedSize = tester.getSize(failedFilter);
      bool isSelected(Finder label) => tester.widget<Semantics>(
        find.ancestor(
          of: label,
          matching: find.byWidgetPredicate(
            (widget) => widget is Semantics && widget.properties.selected != null,
          ),
        ),
      ).properties.selected!;
      expect(isSelected(allFilter), isTrue);
      expect(isSelected(failedFilter), isFalse);

      // Filter to Failed -> only item 2 visible
      await tester.tap(failedFilter);
      await tester.pumpAndSettle();
      expect(isSelected(allFilter), isFalse);
      expect(isSelected(failedFilter), isTrue);
      expect(tester.getSize(allFilter), allSize);
      expect(tester.getSize(failedFilter), failedSize);
      expect(
        find.byKey(const ValueKey<String>('batch_metadata_result_2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('batch_metadata_result_0')),
        findsNothing,
      );

      // Retry failed items
      failThird = false;
      await tester.tap(
        find.byKey(const ValueKey<String>('batch_metadata_retry_failed')),
      );
      await tester.pumpAndSettle();

      // Switch back to All and confirm all matched
      await tester.tap(allFilter);
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(session.confirmedCount, 3);
      expect(
        find.text(
          languageProvider.tr('batch_results_save_count', {'count': '3'}),
        ),
        findsOneWidget,
      );

      // Pressing Back prompts leave confirmation instead of discarding silently
      await tester.tap(find.byType(AppHeaderBackButton));
      await tester.pumpAndSettle();
      expect(
        find.text(languageProvider.tr('batch_results_leave_title')),
        findsOneWidget,
      );
      await tester.tap(find.text(languageProvider.tr('cancel')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('batch_metadata_results_header')),
        findsOneWidget,
      );
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('work picker toggles select all and deselect all', (tester) async {
    final languageProvider = AppLanguageProvider();
    final entries = [resultEntry('001'), resultEntry('002')];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
        ],
        child: MaterialApp(
          home: DlsiteMetadataWorkPickerPage(
            entries: entries,
            initialSelection: const <AudioLibraryCategoryEntry>[],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.byKey(
      const ValueKey<String>('batch_metadata_picker_select_all'),
    );
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      find.text(languageProvider.tr('batch_metadata_picker_done', {'count': 2})),
      findsOneWidget,
    );

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      find.text(languageProvider.tr('batch_metadata_picker_done', {'count': 0})),
      findsOneWidget,
    );
  });

  testWidgets('failed saves retain the result page after the summary closes', (
    tester,
  ) async {
    final session = DlsiteMetadataBatchSession(
      entries: [resultEntry('001')],
      lookup: (_) =>
          Future<List<DlsiteMetadata>>.value([resultMetadata('001')]),
      apply: (_) => Future<void>.error(StateError('storage unavailable')),
    );
    final languageProvider = AppLanguageProvider();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      DlsiteMetadataBatchResultsPage(session: session),
                ),
              ),
              child: const Text('open results'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open results'));
    await tester.pump();
    await tester.pump();
    session.confirm(0, metadata: resultMetadata('001'), saveCover: false);
    await tester.pump();

    final doneButton = find.byKey(
      const ValueKey<String>('batch_metadata_results_done'),
    );
    tester
        .widget<InkWell>(
          find.descendant(of: doneButton, matching: find.byType(InkWell)),
        )
        .onTap!
        .call();
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('batch_metadata_completion_confirm')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('batch_metadata_results_header')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(HeaderTopCapsule),
        matching: find.byIcon(Icons.cloud_download_rounded),
      ),
      findsOneWidget,
    );
  });

  testWidgets('batch setup hint floats in the header above the scope list', (
    tester,
  ) async {
    final languageProvider = AppLanguageProvider();
    addTearDown(languageProvider.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = switch (defaultTargetPlatform) {
      TargetPlatform.windows => const Size(960, 600),
      _ => const Size(360, 760),
    };
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.4),
            ),
            child: child!,
          ),
          home: const DlsiteMetadataBatchPage(entries: []),
        ),
      ),
    );

    await tester.pump();

    final hint = find.text(languageProvider.tr('batch_metadata_hint'));
    final hintSurface = find.ancestor(
      of: hint,
      matching: find.byType(HeaderFloatingSurface),
    );
    expect(hintSurface, findsOneWidget);
    expect(
      find.ancestor(of: hintSurface, matching: find.byType(TopPageHeader)),
      findsOneWidget,
    );
    final scope = find.byKey(const ValueKey('batch_metadata_scope_group'));
    expect(
      tester.getRect(scope).top - tester.getRect(hintSurface).bottom,
      closeTo(8, 0.1),
    );
    expect(tester.takeException(), isNull);
    final start = find.byKey(const ValueKey<String>('batch_metadata_start'));
    expect(start, findsOneWidget);
    expect(
      find.text(languageProvider.tr('batch_metadata_start')),
      findsOneWidget,
    );
    expect(
      tester.getRect(start).bottom,
      closeTo(tester.getSize(find.byType(Scaffold)).height - 16, 0.1),
    );
    expect(
      tester.getRect(start).right,
      closeTo(tester.getSize(find.byType(Scaffold)).width - 16, 0.1),
    );
  }, variant: const TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.windows,
  }));

  testWidgets(
    'picker clears entry ink and ignores results after disposal',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final observer = _RecordingNavigatorObserver();
      final languageProvider = AppLanguageProvider();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(
              languageProvider,
            ),
          ],
          child: MaterialApp(
            navigatorKey: navigatorKey,
            navigatorObservers: <NavigatorObserver>[observer],
            home: Builder(
              builder: (context) => FilledButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const DlsiteMetadataBatchPage(entries: []),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final batchRoute = observer.lastRoute;

      final specific = find.textContaining(
        languageProvider.tr('batch_metadata_specific'),
      );
      await tester.ensureVisible(specific);
      final dynamic inkController = Material.of(tester.element(specific));
      Iterable<InteractiveInkFeature> visibleInk() =>
          (inkController.debugInkFeatures as List<InkFeature>? ?? [])
              .whereType<InteractiveInkFeature>()
              .where((feature) => feature.color.a > 0);

      final gesture = await tester.startGesture(tester.getCenter(specific));
      await tester.pump(const Duration(milliseconds: 120));
      expect(visibleInk(), isNotEmpty);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 260));
      expect(visibleInk(), isEmpty);
      await tester.pumpAndSettle();
      expect(observer.lastRoute, isNot(same(batchRoute)));

      navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(visibleInk(), isEmpty);
      await tester.pumpAndSettle();
      expect(specific, findsOneWidget);

      await tester.tap(find.widgetWithIcon(IconButton, Icons.edit_rounded));
      await tester.pumpAndSettle();
      expect(observer.lastRoute, isNot(same(batchRoute)));

      navigatorKey.currentState!.removeRoute(batchRoute);
      await tester.pump();
      navigatorKey.currentState!.pop(<AudioLibraryCategoryEntry>[]);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Windows metadata exclusions use visible actions and right click',
    (tester) async {
      final session = DlsiteMetadataBatchSession(
        entries: [resultEntry('001')],
        lookup: (_) async => [resultMetadata('001')],
        apply: (_) async {},
      );
      final language = AppLanguageProvider();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
          ],
          child: MaterialApp(
            home: DlsiteMetadataBatchResultsPage(session: session),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Dismissible), findsNothing);
      final action = find.byKey(const ValueKey('batch_metadata_exclude_0'));
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(session.items.single.isExcluded, isTrue);
      final row = find.byKey(const ValueKey('batch_metadata_result_0'));
      final mouse = await tester.startGesture(
        tester.getCenter(row),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await mouse.up();
      await tester.pumpAndSettle();
      await tester.tap(find.text(language.tr('batch_metadata_action_restore')));
      await tester.pumpAndSettle();
      expect(session.items.single.isExcluded, isFalse);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets('swiping left excludes item and swiping left again restores it', (
    tester,
  ) async {
    final session = DlsiteMetadataBatchSession(
      entries: [resultEntry('001'), resultEntry('002')],
      lookup: (query) => Future<List<DlsiteMetadata>>.value([
        resultMetadata(query.rjCode!.substring(5)),
      ]),
      apply: (_) async {},
    );
    final languageProvider = AppLanguageProvider();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
        ],
        child: MaterialApp(
          home: DlsiteMetadataBatchResultsPage(session: session),
        ),
      ),
    );
    await tester.pump();

    final item0 = find.byKey(const ValueKey<String>('batch_metadata_result_0'));
    expect(item0, findsOneWidget);

    // Initial state: not excluded, opacity 1.0, found icon
    expect(session.items[0].isExcluded, isFalse);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('batch_metadata_status_0')),
        matching: find.byIcon(Icons.pending_rounded),
      ),
      findsOneWidget,
    );

    // Swipe left to reveal exclude action
    await tester.drag(item0, const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(session.items[0].isExcluded, isFalse);

    // Tap revealed exclude action
    await tester.tap(
      find.byTooltip(languageProvider.tr('batch_metadata_action_exclude')),
    );
    await tester.pumpAndSettle();
    expect(session.items[0].isExcluded, isTrue);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('batch_metadata_status_0')),
        matching: find.byIcon(Icons.block_rounded),
      ),
      findsOneWidget,
    );

    // Verify opacity is reduced (greyed out)
    final opacityWidget = tester.widget<Opacity>(
      find.ancestor(of: item0, matching: find.byType(Opacity)).first,
    );
    expect(opacityWidget.opacity, closeTo(0.38, 0.01));

    // Swipe left again to reveal restore action and tap it
    await tester.drag(item0, const Offset(-200, 0));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byTooltip(languageProvider.tr('batch_metadata_action_restore')),
    );
    await tester.pumpAndSettle();

    expect(session.items[0].isExcluded, isFalse);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('batch_metadata_status_0')),
        matching: find.byIcon(Icons.pending_rounded),
      ),
      findsOneWidget,
    );

    final restoredOpacity = tester.widget<Opacity>(
      find.ancestor(of: item0, matching: find.byType(Opacity)).first,
    );
    expect(restoredOpacity.opacity, equals(1.0));
  });

  testWidgets('excluding searching item unblocks saving and skips excluded item', (
    tester,
  ) async {
    final pending = Completer<List<DlsiteMetadata>>();
    final saved = <DlsiteMetadataBatchItem>[];
    final session = DlsiteMetadataBatchSession(
      entries: [resultEntry('001'), resultEntry('002')],
      lookup: (query) => switch (query.rjCode) {
        'RJ000001' => Future<List<DlsiteMetadata>>.value([resultMetadata('001')]),
        _ => pending.future,
      },
      apply: (item) async {
        saved.add(item);
      },
    );
    final languageProvider = AppLanguageProvider();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
        ],
        child: MaterialApp(
          home: DlsiteMetadataBatchResultsPage(session: session),
        ),
      ),
    );
    await tester.pump();

    // Confirm item 0
    session.confirm(0, metadata: resultMetadata('001'), saveCover: false);
    await tester.pump();

    // Done button should be disabled because item 1 is still searching
    final doneButton = find.byKey(
      const ValueKey<String>('batch_metadata_results_done'),
    );
    expect(
      tester
          .widget<InkWell>(
            find.descendant(of: doneButton, matching: find.byType(InkWell)),
          )
          .onTap,
      isNull,
    );

    // Swipe left to reveal exclude action on item 1 (searching item) and tap it
    final item1 = find.byKey(const ValueKey<String>('batch_metadata_result_1'));
    await tester.drag(item1, const Offset(-200, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(
      find.byTooltip(languageProvider.tr('batch_metadata_action_exclude')),
    );
    await tester.pumpAndSettle();

    expect(session.items[1].isExcluded, isTrue);

    // Done button should now be enabled!
    expect(
      tester
          .widget<InkWell>(
            find.descendant(of: doneButton, matching: find.byType(InkWell)),
          )
          .onTap,
      isNotNull,
    );

    // Tap confirm to save
    await tester.tap(doneButton);
    await tester.pumpAndSettle();

    // Item 0 is saved, item 1 is skipped
    expect(saved.length, 1);
    expect(saved.single.entry.title, 'Work 001');

    // Dialog shows completion with 1 saved and 1 skipped
    expect(
      find.byKey(const ValueKey<String>('batch_metadata_completion_dialog')),
      findsOneWidget,
    );
  });

  testWidgets(
    'DlsiteMetadataBatchReviewPage listens to session and enables next work when background lookup finishes',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: CoverArtworkCacheService(
          libraryService: LibraryService(),
          remoteCoverDownloader: (_) async => null,
        ),
      );
      addTearDown(fixture.dispose);
      final secondLookup = Completer<List<DlsiteMetadata>>();
      final session = DlsiteMetadataBatchSession(
        entries: [resultEntry('001'), resultEntry('002')],
        lookup: (query) => switch (query.rjCode) {
          'RJ000001' => Future<List<DlsiteMetadata>>.value([
            resultMetadata('001'),
          ]),
          _ => secondLookup.future,
        },
      );
      addTearDown(session.dispose);
      session.start();
      await tester.pumpWidget(
        fixture.build(
          DlsiteMetadataBatchReviewPage(session: session, initialIndex: 0),
        ),
      );
      await tester.pumpAndSettle();

      final nextButton = find.byKey(
        const ValueKey<String>('dlsite_review_next_work'),
      );
      expect(
        tester.widget<IconButton>(nextButton).onPressed,
        isNull,
      );

      secondLookup.complete([resultMetadata('002')]);
      await tester.pumpAndSettle();

      expect(
        tester.widget<IconButton>(nextButton).onPressed,
        isNotNull,
      );
    },
  );
}

class _RecordingNavigatorObserver extends NavigatorObserver {
  final List<Route<dynamic>> _routes = <Route<dynamic>>[];

  Route<dynamic> get lastRoute => _routes.last;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    super.didPush(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    super.didRemove(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    super.didPop(route, previousRoute);
  }
}
