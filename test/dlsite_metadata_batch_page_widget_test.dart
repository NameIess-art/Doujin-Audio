import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/dlsite_metadata.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/library/application/dlsite_metadata_batch_session.dart';
import 'package:doujin_audio/features/library/application/dlsite_metadata_service.dart';
import 'package:doujin_audio/features/library/domain/audio_library_category.dart';
import 'package:doujin_audio/features/library/presentation/dlsite_metadata_batch_page.dart';

void main() {
  AudioLibraryCategoryEntry resultEntry(String id) {
    final target = AudioDetailTarget.libraryRootFolder('/library/$id');
    return AudioLibraryCategoryEntry(
      target: target,
      title: 'Work $id',
      path: target.targetPath,
      isFolder: true,
      detail: AudioDetail.empty(target).copyWith(rjCode: 'RJ000$id'),
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
      find.byKey(const ValueKey<String>('batch_metadata_results_done')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('batch_metadata_status_0')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('batch_metadata_status_0')),
        matching: find.byIcon(Icons.pending_actions_rounded),
      ),
      findsOneWidget,
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
        matching: find.byIcon(Icons.pending_actions_rounded),
      ),
      findsOneWidget,
    );
    session.confirm(3, metadata: resultMetadata('004'), saveCover: false);
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('batch_metadata_status_3')),
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsOneWidget,
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
    expect(
      find.byKey(const ValueKey<String>('batch_metadata_picker_search')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    final searchField = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('batch_metadata_picker_search')),
        matching: find.byType(TextField),
      ),
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
      const EdgeInsets.only(top: 58, bottom: 78),
    );
    expect(
      find.byKey(const ValueKey<String>('batch_metadata_picker_done')),
      findsOneWidget,
    );
    expect(find.byType(HeaderFloatingSurface), findsNWidgets(3));
  });

  testWidgets('batch result rows match the work picker row height', (
    tester,
  ) async {
    final languageProvider = AppLanguageProvider();
    final entry = resultEntry('001');
    final session = DlsiteMetadataBatchSession(
      entries: [entry],
      lookup: (_) =>
          Future<List<DlsiteMetadata>>.value([resultMetadata('001')]),
    );

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
    final resultRowHeight = tester
        .getSize(find.byKey(const ValueKey<String>('batch_metadata_result_0')))
        .height;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
        ],
        child: MaterialApp(
          home: DlsiteMetadataWorkPickerPage(
            entries: [entry],
            initialSelection: const [],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      resultRowHeight,
      tester.getSize(find.byType(CheckboxListTile)).height,
    );
  });

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
      entries: [resultEntry('001')],
      lookup: (_) =>
          Future<List<DlsiteMetadata>>.value([resultMetadata('001')]),
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
        languageProvider.tr('batch_metadata_completion_saved', {'count': '0'}),
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
  });

  testWidgets('batch setup content follows the one-line header closely', (
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
        child: const MaterialApp(home: DlsiteMetadataBatchPage(entries: [])),
      ),
    );

    expect(
      tester.widget<ListView>(find.byType(ListView)).padding,
      const EdgeInsets.fromLTRB(16, 58, 16, 88),
    );
    final start = find.widgetWithText(
      FilledButton,
      languageProvider.tr('batch_metadata_start'),
    );
    expect(start, findsOneWidget);
    expect(
      tester.getRect(start).bottom,
      closeTo(tester.getSize(find.byType(Scaffold)).height - 16, 0.1),
    );
  });

  testWidgets('picker result is ignored after batch page is disposed', (
    tester,
  ) async {
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
    await tester.tap(specific);
    await tester.pumpAndSettle();
    expect(observer.lastRoute, isNot(same(batchRoute)));

    navigatorKey.currentState!.removeRoute(batchRoute);
    await tester.pump();
    navigatorKey.currentState!.pop(<AudioLibraryCategoryEntry>[]);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

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
        matching: find.byIcon(Icons.pending_actions_rounded),
      ),
      findsOneWidget,
    );

    // Swipe left to exclude
    await tester.drag(item0, const Offset(-500, 0));
    // While the swipe and rebound animation are underway, item is not yet excluded
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(session.items[0].isExcluded, isFalse);

    // After rebound completely finishes, state changes
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
      find.ancestor(
        of: item0,
        matching: find.byType(Opacity),
      ).first,
    );
    expect(opacityWidget.opacity, closeTo(0.38, 0.01));

    // Swipe left again to restore
    await tester.drag(item0, const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(session.items[0].isExcluded, isFalse);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('batch_metadata_status_0')),
        matching: find.byIcon(Icons.pending_actions_rounded),
      ),
      findsOneWidget,
    );

    final restoredOpacity = tester.widget<Opacity>(
      find.ancestor(
        of: item0,
        matching: find.byType(Opacity),
      ).first,
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

    // Swipe left to exclude item 1 (searching item)
    final item1 = find.byKey(const ValueKey<String>('batch_metadata_result_1'));
    await tester.drag(item1, const Offset(-500, 0));
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
