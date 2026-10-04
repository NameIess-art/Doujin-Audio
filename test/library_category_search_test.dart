import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/widgets/search_highlight.dart';
import 'package:doujin_audio/core/widgets/app_search_page.dart';
import 'package:doujin_audio/features/library/domain/audio_library_category.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_category_widgets.dart';
import 'package:doujin_audio/features/library/presentation/library_search_page.dart';
import 'package:doujin_audio/features/library/presentation/library_providers.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/library_snapshot_cache_service.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';

import 'support/app_runtime_test_fixture.dart';

class _CountingCategoryEntry extends AudioLibraryCategoryEntry {
  _CountingCategoryEntry(AudioLibraryCategoryEntry entry)
    : super(
        target: entry.target,
        title: entry.title,
        path: entry.path,
        isFolder: entry.isFolder,
        detail: entry.detail,
        tracks: entry.tracks,
      );

  final reads = <AudioLibraryCategoryType, int>{};

  @override
  Set<String> normalizedTermsForCategory(AudioLibraryCategoryType type) {
    reads.update(type, (value) => value + 1, ifAbsent: () => 1);
    return super.normalizedTermsForCategory(type);
  }
}

class _FixedCategorySnapshotCache extends LibrarySnapshotCacheService {
  _FixedCategorySnapshotCache({
    required super.libraryService,
    required super.detailCacheService,
    required this.snapshot,
  }) : super(
         treeSnapshotBuilder: (_) async =>
             LibraryTreeSnapshot(tree: const [], leafFolderCount: 0),
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
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'visited categories retain lists, filters and scroll on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        UiInteractionCoordinator.instance.resetForTest();
        addTearDown(UiInteractionCoordinator.instance.resetForTest);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final darkTheme = ValueNotifier(false);
        addTearDown(darkTheme.dispose);
        final entries = List.generate(
          30,
          (index) => _CountingCategoryEntry(
            _createEntry(
              title: 'Work $index',
              path: '/work/$index',
              tags: ['ASMR'],
              voiceActors: ['Voice'],
              circleName: 'Circle',
            ),
          ),
        );
        final cache = _FixedCategorySnapshotCache(
          libraryService: fixture.libraryService,
          detailCacheService: fixture.library.detailCacheService,
          snapshot: AudioLibraryCategorySnapshot(
            entries: entries,
            tagTerms: ['ASMR'],
            voiceActorTerms: ['Voice'],
            circleTerms: ['Circle'],
            structureRevision: fixture.libraryService.structureRevision,
            detailRevision: fixture.library.detailCacheService.revision,
          ),
        );
        final library = LibraryFacade.create(
          databaseRepository: fixture.persistenceRepository,
          service: fixture.libraryService,
          detailCacheService: fixture.library.detailCacheService,
          snapshotCacheService: cache,
        );
        await tester.pumpWidget(
          fixture.build(
            ValueListenableBuilder<bool>(
              valueListenable: darkTheme,
              child: const LibrarySearchPage(),
              builder: (_, dark, child) => Theme(
                data: dark ? ThemeData.dark() : ThemeData.light(),
                child: child!,
              ),
            ),
            overrides: [libraryFacadeProvider.overrideWithValue(library)],
          ),
        );
        await tester.pumpAndSettle();
        Future<void> choose(AudioLibraryCategoryType type) async {
          await tester.tap(find.byKey(ValueKey('app_search_category_$type')));
          await tester.pumpAndSettle();
        }

        await choose(AudioLibraryCategoryType.tags);
        await tester.tap(find.widgetWithText(ActionChip, '展开'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilterChip, 'ASMR'));
        await tester.pumpAndSettle();
        final tagListFinder = find.byKey(
          const ValueKey('library_category_tags'),
        );
        final tagList = tester.widget<ListView>(tagListFinder);
        final termState = tester.state(find.byType(LibraryCategoryTermBox));
        tagList.controller!.jumpTo(32);
        await tester.pumpAndSettle();
        final reads = Map<AudioLibraryCategoryType, int>.of(
          entries.first.reads,
        );
        for (var round = 0; round < 2; round++) {
          await choose(AudioLibraryCategoryType.voiceActors);
          await choose(AudioLibraryCategoryType.tags);
          expect(tester.widget<ListView>(tagListFinder), same(tagList));
          expect(
            tester.state(find.byType(LibraryCategoryTermBox)),
            same(termState),
          );
          expect(tagList.controller!.offset, 32);
          expect(
            entries.first.reads[AudioLibraryCategoryType.tags],
            reads[AudioLibraryCategoryType.tags],
          );
        }
        tagList.controller!.jumpTo(0);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilterChip>(find.widgetWithText(FilterChip, 'ASMR'))
              .selected,
          isTrue,
        );
        expect(find.widgetWithText(ActionChip, '收起'), findsOneWidget);
        darkTheme.value = true;
        await tester.pumpAndSettle();
        expect(
          Theme.of(
            tester.element(find.byType(AudioLibraryCategoryEntryCard).first),
          ).brightness,
          Brightness.dark,
        );
        AudioLibraryCategoryEntryCard firstCard() =>
            tester.widget<AudioLibraryCategoryEntryCard>(
              find.byType(AudioLibraryCategoryEntryCard).first,
            );
        firstCard().onLongPress!();
        await tester.pumpAndSettle();
        expect(firstCard().isSelectionMode, isTrue);
        tester
            .widget<AppSearchPageScaffold<AudioLibraryCategoryType>>(
              find.byType(AppSearchPageScaffold<AudioLibraryCategoryType>),
            )
            .onCategorySelected(AudioLibraryCategoryType.voiceActors);
        await tester.pumpAndSettle();
        await choose(AudioLibraryCategoryType.tags);
        expect(firstCard().isSelectionMode, isFalse);
        expect(find.widgetWithText(ActionChip, '收起'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
  testWidgets(
    'hidden visited categories wait for activation to filter latest state',
    (tester) async {
      UiInteractionCoordinator.instance.resetForTest();
      addTearDown(UiInteractionCoordinator.instance.resetForTest);
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final entries = [
        for (final title in ['Alpha', 'Beta'])
          _CountingCategoryEntry(
            _createEntry(
              title: title,
              path: '/$title',
              tags: ['ASMR'],
              voiceActors: ['Voice'],
              circleName: 'Circle',
            ),
          ),
      ];
      AudioLibraryCategorySnapshot snapshot() => AudioLibraryCategorySnapshot(
        entries: entries,
        tagTerms: ['ASMR'],
        voiceActorTerms: ['Voice'],
        circleTerms: ['Circle'],
        structureRevision: fixture.libraryService.structureRevision,
        detailRevision: fixture.library.detailCacheService.revision,
      );
      final cache = _FixedCategorySnapshotCache(
        libraryService: fixture.libraryService,
        detailCacheService: fixture.library.detailCacheService,
        snapshot: snapshot(),
      );
      final library = LibraryFacade.create(
        databaseRepository: fixture.persistenceRepository,
        service: fixture.libraryService,
        detailCacheService: fixture.library.detailCacheService,
        snapshotCacheService: cache,
      );
      await tester.pumpWidget(
        fixture.build(
          const LibrarySearchPage(),
          overrides: [libraryFacadeProvider.overrideWithValue(library)],
        ),
      );
      await tester.pumpAndSettle();
      Future<void> choose(AudioLibraryCategoryType type) async {
        await tester.tap(find.byKey(ValueKey('app_search_category_$type')));
        await tester.pumpAndSettle();
      }

      for (final type in AudioLibraryCategoryType.values.skip(1)) {
        await choose(type);
      }
      await choose(AudioLibraryCategoryType.all);
      final priorReads = Map<AudioLibraryCategoryType, int>.of(
        entries.first.reads,
      );
      await tester.enterText(
        find.byKey(const ValueKey('app_search_field')),
        'Beta',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      fixture.settings.pinnedLibraryPaths = ['/Beta'];
      fixture.settings.syncSlice(isInitialized: true);
      fixture.libraryService.markStructureChanged();
      cache.snapshot = snapshot();
      fixture.library.syncPresentationState(isInitialized: true);
      await tester.pumpAndSettle();
      expect(entries.first.reads, priorReads);
      await choose(AudioLibraryCategoryType.tags);
      expect(
        entries.first.reads[AudioLibraryCategoryType.tags],
        greaterThan(priorReads[AudioLibraryCategoryType.tags]!),
      );
      expect(
        entries.first.reads[AudioLibraryCategoryType.voiceActors],
        priorReads[AudioLibraryCategoryType.voiceActors],
      );
      expect(find.byKey(const ValueKey('category_/Beta')), findsOneWidget);
      expect(find.byKey(const ValueKey('category_/Alpha')), findsNothing);
      final beforeSlide = entries.first.reads[AudioLibraryCategoryType.tags]!;
      await tester.tap(
        find.byKey(
          const ValueKey(
            'app_search_category_AudioLibraryCategoryType.voiceActors',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
      await tester.enterText(
        find.byKey(const ValueKey('app_search_field')),
        'Alpha',
      );
      await tester.pump(const Duration(milliseconds: 230));
      expect(entries.first.reads[AudioLibraryCategoryType.tags], beforeSlide);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('category_/Alpha')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  group('SearchHighlightScope.withTerms', () {
    testWidgets('provides custom terms list to descendant SearchHighlightedText', (
      tester,
    ) async {
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
    });
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

    test('Simultaneous AND condition matching between text query and element search', () {
      final entries = [entry1, entry2];

      List<AudioLibraryCategoryEntry> filter({
        required List<String> queryTerms,
        required List<String> normalizedSelectedTerms,
        required List<String> termKeywords,
      }) {
        final hasTextQuery = queryTerms.isNotEmpty;
        final hasElementQuery =
            normalizedSelectedTerms.isNotEmpty || termKeywords.isNotEmpty;

        return entries.where((entry) {
          final entryTerms = entry.normalizedTermsForCategory(
            AudioLibraryCategoryType.tags,
          );
          final matchesSelected = normalizedSelectedTerms.every(
            entryTerms.contains,
          );
          final matchesTermKeywords = termKeywords.every(
            (keyword) => entryTerms.any((term) => term.contains(keyword)),
          );
          final matchesElement =
              hasElementQuery && matchesSelected && matchesTermKeywords;
          final matchesText =
              hasTextQuery && queryTerms.every(entry.searchableText.contains);

          if (hasTextQuery && hasElementQuery) {
            return matchesText && matchesElement;
          } else if (hasTextQuery) {
            return matchesText;
          } else if (hasElementQuery) {
            return matchesElement;
          }
          return true;
        }).toList();
      }

      // Only text search ('alpha') matches entry1
      final textOnly = filter(
        queryTerms: ['alpha'],
        normalizedSelectedTerms: [],
        termKeywords: [],
      );
      expect(textOnly.map((e) => e.title), ['Work Alpha']);

      // Only element search ('asmr') matches both entry1 and entry2
      final elementOnly = filter(
        queryTerms: [],
        normalizedSelectedTerms: ['asmr'],
        termKeywords: [],
      );
      expect(elementOnly.map((e) => e.title), ['Work Alpha', 'Work Beta']);

      // Both active: text search 'alpha' AND element search 'asmr' -> matches ONLY entry1!
      final bothActiveMatch = filter(
        queryTerms: ['alpha'],
        normalizedSelectedTerms: ['asmr'],
        termKeywords: [],
      );
      expect(bothActiveMatch.map((e) => e.title), ['Work Alpha']);

      // Both active: text search 'beta' AND element search 'relaxation' -> matches NONE because entry2 has 'beta' but no 'relaxation', entry1 has 'relaxation' but no 'beta'
      final bothActiveNoMatch = filter(
        queryTerms: ['beta'],
        normalizedSelectedTerms: ['relaxation'],
        termKeywords: [],
      );
      expect(bothActiveNoMatch, isEmpty);
    });
  });

  group('LibraryCategoryTermBox styling', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
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
