import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/core/widgets/file_tree_row.dart';
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
  AsmrDownloadSelectionModel selection, {
  bool reduceMotion = false,
  double textScale = 1,
}) async {
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
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reduceMotion,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
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
  testWidgets('download file type icons use work detail colors', (
    tester,
  ) async {
    final model = AsmrDownloadSelectionModel([
      _node(
        'folder',
        children: [
          _node('audio.mp3'),
          _node('notes.txt'),
          _node('cover.jpg'),
          _node('subtitle.srt'),
          _node('metadata.json'),
          _node('audio.cue'),
          _node('booklet.pdf'),
          _node('cover.bmp'),
        ],
      ),
    ]);
    await _pumpList(tester, model);
    final expected = {
      'folder': AppDesignTokens.folderIconColor,
      'audio.mp3': AppDesignTokens.light.asmrAccent,
      'notes.txt': AppDesignTokens.textFileIconColor,
      'cover.jpg': AppDesignTokens.imageFileIconColor,
      'subtitle.srt': AppDesignTokens.textFileIconColor,
      'metadata.json': AppDesignTokens.textFileIconColor,
      'audio.cue': AppDesignTokens.textFileIconColor,
      'booklet.pdf': AppDesignTokens.textFileIconColor,
      'cover.bmp': AppDesignTokens.imageFileIconColor,
    };
    for (final entry in expected.entries) {
      final row = find.ancestor(
        of: find.text(entry.key),
        matching: find.byType(FileTreeRow),
      );
      final icon = find.descendant(of: row, matching: find.byType(Icon)).first;
      expect(tester.widget<Icon>(icon).color, entry.value);
      expect(tester.widget<Icon>(icon).size, AppDesignTokens.fileEntryIconSize);
    }
    expect(find.byIcon(AppDesignTokens.audioFileIcon), findsOneWidget);
    expect(find.byIcon(AppDesignTokens.textFileIcon), findsNWidgets(5));
    expect(find.byIcon(AppDesignTokens.imageFileIcon), findsNWidgets(2));
  });

  testWidgets('download rows show invariant subtree sizes and shared shape', (
    tester,
  ) async {
    final model = AsmrDownloadSelectionModel([
      _node('root', children: [_node('one'), _node('two')]),
    ]);
    await _pumpList(tester, model);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.text('1.0 KB'), findsNWidgets(2));
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    expect(find.byType(Checkbox), findsNWidgets(3));
    expect(tester.getSize(find.byType(FileTreeRow).first).height, 44);
    final rows = find.byType(FileTreeRow);
    for (var index = 0; index < 3; index++) {
      expect(tester.getSize(rows.at(index)).height, 44);
      if (index > 0) {
        expect(
          tester.getRect(rows.at(index)).top,
          tester.getRect(rows.at(index - 1)).bottom,
        );
      }
    }
    final ink = tester.widget<InkWell>(
      find
          .descendant(
            of: find.byType(FileTreeRow).first,
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(ink.borderRadius, FileTreeRow.borderRadius);
    await tester.tap(find.text('one'));
    await tester.pumpAndSettle();
    expect(model.stateForPath('root'), isNull);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(model.selectedTotalSizeBytes(), 1024);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'download rows fit deep folders with large text on $platform',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 600);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        var roots = [_node('long audio file name.mp3')];
        for (var depth = 8; depth >= 0; depth--) {
          roots = [_node('folder$depth', children: roots)];
        }
        final model = AsmrDownloadSelectionModel(roots);
        await _pumpList(tester, model, textScale: 2);
        for (var depth = 1; depth <= 8; depth++) {
          await tester.scrollUntilVisible(find.text('folder$depth'), 100);
          await tester.ensureVisible(find.text('folder$depth'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('folder$depth'));
          await tester.pumpAndSettle();
        }
        await tester.scrollUntilVisible(
          find.text('long audio file name.mp3'),
          100,
        );
        await tester.ensureVisible(find.text('long audio file name.mp3'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.text('long audio file name.mp3')).width,
          greaterThan(40),
        );
        await tester.tap(find.text('long audio file name.mp3'));
        await tester.pumpAndSettle();
        expect(model.selectedLeafCount(), 1);
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'download folders animate and safely reverse on $platform',
      (tester) async {
        final model = AsmrDownloadSelectionModel([
          _node(
            'root',
            children: [
              _node('disc', children: [_node('one')]),
            ],
          ),
        ]);
        await _pumpList(tester, model);
        await tester.tap(find.text('disc'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final opacity = tester
            .widget<FadeTransition>(
              find
                  .ancestor(
                    of: find.text('one'),
                    matching: find.byType(FadeTransition),
                  )
                  .first,
            )
            .opacity
            .value;
        expect(opacity, greaterThan(0));
        expect(opacity, lessThan(1));
        await tester.tap(find.text('disc'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tap(find.text('one'), warnIfMissed: false);
        await tester.pump();
        expect(model.stateForPath('one'), isFalse);
        await tester.tap(find.text('disc'));
        await tester.pump(const Duration(milliseconds: 30));
        await tester.tap(find.text('disc'));
        await tester.pumpAndSettle();
        expect(find.text('one'), findsNothing);
        await tester.tap(find.text('disc'));
        await tester.pumpAndSettle();
        expect(find.text('one'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'download animation work stays constant for large folders on $platform',
      (tester) async {
        for (final count in [20, 2000]) {
          final model = AsmrDownloadSelectionModel([
            _node(
              'root',
              children: [
                _node(
                  'disc',
                  children: [for (var i = 0; i < count; i++) _node('track$i')],
                ),
              ],
            ),
          ]);
          await _pumpList(tester, model);
          await tester.tap(find.text('disc'));
          // Check before the first frame: AnimatedList used to start one
          // ticker for every descendant despite only mounting viewport rows.
          expect(tester.binding.transientCallbackCount, lessThan(10));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          final fades = find
              .byType(FadeTransition)
              .evaluate()
              .map((element) => element.widget as FadeTransition)
              .where((fade) => fade.opacity.value > 0 && fade.opacity.value < 1)
              .toList();
          expect(fades.length, greaterThan(1));
          expect(fades.map((fade) => fade.opacity).toSet(), hasLength(1));
          expect(
            find.byType(AsmrDownloadNodeTile).evaluate().length,
            lessThan(110),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('track0'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('disc'));
          expect(tester.binding.transientCallbackCount, lessThan(10));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 60));
          await tester.tap(find.text('disc'));
          await tester.pumpAndSettle();
          expect(model.stateForPath('track0'), isTrue);
          expect(find.text('track0'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'download folder keeps its scroll anchor while changing on $platform',
      (tester) async {
        final model = AsmrDownloadSelectionModel([
          _node(
            'root',
            children: [
              for (var i = 0; i < 100; i++) _node('before$i'),
              _node('disc', children: [_node('one'), _node('two')]),
              for (var i = 0; i < 100; i++) _node('after$i'),
            ],
          ),
        ]);
        await _pumpList(tester, model);
        await tester.scrollUntilVisible(find.text('disc'), 200);
        await tester.ensureVisible(find.text('disc'));
        await tester.pumpAndSettle();
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position;
        final offset = position.pixels;
        final top = tester.getRect(find.text('disc')).top;
        await tester.tap(find.text('disc'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(position.pixels, closeTo(offset, 0.01));
        expect(tester.getRect(find.text('disc')).top, closeTo(top, 0.01));
        await tester.tap(find.text('disc'));
        await tester.pumpAndSettle();
        expect(position.pixels, closeTo(offset, 0.01));
        expect(tester.getRect(find.text('disc')).top, closeTo(top, 0.01));
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'download can change another folder during animation on $platform',
      (tester) async {
        final model = AsmrDownloadSelectionModel([
          _node(
            'root',
            children: [
              _node(
                'disc',
                children: [
                  _node('nested', children: [_node('leaf')]),
                  _node('one'),
                ],
              ),
              _node('other', children: [_node('two')]),
            ],
          ),
        ]);
        await _pumpList(tester, model);
        await tester.tap(find.text('disc'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.text('nested'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.text('other'));
        await tester.pumpAndSettle();
        expect(find.text('leaf'), findsOneWidget);
        expect(find.text('two'), findsOneWidget);
        await tester.tap(find.text('leaf'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('disc'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tap(find.text('other'));
        await tester.pumpAndSettle();
        expect(find.text('leaf'), findsNothing);
        expect(find.text('two'), findsNothing);
        await tester.tap(find.text('disc'));
        await tester.pumpAndSettle();
        expect(find.text('leaf'), findsOneWidget);
        expect(model.stateForPath('leaf'), isTrue);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets('reduced motion completes folder changes immediately', (
    tester,
  ) async {
    final model = AsmrDownloadSelectionModel([
      _node(
        'root',
        children: [
          _node('disc', children: [_node('one')]),
        ],
      ),
    ]);
    await _pumpList(tester, model, reduceMotion: true);
    await tester.tap(find.text('disc'));
    await tester.pump();
    expect(find.text('one'), findsOneWidget);
    expect(
      tester
          .widget<FadeTransition>(
            find
                .ancestor(
                  of: find.text('one'),
                  matching: find.byType(FadeTransition),
                )
                .first,
          )
          .opacity
          .value,
      1,
    );
    expect(
      tester
          .widget<AnimatedRotation>(find.byType(AnimatedRotation).last)
          .duration,
      Duration.zero,
    );
    await tester.tap(find.text('disc'));
    await tester.pump();
    expect(find.text('one'), findsNothing);
  });

  testWidgets('large download expansion stays lazy throughout animation', (
    tester,
  ) async {
    final model = AsmrDownloadSelectionModel([
      _node(
        'root',
        children: [
          _node(
            'disc',
            children: [for (var i = 0; i < 2000; i++) _node('track$i')],
          ),
        ],
      ),
    ]);
    await _pumpList(tester, model);
    await tester.tap(find.text('disc'));
    await tester.pump();
    expect(find.byType(AsmrDownloadNodeTile).evaluate().length, lessThan(110));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(AsmrDownloadNodeTile).evaluate().length, lessThan(110));
    await tester.pumpAndSettle();
    expect(find.byType(AsmrDownloadNodeTile).evaluate().length, lessThan(30));
    await tester.tap(find.text('disc'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(AsmrDownloadNodeTile).evaluate().length, lessThan(110));
    await tester.pumpAndSettle();
    expect(find.text('track0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deep download folders remain selectable in a narrow pane', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    var tree = [_node('leaf.mp3')];
    for (var depth = 20; depth >= 0; depth--) {
      tree = [_node('folder$depth', children: tree)];
    }
    final model = AsmrDownloadSelectionModel(tree);
    await _pumpList(tester, model);
    for (var depth = 1; depth <= 20; depth++) {
      final folder = find.byKey(ValueKey('asmr_download_node_folder$depth'));
      await tester.scrollUntilVisible(folder, 100);
      await tester.ensureVisible(find.text('folder$depth'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: folder, matching: find.text('folder$depth')),
      );
      await tester.pumpAndSettle();
    }
    final leaf = find.byKey(const ValueKey('asmr_download_node_leaf.mp3'));
    await tester.scrollUntilVisible(leaf, 100);
    expect(tester.takeException(), isNull);
    final title = find.descendant(of: leaf, matching: find.text('leaf.mp3'));
    expect(tester.getSize(title).width, greaterThan(40));
    await tester.tap(title);
    await tester.pumpAndSettle();
    expect(model.stateForPath('leaf.mp3'), isTrue);
    expect(model.selectedLeafCount(), 1);

    tester.view.physicalSize = const Size(510, 1000);
    await tester.pumpAndSettle();
    expect(find.text('leaf.mp3'), findsOneWidget);
    expect(model.stateForPath('leaf.mp3'), isTrue);
    expect(tester.takeException(), isNull);
  });

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
