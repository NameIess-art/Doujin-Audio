import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:doujin_audio/core/widgets/search_highlight.dart';
import 'package:doujin_audio/core/widgets/app_search_page.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_category_widgets.dart';
import 'package:doujin_audio/features/library/presentation/library_search_page.dart';
import 'package:doujin_audio/features/library/presentation/library_providers.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_tree_widgets.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_ui_helpers.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/library_snapshot_cache_service.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/runtime_test_models.dart';

class _FixedCategorySnapshotCache extends LibrarySnapshotCacheService {
  _FixedCategorySnapshotCache({
    required super.libraryService,
    required super.detailCacheService,
    required this.snapshot,
  }) : super(
         treeSnapshotBuilder: (payload) async => LibraryTreeSnapshot(
           tree: payload.tracks.map(TrackNode.new).toList(),
           leafFolderCount: 0,
         ),
       );

  AudioLibraryCategorySnapshot snapshot;
  @override
  AudioLibraryCategorySnapshot get categorySnapshotSync => snapshot;

  @override
  Future<AudioLibraryCategorySnapshot> categorySnapshot({
    required VoidCallback onCommitted,
  }) async => snapshot;
}

void main() {
  AppRuntimeTestFixture.initialize();
  test(
    'worker filters with AND terms and stably promotes normalized paths',
    () async {
      final entries = [
        for (var i = 0; i < 5; i++)
          _createEntry(
            title: 'Work $i',
            path: 'C:/Work/$i',
            tags: i == 4 ? ['ASMR'] : ['ASMR', 'Sleep'],
            voiceActors: ['Voice'],
            circleName: 'Circle',
          ),
      ];
      final snapshot = AudioLibraryCategorySnapshot(
        entries: entries,
        structureRevision: 1,
        detailRevision: 1,
      );
      final request = (
        snapshot: snapshot,
        category: AudioLibraryCategoryType.tags,
        queryTerms: ['work'],
        termKeywords: ['sl'],
        selectedTerms: {'ASMR', 'Sleep'},
        pinnedPaths: {r'C:\Work\3', 'C:/Work/1/'},
      );
      final result = await compute(filterLibraryCategoryEntries, request);
      expect(result.entries.map((entry) => entry.title), [
        'Work 1',
        'Work 3',
        'Work 0',
        'Work 2',
      ]);
      expect(result.terms, ['Sleep']);
      expect(snapshot.entries, entries);
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'local search suggests terms and waits for confirmation on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        UiInteractionCoordinator.instance.resetForTest();
        addTearDown(UiInteractionCoordinator.instance.resetForTest);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final tracks = [
          for (final title in ['Alpha', 'Beta'])
            testMusicTrack(
              name: title,
              path: '/$title.mp3',
              groupKey: '/$title.mp3',
              groupTitle: title,
              isSingle: true,
            ),
        ];
        fixture.library.addTracks(tracks, persist: false);
        final cache = _FixedCategorySnapshotCache(
          libraryService: fixture.libraryService,
          detailCacheService: fixture.library.detailCacheService,
          snapshot: AudioLibraryCategorySnapshot(
            entries: [
              for (final title in ['Alpha', 'Beta'])
                _createEntry(
                  title: title,
                  path: '/$title.mp3',
                  tags: ['ASMR'],
                  voiceActors: ['Voice'],
                  circleName: 'Circle',
                ),
            ],
            structureRevision: fixture.library.structureRevision,
            detailRevision: fixture.library.detailCacheService.revision,
          ),
        );
        final library = LibraryFacade.create(
          databaseRepository: fixture.persistenceRepository,
          service: fixture.libraryService,
          detailCacheService: fixture.library.detailCacheService,
          snapshotCacheService: cache,
          coverArtworkCacheService: fixture.library.coverArtworkCacheService,
        );
        await tester.runAsync(
          fixture.library.coverArtworkCacheService.initialize,
        );
        await tester.pumpWidget(
          fixture.build(
            const LibrarySearchPage(),
            overrides: [libraryFacadeProvider.overrideWithValue(library)],
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('library_search_suggestions')),
          findsOneWidget,
        );
        expect(find.byType(LibraryTreeItem), findsNothing);
        final scaffold = tester
            .widget<AppSearchPageScaffold<AudioLibraryCategoryType>>(
              find.byType(AppSearchPageScaffold<AudioLibraryCategoryType>),
            );
        expect(scaffold.categories, isEmpty);
        expect(scaffold.onConfirm, isNull);
        expect(find.text('历史'), findsOneWidget);
        expect(find.text('声优'), findsOneWidget);
        expect(find.text('标签'), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('library_search_voices')),
            matching: find.text('Voice'),
          ),
        );
        await tester.pumpAndSettle();
        final field = find.byKey(const ValueKey('app_search_field'));
        expect(tester.widget<TextField>(field).controller!.text, 'Voice');
        expect(
          tester
              .widget<AppSearchSuggestionSection>(
                find.byKey(const ValueKey('library_search_voices')),
              )
              .isSelected('Voice'),
          isTrue,
        );
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('library_search_voices')),
            matching: find.text('Voice'),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller!.text, isEmpty);
        await tester.enterText(field, 'Alpha, ASMR');
        await tester.pumpAndSettle();
        expect(find.byType(LibraryTreeItem), findsNothing);
        expect(fixture.settings.librarySearchHistory, isEmpty);
        tester
            .widget<AppSearchPageScaffold<AudioLibraryCategoryType>>(
              find.byType(AppSearchPageScaffold<AudioLibraryCategoryType>),
            )
            .onConfirm!();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('library_search_suggestions')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('search_/Alpha.mp3')), findsOneWidget);
        expect(find.byKey(const ValueKey('search_/Beta.mp3')), findsNothing);
        expect(fixture.settings.librarySearchHistory, ['Alpha, ASMR']);
        final item = tester.widget<LibraryTreeItem>(
          find.byType(LibraryTreeItem).first,
        );
        item.onLongPress!();
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<LibraryTreeItem>(find.byType(LibraryTreeItem).first)
              .isSelected,
          isTrue,
        );
        expect(
          tester
              .widget<AppSearchPageScaffold<AudioLibraryCategoryType>>(
                find.byType(AppSearchPageScaffold<AudioLibraryCategoryType>),
              )
              .showConfirmButton,
          isFalse,
        );
        expect(find.byKey(const ValueKey('app_search_confirm')), findsNothing);
        (tester
                    .widget<AppSearchPageScaffold<AudioLibraryCategoryType>>(
                      find.byType(
                        AppSearchPageScaffold<AudioLibraryCategoryType>,
                      ),
                    )
                    .controlsOverlay
                as LibraryBatchSelectionHeader)
            .onExit();
        await tester.pumpAndSettle();
        await tester.enterText(field, 'Beta');
        await tester.pumpAndSettle();
        expect(find.byType(LibraryTreeItem), findsNothing);
        expect(
          find.byKey(const ValueKey('library_search_suggestions')),
          findsOneWidget,
        );
        final historyItem = find.descendant(
          of: find.byKey(const ValueKey('library_search_history')),
          matching: find.text('Alpha, ASMR'),
        );
        await tester.tap(historyItem);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(field).controller!.text,
          'Beta, Alpha, ASMR',
        );
        await tester.tap(historyItem);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller!.text, 'Beta');
        await tester.showKeyboard(field);
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('search_/Beta.mp3')), findsOneWidget);
        tester
            .widget<AppSearchPageScaffold<AudioLibraryCategoryType>>(
              find.byType(AppSearchPageScaffold<AudioLibraryCategoryType>),
            )
            .onCloseOrClear();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('library_search_suggestions')),
          findsOneWidget,
        );
        expect(find.byType(LibraryTreeItem), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  group('SearchHighlightScope.withTerms', () {
    testWidgets(
      'provides custom terms list to descendant SearchHighlightedText',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: SearchHighlightScope.withTerms(
                terms: ['alpha', 'beta'],
                child: SearchHighlightedText(
                  text: 'alpha test beta',
                  style: TextStyle(),
                ),
              ),
            ),
          ),
        );

        expect(find.byType(RichText), findsOneWidget);
        final richText = tester.widget<RichText>(find.byType(RichText));
        final textSpan = richText.text as TextSpan;
        expect(textSpan.children, isNotNull);
        expect(textSpan.children!.length, greaterThan(1));
      },
    );
  });

  group('Category entry search filtering logic', () {
    final entry1 = _createEntry(
      title: 'Work Alpha',
      path: '/path/1',
      tags: ['ASMR', 'Relaxation'],
      voiceActors: ['VoiceA'],
      circleName: 'CircleOne',
    );
    final entry2 = _createEntry(
      title: 'Work Beta',
      path: '/path/2',
      tags: ['Sleep', 'ASMR'],
      voiceActors: ['VoiceB'],
      circleName: 'CircleTwo',
    );

    test('Single-value and multi-value term matching on entries', () {
      final terms1 = entry1.normalizedTermsForCategory(
        AudioLibraryCategoryType.tags,
      );
      expect(terms1.contains('asmr'), isTrue);
      expect(terms1.contains('relaxation'), isTrue);

      final terms2 = entry2.normalizedTermsForCategory(
        AudioLibraryCategoryType.tags,
      );
      expect(terms2.contains('asmr'), isTrue);
      expect(terms2.contains('sleep'), isTrue);
    });
  });

  group('LibraryCategoryTermBox styling', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      for (final width in [400.0, 1280.0]) {
        testWidgets(
          'term card aligns with header capsule on $platform at width $width',
          (tester) async {
            debugDefaultTargetPlatformOverride = platform;
            addTearDown(() => debugDefaultTargetPlatformOverride = null);
            await tester.binding.setSurfaceSize(Size(width, 800));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final controller = TextEditingController();
            final focus = FocusNode();
            addTearDown(controller.dispose);
            addTearDown(focus.dispose);
            for (final type in AudioLibraryCategoryType.values.skip(1)) {
              await tester.pumpWidget(
                MaterialApp(
                  home: AppSearchPageScaffold<AudioLibraryCategoryType>(
                    key: ValueKey(type),
                    controller: controller,
                    focusNode: focus,
                    hintText: 'Search',
                    categories: [
                      AppSearchCategory(value: type, label: type.name),
                    ],
                    selectedCategory: type,
                    onCategorySelected: (_) {},
                    onChanged: (_) {},
                    onSubmitted: (_) {},
                    onCloseOrClear: () {},
                    body: ListView(
                      padding: const EdgeInsets.fromLTRB(8, 100, 8, 16),
                      children: [
                        LibraryCategoryTermBox(
                          categoryType: type,
                          collapseOnMount: true,
                          terms: const ['Term'],
                          selectedTerms: const {},
                          emptyText: 'Empty',
                          clearLabel: 'Clear',
                          searchHintText: 'Search terms',
                          searchQuery: '',
                          onSearchQueryChanged: (_) {},
                          onToggle: (_) {},
                          onClear: () {},
                        ),
                      ],
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              final card = find.descendant(
                of: find.byType(LibraryCategoryTermBox),
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is DecoratedBox &&
                      widget.decoration is BoxDecoration &&
                      (widget.decoration as BoxDecoration).borderRadius ==
                          BorderRadius.circular(
                            LibraryCategoryTermBox.capsuleRadius,
                          ),
                ),
              );
              void expectAligned() {
                final headerRect = tester.getRect(
                  find.byKey(const ValueKey('app_search_category_shell')),
                );
                final cardRect = tester.getRect(card);
                expect(cardRect.left, headerRect.left);
                expect(cardRect.right, headerRect.right);
                expect(tester.takeException(), isNull);
              }

              expectAligned();
              await tester.tap(find.widgetWithText(ActionChip, '展开'));
              await tester.pumpAndSettle();
              expectAligned();
              await tester.tap(find.widgetWithText(ActionChip, '收起'));
              await tester.pumpAndSettle();
              expectAligned();
            }
            await tester.pumpWidget(const SizedBox.shrink());
            debugDefaultTargetPlatformOverride = null;
          },
        );
      }

      testWidgets(
        'large term batches retain selection and reset on search on $platform',
        (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          final selected = ValueNotifier(<String>{'term1999'});
          final query = ValueNotifier('');
          addTearDown(selected.dispose);
          addTearDown(query.dispose);
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: ListView(
                  children: [
                    ValueListenableBuilder<String>(
                      valueListenable: query,
                      builder: (context, text, _) =>
                          ValueListenableBuilder<Set<String>>(
                            valueListenable: selected,
                            builder: (context, selection, _) =>
                                LibraryCategoryTermBox(
                                  categoryType: AudioLibraryCategoryType.tags,
                                  collapseOnMount: true,
                                  terms: text.isEmpty
                                      ? List.generate(2000, (i) => 'term$i')
                                      : const ['term1999'],
                                  selectedTerms: selection,
                                  emptyText: 'empty',
                                  clearLabel: 'clear',
                                  searchHintText: 'search',
                                  searchQuery: text,
                                  onSearchQueryChanged: (value) =>
                                      query.value = value,
                                  onToggle: (term) =>
                                      selected.value = selection.contains(term)
                                      ? (Set.of(selection)..remove(term))
                                      : {...selection, term},
                                  onClear: () => selected.value = {},
                                ),
                          ),
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(ActionChip, '展开'));
          await tester.pumpAndSettle();
          expect(find.byType(FilterChip), findsNWidgets(41));
          expect(find.text('term1999'), findsOneWidget);
          expect(find.text('term40'), findsNothing);
          final more = find.byKey(
            const ValueKey('library_category_terms_more_tags'),
          );
          await tester.ensureVisible(more);
          await tester.tap(more);
          await tester.pumpAndSettle();
          expect(find.byType(FilterChip), findsNWidgets(81));
          expect(find.text('term40'), findsOneWidget);
          await tester.ensureVisible(find.text('term1999'));
          await tester.tap(find.text('term1999'));
          await tester.pumpAndSettle();
          expect(selected.value, isEmpty);
          expect(find.byType(FilterChip), findsNWidgets(80));
          query.value = 'term1999';
          await tester.pumpAndSettle();
          expect(find.byType(FilterChip), findsOneWidget);
          expect(more, findsNothing);
          query.value = '';
          await tester.pumpAndSettle();
          expect(find.byType(FilterChip), findsNWidgets(40));
          final collapse = find.widgetWithText(ActionChip, '收起');
          await tester.ensureVisible(collapse);
          await tester.tap(collapse);
          await tester.pumpAndSettle();
          expect(find.byType(FilterChip), findsNothing);
          await tester.tap(find.widgetWithText(ActionChip, '展开'));
          await tester.pumpAndSettle();
          expect(find.byType(FilterChip), findsNWidgets(40));
          await tester.pumpWidget(const SizedBox.shrink());
          debugDefaultTargetPlatformOverride = null;
        },
      );
    }

    testWidgets(
      'displays capsule style when collapsed and transitions to card style when expanded',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LibraryCategoryTermBox(
                categoryType: AudioLibraryCategoryType.tags,
                collapseOnMount: true,
                terms: const ['tag1', 'tag2'],
                selectedTerms: const {},
                emptyText: 'No tags',
                clearLabel: 'Clear',
                searchHintText: 'Search tags...',
                searchQuery: '',
                onSearchQueryChanged: (_) {},
                onToggle: (_) {},
                onClear: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Collapsed: Container has capsule border radius
        final containerFinder = find.byType(AnimatedContainer);
        expect(containerFinder, findsOneWidget);
        final container = tester.widget<AnimatedContainer>(containerFinder);
        final decoration = container.decoration as BoxDecoration;
        expect(
          decoration.borderRadius,
          BorderRadius.circular(LibraryCategoryTermBox.capsuleRadius),
        );

        // AnimatedSize alignment is Alignment.topCenter (anchors search row to prevent flickering other rows)
        final animatedSizeFinder = find.byType(AnimatedSize);
        expect(animatedSizeFinder, findsOneWidget);
        final animatedSize = tester.widget<AnimatedSize>(animatedSizeFinder);
        expect(animatedSize.alignment, Alignment.topCenter);

        // Collapsed: TextField has capsule border radius
        final textFieldFinder = find.byType(TextField);
        expect(textFieldFinder, findsOneWidget);
        final textField = tester.widget<TextField>(textFieldFinder);
        final border =
            textField.decoration!.enabledBorder as OutlineInputBorder;
        expect(border.borderRadius, BorderRadius.circular(999));

        // Collapsed: ActionChip has StadiumBorder
        final actionChipFinder = find.byType(ActionChip);
        expect(actionChipFinder, findsOneWidget);
        final actionChip = tester.widget<ActionChip>(actionChipFinder);
        expect(actionChip.shape, const StadiumBorder());

        // Tap ActionChip to expand
        await tester.tap(actionChipFinder);
        await tester.pumpAndSettle();

        // Expanded: Container border radius matches capsule border radius
        final expandedContainer = tester.widget<AnimatedContainer>(
          containerFinder,
        );
        final expandedDecoration =
            expandedContainer.decoration as BoxDecoration;
        expect(
          expandedDecoration.borderRadius,
          BorderRadius.circular(LibraryCategoryTermBox.capsuleRadius),
        );

        // Expanded: TextField retains capsule border radius
        final expandedTextField = tester.widget<TextField>(textFieldFinder);
        final expandedBorder =
            expandedTextField.decoration!.enabledBorder as OutlineInputBorder;
        expect(expandedBorder.borderRadius, BorderRadius.circular(999));

        // Expanded: ActionChip has StadiumBorder
        final expandedActionChip = tester.widget<ActionChip>(actionChipFinder);
        expect(expandedActionChip.shape, const StadiumBorder());

        // Expanded: FilterChip elements have StadiumBorder (capsule style)
        final filterChipFinder = find.byType(FilterChip);
        expect(filterChipFinder, findsNWidgets(2));
        final filterChip = tester.widget<FilterChip>(filterChipFinder.first);
        expect(filterChip.shape, const StadiumBorder());

        // Tap ActionChip to collapse again
        await tester.tap(actionChipFinder);
        await tester.pumpAndSettle();

        // Back to capsule
        final reCollapsedContainer = tester.widget<AnimatedContainer>(
          containerFinder,
        );
        final reCollapsedDecoration =
            reCollapsedContainer.decoration as BoxDecoration;
        expect(
          reCollapsedDecoration.borderRadius,
          BorderRadius.circular(LibraryCategoryTermBox.capsuleRadius),
        );
      },
    );
  });
}

AudioLibraryCategoryEntry _createEntry({
  required String title,
  required String path,
  required List<String> tags,
  required List<String> voiceActors,
  required String circleName,
}) {
  final target = AudioDetailTarget.singleAudioFile(path);
  return AudioLibraryCategoryEntry(
    target: target,
    title: title,
    path: path,
    isFolder: false,
    detail: AudioDetail(
      target: target,
      rjCode: '',
      workTitle: title,
      circleName: circleName,
      voiceActors: voiceActors,
      tags: tags,
    ),
    tracks: const [],
  );
}
