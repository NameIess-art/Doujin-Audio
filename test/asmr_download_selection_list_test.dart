import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_selection.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_selection_tree.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

AsmrTrackFile _node(String path, {List<AsmrTrackFile>? children}) =>
    AsmrTrackFile(
      hash: path,
      title: path,
      type: children == null ? 'audio' : 'folder',
      streamUrl: null,
      downloadUrl: null,
      lowQualityUrl: null,
      duration: Duration.zero,
      size: children == null ? 1024 : 0,
      children: children ?? const [],
      workId: 1,
      workTitle: 'Work',
      sourceId: 'RJ000001',
      relativePath: path,
    );

Future<void> _pumpList(
  WidgetTester tester,
  AsmrDownloadSelectionModel selection,
) async {
  SharedPreferences.setMockInitialValues({});
  final language = AppLanguageProvider();
  await language.initialized;
  addTearDown(language.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appLanguageProviderInstanceProvider.overrideWithValue(language),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, setState) => AsmrDownloadSelectionList(
              selection: selection,
              onSelectionChanged: () => setState(() {}),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _jumpToEnd(WidgetTester tester, ScrollPosition position) async {
  for (var i = 0; i < 4; i++) {
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
  }
}

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'large download directory mounts only viewport rows on $platform',
      (tester) async {
        final model = AsmrDownloadSelectionModel([
          _node(
            'root',
            children: [for (var i = 0; i < 2000; i++) _node('track$i')],
          ),
        ]);
        await _pumpList(tester, model);
        expect(find.text('track0'), findsOneWidget);
        expect(find.text('track1999'), findsNothing);
        expect(
          find.byType(AsmrDownloadNodeTile).evaluate().length,
          lessThan(30),
        );

        final position = tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position;
        await _jumpToEnd(tester, position);
        expect(find.text('track1999'), findsOneWidget);
        expect(
          find.byType(AsmrDownloadNodeTile).evaluate().length,
          lessThan(30),
        );
        await tester.tap(find.text('track1999'));
        await tester.pumpAndSettle();
        expect(model.stateForPath('track1999'), isTrue);
        expect(model.stateForPath('root'), isNull);
        expect(model.selectedLeafCount(), 1);
        expect(model.selectedTotalSizeBytes(), 1024);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets(
    'download expansion and selection survive collapse and scrolling',
    (tester) async {
      final model = AsmrDownloadSelectionModel([
        _node(
          'root',
          children: [
            _node('disc', children: [_node('one'), _node('two')]),
            _node('empty', children: []),
            for (var i = 0; i < 200; i++) _node('extra$i'),
          ],
        ),
      ]);
      await _pumpList(tester, model);
      expect(find.text('one'), findsNothing);
      await tester.tap(find.text('disc'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('one'));
      await tester.pumpAndSettle();
      expect(model.stateForPath('disc'), isNull);
      expect(model.stateForPath('root'), isNull);
      await tester.tap(find.text('root'));
      await tester.pumpAndSettle();
      expect(find.text('disc'), findsNothing);
      await tester.tap(find.text('root'));
      await tester.pumpAndSettle();
      expect(find.text('one'), findsOneWidget);

      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      await _jumpToEnd(tester, position);
      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('one'), findsOneWidget);
      final disc = find.byKey(const ValueKey('asmr_download_node_disc'));
      await tester.tap(
        find.descendant(of: disc, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      expect(model.stateForPath('one'), isFalse);
      expect(model.stateForPath('two'), isFalse);
      await tester.tap(
        find.descendant(of: disc, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      expect(model.stateForPath('one'), isTrue);
      expect(model.stateForPath('two'), isTrue);
      expect(model.selectedLeafCount(), 2);
      await tester.tap(find.text('empty'));
      await tester.pumpAndSettle();
      final language = ProviderScope.containerOf(
        tester.element(disc),
        listen: false,
      ).read(appLanguageProviderInstanceProvider);
      expect(
        find.text(language.tr('asmr_download_empty_folder')),
        findsOneWidget,
      );
    },
  );
}
