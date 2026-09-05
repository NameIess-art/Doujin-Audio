import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_en.dart';
import 'package:doujin_audio/app/localization/app_language_zh.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/theme/app_styles.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/card_info_field.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/widgets/library_like_cards.dart';
import 'package:doujin_audio/core/widgets/marquee_text.dart';
import 'package:doujin_audio/core/widgets/scroll_activity_gate.dart';
import 'package:doujin_audio/core/widgets/shimmer_loading.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';

Widget _buildSurface(Widget child) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  home: Scaffold(
    body: Center(child: SizedBox(width: 360, child: child)),
  ),
);

Widget _buildScrollableHeader({required bool blurEnabled}) {
  return ProviderScope(
    overrides: [
      settingsStateProvider.overrideWith(
        (ref) => Stream<SettingsState>.value(
          SettingsState(uiBlurEffectEnabled: blurEnabled),
        ),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData.light(useMaterial3: true),
      home: Scaffold(
        body: ScrollActivityGate(
          child: Stack(
            children: [
              ListView(
                key: const ValueKey('header_scroll_list'),
                children: const [SizedBox(height: 1400)],
              ),
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: TopPageHeader(title: 'Library'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _buildPageAppBar({required bool blurEnabled}) {
  return ProviderScope(
    key: ValueKey<String>('page_app_bar_blur_$blurEnabled'),
    overrides: [
      settingsStateProvider.overrideWith(
        (ref) => Stream<SettingsState>.value(
          SettingsState(uiBlurEffectEnabled: blurEnabled),
        ),
      ),
    ],
    child: const MaterialApp(
      home: Scaffold(
        appBar: AppPageAppBar(title: Text('Secondary page')),
        body: SizedBox.expand(),
      ),
    ),
  );
}

LibraryLikeWorkCardContent _buildFeaturedCard({
  required String title,
  required List<LibraryLikeInfoLineData> lines,
  required Key coverKey,
  bool showExpandIndicator = true,
  bool compactCoverLayout = false,
}) {
  return LibraryLikeWorkCardContent(
    title: title,
    lines: lines,
    playTooltip: 'add',
    onPlay: () {},
    showExpandIndicator: showExpandIndicator,
    compactCoverLayout: compactCoverLayout,
    enableMarquee: false,
    enableTitleMarquee: false,
    coverBuilder: (coverWidth) => Container(
      key: coverKey,
      width: coverWidth,
      height: coverWidth / LibraryLikeCardMetrics.coverAspectRatio,
      decoration: BoxDecoration(
        color: Colors.pink,
        borderRadius: BorderRadius.circular(LibraryLikeCardMetrics.coverRadius),
      ),
    ),
  );
}

void main() {
  testWidgets('top header keeps blur while scrolling', (tester) async {
    await tester.pumpWidget(_buildScrollableHeader(blurEnabled: true));
    await tester.pump();

    expect(find.byType(BackdropFilter), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('header_scroll_list')),
      const Offset(0, -240),
    );
    await tester.pump();

    expect(find.byType(BackdropFilter), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 170));
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('top header keeps blur disabled when the setting is off', (
    tester,
  ) async {
    await tester.pumpWidget(_buildScrollableHeader(blurEnabled: false));
    await tester.pump();

    expect(find.byType(BackdropFilter), findsNothing);

    await tester.drag(
      find.byKey(const ValueKey('header_scroll_list')),
      const Offset(0, -240),
    );
    await tester.pump(const Duration(milliseconds: 170));

    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('secondary page app bar follows the glass effect setting', (
    tester,
  ) async {
    await tester.pumpWidget(_buildPageAppBar(blurEnabled: true));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('app_page_header_blur')),
      findsOneWidget,
    );

    await tester.pumpWidget(_buildPageAppBar(blurEnabled: false));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('app_page_header_blur')),
      findsNothing,
    );
  });

  testWidgets('placeholder content fades over the shared 750ms duration', (
    tester,
  ) async {
    var showPlaceholder = true;
    late StateSetter update;
    final contentKey = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return PlaceholderContentTransition(
              showPlaceholder: showPlaceholder,
              placeholder: const SizedBox(
                key: ValueKey('placeholder'),
                width: 80,
                height: 80,
              ),
              content: SizedBox(key: contentKey, width: 80, height: 80),
            );
          },
        ),
      ),
    );

    expect(
      kPlaceholderContentTransitionDuration,
      const Duration(milliseconds: 750),
    );

    update(() => showPlaceholder = false);
    await tester.pump();
    final fadeFinder = find.descendant(
      of: find.byType(PlaceholderContentTransition),
      matching: find.byType(FadeTransition),
    );
    expect(fadeFinder, findsNWidgets(2));
    expect(find.byKey(const ValueKey('placeholder')), findsOneWidget);
    expect(find.byKey(contentKey), findsOneWidget);
    expect(
      tester
          .widgetList<FadeTransition>(fadeFinder)
          .map((fade) => fade.opacity.value),
      unorderedEquals(<double>[0, 1]),
    );

    await tester.pump(const Duration(milliseconds: 350));
    final midpointOpacities = tester
        .widgetList<FadeTransition>(fadeFinder)
        .map((fade) => fade.opacity.value)
        .toList(growable: false);
    expect(midpointOpacities, hasLength(2));
    expect(midpointOpacities[0], inInclusiveRange(0.3, 0.7));
    expect(midpointOpacities[1], inInclusiveRange(0.3, 0.7));
    expect(midpointOpacities[0] + midpointOpacities[1], closeTo(1, 0.001));

    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const ValueKey('placeholder')), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('placeholder')), findsNothing);
    expect(find.byKey(contentKey), findsOneWidget);

    update(() => showPlaceholder = true);
    await tester.pump();
    update(() => showPlaceholder = false);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
  });

  test('library-like info lines map AudioDetail metadata consistently', () {
    final detail =
        AudioDetail.empty(
          AudioDetailTarget.libraryRootFolder('/library'),
        ).copyWith(
          rjCode: ' RJ123456 ',
          circleName: ' Circle ',
          voiceActors: const <String>[' Alice ', 'Alice', 'Bob'],
          tags: const <String>[' sleep ', 'sleep', 'voice'],
          releaseDate: DateTime(2026, 7, 2),
          salesCount: 1200,
          rating: 4.0,
        );

    final lines = buildLibraryLikeInfoLines(
      fields: CardInfoField.values,
      metadata: LibraryLikeInfoMetadata(
        rjCode: detail.rjCode,
        voiceActors: detail.voiceActors,
        circleName: detail.circleName,
        tags: detail.tags,
        releaseDate: detail.releaseDate,
        duration: detail.duration,
        salesCount: detail.salesCount,
        rating: detail.rating,
      ),
      circleLabel: 'Circle',
      tagsLabel: 'Tags',
      releaseDateLabel: 'Release',
      salesCountLabel: 'Sales',
      ratingLabel: 'Rating',
    );

    expect(
      lines.map((line) => '${line.label}:${line.text}:${line.lines}'),
      <String>[
        'RJ:RJ123456:1',
        'CV:Alice，Bob:1',
        'Circle:Circle:1',
        'Tags:sleep，voice:1',
        'Release:2026-07-02:1',
        'Sales:1200:1',
        'Rating:4:1',
      ],
    );
  });

  test('library-like info lines map AsmrWork metadata consistently', () {
    final work = AsmrWork(
      id: 1,
      title: 'Work',
      circleName: 'Circle',
      sourceId: 'RJ654321',
      sourceType: 'dlsite',
      sourceUrl: '',
      coverUrl: '',
      thumbnailUrl: '',
      mainCoverUrl: '',
      releaseDate: DateTime(2026, 6, 9),
      createDate: null,
      duration: const Duration(minutes: 30),
      dlCount: 345,
      reviewCount: 20,
      rating: 4.5,
      voiceActors: const <String>['Voice A', 'Voice B'],
      tags: const <String>['ASMR', 'Sleep'],
    );

    final lines = buildLibraryLikeInfoLines(
      fields: CardInfoField.values,
      metadata: LibraryLikeInfoMetadata(
        rjCode: work.rjCode,
        voiceActors: work.voiceActors,
        circleName: work.circleName,
        tags: work.tags,
        releaseDate: work.releaseDate,
        duration: work.duration,
        salesCount: work.dlCount,
        rating: work.rating,
      ),
      circleLabel: 'Circle',
      tagsLabel: 'Tags',
      releaseDateLabel: 'Release',
      salesCountLabel: 'Sales',
      ratingLabel: 'Rating',
      listSeparator: '、',
    );

    expect(
      lines.map((line) => '${line.label}:${line.text}:${line.lines}'),
      <String>[
        'RJ:RJ654321:1',
        'CV:Voice A、Voice B:1',
        'Circle:Circle:1',
        'Tags:ASMR、Sleep:1',
        'Release:2026-06-09:1',
        'Sales:345:1',
        'Rating:4.5:1',
      ],
    );
  });

  testWidgets('library card metrics keep the compact P2 baseline', (
    tester,
  ) async {
    const coverKey = ValueKey('local-cover');
    const title = '触手世界に堕ちたあなたと苗床調教済み双子少女';

    await tester.pumpWidget(
      _buildSurface(
        _buildFeaturedCard(
          title: title,
          coverKey: coverKey,
          lines: const [
            LibraryLikeInfoLineData('CV', '聖純シオ'),
            LibraryLikeInfoLineData('社团', 'えたーなるわーくす'),
            LibraryLikeInfoLineData('销量', '2070'),
            LibraryLikeInfoLineData(
              '标签',
              '搾乳，産卵，百合，触手，双子，丸呑み，バイノーラル',
              lines: 3,
            ),
          ],
        ),
      ),
    );

    expect(LibraryLikeCardMetrics.rootTileHeight, 150);
    expect(LibraryLikeCardMetrics.contentHeight, 134);
    expect(LibraryLikeCardMetrics.infoBlockHeight, 90);
    expect(LibraryLikeCardMetrics.infoVerticalOffset, -4);
    expect(LibraryLikeCardMetrics.titleBlockHeight, 38);
    expect(LibraryLikeCardMetrics.actionButtonSize, 40);
    expect(LibraryLikeCardMetrics.coverRadius, 8);
    expect(LibraryLikeCardMetrics.cardRadius, 10);
    expect(LibraryLikeCardMetrics.coverAspectRatio, kStandardCoverAspectRatio);

    expect(
      tester.getSize(find.byType(LibraryLikeWorkCardContent)),
      const Size(360, LibraryLikeCardMetrics.contentHeight),
    );
    expect(
      tester.getSize(find.byKey(coverKey)),
      const Size(
        LibraryLikeCardMetrics.infoBlockHeight *
            LibraryLikeCardMetrics.coverAspectRatio,
        LibraryLikeCardMetrics.infoBlockHeight,
      ),
    );
    expect(
      tester.getTopLeft(find.text('CV')).dy,
      tester.getTopLeft(find.byKey(coverKey)).dy +
          LibraryLikeCardMetrics.infoVerticalOffset,
    );
    expect(find.byType(MarqueeText), findsNothing);
    expect(find.byIcon(Icons.add_circle_rounded), findsOneWidget);
    expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);

    final titleText = tester.widget<Text>(find.text(title));
    expect(titleText.maxLines, 2);
    expect(titleText.overflow, TextOverflow.ellipsis);
    expect(titleText.softWrap, isTrue);
  });

  testWidgets('empty card info uses the compact resolved-cover layout', (
    tester,
  ) async {
    const coverKey = ValueKey('compact-cover');
    const title = 'A long work title that remains on the right of its cover';

    await tester.pumpWidget(
      _buildSurface(
        ListTile(
          minTileHeight: LibraryLikeCardMetrics.compactRootTileHeight,
          contentPadding: LibraryLikeCardMetrics.rootTilePadding,
          title: _buildFeaturedCard(
            title: title,
            coverKey: coverKey,
            lines: const <LibraryLikeInfoLineData>[],
            compactCoverLayout: true,
          ),
        ),
      ),
    );

    final content = find.byType(LibraryLikeWorkCardContent);
    final contentRect = tester.getRect(content);
    final coverRect = tester.getRect(find.byKey(coverKey));
    final addRect = tester.getRect(find.byIcon(Icons.add_circle_rounded));
    final expandRect = tester.getRect(find.byIcon(Icons.expand_more_rounded));

    expect(
      tester.getSize(content),
      const Size(344, LibraryLikeCardMetrics.compactContentHeight),
    );
    expect(
      tester.getSize(find.byKey(coverKey)),
      const Size(
        LibraryLikeCardMetrics.compactContentHeight *
            LibraryLikeCardMetrics.coverAspectRatio,
        LibraryLikeCardMetrics.compactContentHeight,
      ),
    );
    expect(
      tester.getSize(find.byType(ListTile)).height,
      LibraryLikeCardMetrics.compactRootTileHeight,
    );

    final topFinder = find.text('A long work title that remains on the');
    final bottomFinder = find.text('right of its cover');
    expect(topFinder, findsOneWidget);
    expect(bottomFinder, findsOneWidget);

    final topRect = tester.getRect(topFinder);
    final bottomRect = tester.getRect(bottomFinder);
    final topText = tester.widget<Text>(topFinder);
    final bottomText = tester.widget<Text>(bottomFinder);

    expect(topRect.left, greaterThan(coverRect.right));
    expect(topRect.top, contentRect.top);
    expect(bottomRect.left, greaterThan(coverRect.right));
    expect(bottomRect.right, lessThanOrEqualTo(addRect.left));
    expect(addRect.center.dy, greaterThan(contentRect.center.dy));
    expect(expandRect.center.dy, greaterThan(contentRect.center.dy));
    expect(addRect.left, greaterThan(coverRect.right));
    expect(expandRect.left, greaterThan(addRect.left));
    expect(topText.maxLines, 3);
    expect(bottomText.maxLines, 3);
    expect(bottomText.overflow, TextOverflow.ellipsis);
    expect(bottomRect.top, equals(topRect.bottom));
  });

  test('splitCompactCardTitle preserves short titles and splits long titles', () {
    const style = TextStyle(fontSize: 14, height: 1.06, fontWeight: FontWeight.w800);

    final (shortTop, shortBot) = splitCompactCardTitle(
      title: 'Short',
      style: style,
      maxWidth: 206,
      textDirection: TextDirection.ltr,
    );
    expect(shortTop, 'Short');
    expect(shortBot, isEmpty);

    final (longTop, longBot) = splitCompactCardTitle(
      title: 'A long work title that remains on the right of its cover',
      style: style,
      maxWidth: 206,
      textDirection: TextDirection.ltr,
    );
    expect(longTop, 'A long work title that remains on the');
    expect(longBot, 'right of its cover');
  });

  testWidgets('compact card with short title keeps title in top block', (
    tester,
  ) async {
    const coverKey = ValueKey('compact-short-cover');
    const title = 'Short';

    await tester.pumpWidget(
      _buildSurface(
        ListTile(
          minTileHeight: LibraryLikeCardMetrics.compactRootTileHeight,
          contentPadding: LibraryLikeCardMetrics.rootTilePadding,
          title: _buildFeaturedCard(
            title: title,
            coverKey: coverKey,
            lines: const <LibraryLikeInfoLineData>[],
            compactCoverLayout: true,
          ),
        ),
      ),
    );

    final addRect = tester.getRect(find.byIcon(Icons.add_circle_rounded));
    final titleFinder = find.text(title);
    expect(titleFinder, findsOneWidget);
    expect(tester.getTopLeft(titleFinder).dy, lessThan(addRect.top));
  });

  testWidgets(
    'compact card actions keep fixed position regardless of title length',
    (tester) async {
      const coverKey1 = ValueKey('cover-short');
      const coverKey2 = ValueKey('cover-long');
      const shortTitle = 'Short';
      const longTitle =
          'A long work title that remains on the right of its cover';

      await tester.pumpWidget(
        _buildSurface(
          ListTile(
            minTileHeight: LibraryLikeCardMetrics.compactRootTileHeight,
            contentPadding: LibraryLikeCardMetrics.rootTilePadding,
            title: _buildFeaturedCard(
              title: shortTitle,
              coverKey: coverKey1,
              lines: const <LibraryLikeInfoLineData>[],
              compactCoverLayout: true,
            ),
          ),
        ),
      );

      final shortAddRect =
          tester.getRect(find.byIcon(Icons.add_circle_rounded));
      final shortExpandRect =
          tester.getRect(find.byIcon(Icons.expand_more_rounded));

      await tester.pumpWidget(
        _buildSurface(
          ListTile(
            minTileHeight: LibraryLikeCardMetrics.compactRootTileHeight,
            contentPadding: LibraryLikeCardMetrics.rootTilePadding,
            title: _buildFeaturedCard(
              title: longTitle,
              coverKey: coverKey2,
              lines: const <LibraryLikeInfoLineData>[],
              compactCoverLayout: true,
            ),
          ),
        ),
      );

      final longAddRect =
          tester.getRect(find.byIcon(Icons.add_circle_rounded));
      final longExpandRect =
          tester.getRect(find.byIcon(Icons.expand_more_rounded));

      expect(longAddRect, equals(shortAddRect));
      expect(longExpandRect, equals(shortExpandRect));
    },
  );

  testWidgets(
    'metadata card keeps the configured compact layout while the cover loads',
    (tester) async {
      const coverKey = ValueKey('metadata-compact-cover');

      Widget buildCard({required bool loading}) {
        return _buildSurface(
          LibraryLikeMetadataWorkCardContent(
            title: 'Work',
            fields: const <CardInfoField>[],
            metadata: const LibraryLikeInfoMetadata(),
            circleLabel: 'Circle',
            tagsLabel: 'Tags',
            releaseDateLabel: 'Release',
            salesCountLabel: 'Sales',
            ratingLabel: 'Rating',
            onPlay: () {},
            playTooltip: 'add',
            loading: loading,
            coverBuilder: (coverWidth) => SizedBox(
              key: coverKey,
              width: coverWidth,
              height: coverWidth / LibraryLikeCardMetrics.coverAspectRatio,
            ),
          ),
        );
      }

      await tester.pumpWidget(buildCard(loading: true));
      expect(
        tester.getSize(find.byType(LibraryLikeWorkCardContent)).height,
        LibraryLikeCardMetrics.compactContentHeight,
      );

      await tester.pumpWidget(buildCard(loading: false));
      expect(
        tester.getSize(find.byType(LibraryLikeWorkCardContent)).height,
        LibraryLikeCardMetrics.compactContentHeight,
      );
    },
  );

  testWidgets('library-like skeleton cards blend into the page surface', (
    tester,
  ) async {
    await tester.pumpWidget(_buildSurface(const LibraryLikeSkeletonCard()));

    final card = tester.widget<Card>(find.byType(Card));
    expect(card.color, Colors.transparent);
    expect(card.elevation, 0);
    expect(card.shadowColor, Colors.transparent);
    expect(card.surfaceTintColor, Colors.transparent);
    expect((card.shape as RoundedRectangleBorder).side, BorderSide.none);
  });

  testWidgets(
    'compact library-like skeleton matches the compact cover card layout',
    (tester) async {
      const coverKey = ValueKey('compact-skeleton-cover');

      await tester.pumpWidget(
        _buildSurface(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const LibraryLikeSkeletonCard(compactCoverLayout: true),
              ListTile(
                minTileHeight: LibraryLikeCardMetrics.compactRootTileHeight,
                contentPadding: LibraryLikeCardMetrics.rootTilePadding,
                title: _buildFeaturedCard(
                  title: 'Work',
                  coverKey: coverKey,
                  lines: const <LibraryLikeInfoLineData>[],
                  compactCoverLayout: true,
                ),
              ),
            ],
          ),
        ),
      );

      final skeletonCover = find.byWidgetPredicate(
        (widget) =>
            widget is ShimmerContainer &&
            widget.width ==
                LibraryLikeCardMetrics.compactContentHeight *
                    LibraryLikeCardMetrics.coverAspectRatio &&
            widget.height == LibraryLikeCardMetrics.compactContentHeight,
      );
      final skeletonAdd = find.byWidgetPredicate(
        (widget) =>
            widget is ShimmerContainer &&
            widget.width == 25 &&
            widget.height == 25,
      );
      final skeletonExpand = find.byWidgetPredicate(
        (widget) =>
            widget is ShimmerContainer &&
            widget.width == 16 &&
            widget.height == 16,
      );

      expect(
        tester.getSize(find.byType(Card)),
        const Size(360, LibraryLikeCardMetrics.compactRootTileHeight),
      );
      expect(skeletonCover, findsOneWidget);
      expect(
        tester.getSize(skeletonCover),
        const Size(
          LibraryLikeCardMetrics.compactContentHeight *
              LibraryLikeCardMetrics.coverAspectRatio,
          LibraryLikeCardMetrics.compactContentHeight,
        ),
      );
      final cardRect = tester.getRect(find.byType(Card));
      final tileRect = tester.getRect(find.byType(ListTile));
      final actualAdd = find.byIcon(Icons.add_circle_rounded);
      final actualExpand = find.byIcon(Icons.expand_more_rounded);

      expect(
        tester.getCenter(skeletonAdd).dx - tester.getCenter(actualAdd).dx,
        closeTo(0, 0.1),
      );
      expect(
        tester.getCenter(skeletonExpand).dx - tester.getCenter(actualExpand).dx,
        closeTo(0, 0.1),
      );

      final skeletonAddRelativeY =
          tester.getCenter(skeletonAdd).dy - cardRect.top;
      final actualAddRelativeY = tester.getCenter(actualAdd).dy - tileRect.top;
      final skeletonExpandRelativeY =
          tester.getCenter(skeletonExpand).dy - cardRect.top;
      final actualExpandRelativeY =
          tester.getCenter(actualExpand).dy - tileRect.top;

      expect(skeletonAddRelativeY, closeTo(actualAddRelativeY, 0.1));
      expect(skeletonExpandRelativeY, closeTo(actualExpandRelativeY, 0.1));
    },
  );

  testWidgets(
    'library-like skeleton actions align with rendered card actions',
    (tester) async {
      const coverKey = ValueKey('alignment-cover');

      await tester.pumpWidget(
        _buildSurface(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const LibraryLikeSkeletonCard(),
              ExpansionTile(
                minTileHeight: LibraryLikeCardMetrics.rootTileHeight,
                showTrailingIcon: false,
                tilePadding: LibraryLikeCardMetrics.rootTilePadding,
                title: _buildFeaturedCard(
                  title: 'Work',
                  coverKey: coverKey,
                  lines: const <LibraryLikeInfoLineData>[],
                ),
              ),
            ],
          ),
        ),
      );

      final skeletonAdd = find.byWidgetPredicate(
        (widget) =>
            widget is ShimmerContainer &&
            widget.width == 25 &&
            widget.height == 25,
      );
      final skeletonExpand = find.byWidgetPredicate(
        (widget) =>
            widget is ShimmerContainer &&
            widget.width == 16 &&
            widget.height == 16,
      );

      expect(skeletonAdd, findsOneWidget);
      expect(skeletonExpand, findsOneWidget);
      final addDelta =
          tester.getCenter(skeletonAdd).dx -
          tester.getCenter(find.byIcon(Icons.add_circle_rounded)).dx;
      final expandDelta =
          tester.getCenter(skeletonExpand).dx -
          tester.getCenter(find.byIcon(Icons.expand_more_rounded)).dx;
      expect(<double>[addDelta, expandDelta], everyElement(closeTo(0, 0.1)));
    },
  );

  testWidgets('library-like card content keeps compact equal edge insets', (
    tester,
  ) async {
    const tileKey = ValueKey('library-like-tile');
    const coverKey = ValueKey('library-like-cover');

    await tester.pumpWidget(
      _buildSurface(
        ListTile(
          key: tileKey,
          contentPadding: LibraryLikeCardMetrics.rootTilePadding,
          minTileHeight: LibraryLikeCardMetrics.rootTileHeight,
          title: _buildFeaturedCard(
            title: 'Work',
            coverKey: coverKey,
            lines: const <LibraryLikeInfoLineData>[],
          ),
        ),
      ),
    );

    final tileRect = tester.getRect(find.byKey(tileKey));
    final contentRect = tester.getRect(find.byType(LibraryLikeWorkCardContent));
    final topInset = contentRect.top - tileRect.top;
    final bottomInset = tileRect.bottom - contentRect.bottom;
    final leftInset = contentRect.left - tileRect.left;
    final rightInset = tileRect.right - contentRect.right;

    expect(topInset, AppSpacing.xs);
    expect(bottomInset, AppSpacing.xs);
    expect(leftInset, AppSpacing.xs);
    expect(rightInset, AppSpacing.xs);
  });

  testWidgets('ASMR-style cards reuse static Android list rhythm', (
    tester,
  ) async {
    const coverKey = ValueKey('asmr-cover');
    const title = '#羊娘めめ 20260326 nico【限定ASMR｜睡眠導入】ゆっくりはむちゅ';

    await tester.pumpWidget(
      _buildSurface(
        _buildFeaturedCard(
          title: title,
          coverKey: coverKey,
          lines: const [
            LibraryLikeInfoLineData('RJ', 'RJ01577349'),
            LibraryLikeInfoLineData('CV', '未想可みいろ'),
            LibraryLikeInfoLineData('社团', 'あまとうむし'),
            LibraryLikeInfoLineData('标签', '耳舐め，ASMR', lines: 2),
          ],
        ),
      ),
    );

    expect(tester.getSize(find.byKey(coverKey)).width, 120);
    expect(
      tester.getSize(find.byKey(coverKey)).height,
      120 / kStandardCoverAspectRatio,
    );
    expect(find.byType(MarqueeText), findsNothing);

    final titleText = tester.widget<Text>(find.text(title));
    expect(titleText.maxLines, 2);
    expect(titleText.overflow, TextOverflow.ellipsis);
  });

  testWidgets('short tag values do not reserve empty configured rows', (
    tester,
  ) async {
    const style = TextStyle(fontSize: 10, height: 1.6);

    await tester.pumpWidget(
      _buildSurface(
        const LibraryLikeDetailInfoLine(
          label: '标签',
          text: '耳舐め，ASMR',
          style: style,
          loading: false,
          lines: 4,
          enableMarquee: false,
        ),
      ),
    );

    expect(find.byType(MarqueeText), findsNothing);
    expect(tester.getSize(find.byType(LibraryLikeDetailInfoLine)).height, 16);
    final valueText = tester.widget<Text>(find.text('耳舐め，ASMR'));
    expect(valueText.maxLines, 4);
    expect(valueText.overflow, TextOverflow.ellipsis);
  });

  testWidgets(
    'single audio card keeps info line vertical spacing consistent with with-cover cards',
    (tester) async {
      await tester.pumpWidget(
        _buildSurface(
          const LibraryLikeSingleAudioCardContent(
            title: 'Track Title',
            lines: [
              LibraryLikeInfoLineData('CV', '圣纯シオ'),
              LibraryLikeInfoLineData('社团', 'えたーなるわーくす'),
              LibraryLikeInfoLineData('销量', '2070'),
            ],
            enableMarquee: false,
            enableTitleMarquee: false,
          ),
        ),
      );

      final titleRect = tester.getRect(find.text('Track Title'));
      final cvRect = tester.getRect(find.text('CV'));
      final circleRect = tester.getRect(find.text('社团'));
      final salesRect = tester.getRect(find.text('销量'));

      // 4px spacing between title and info block
      expect(cvRect.top - titleRect.bottom, closeTo(4.0, 0.5));

      // 0 gap between consecutive info lines (each line is 16px high)
      expect(circleRect.top - cvRect.top, 16.0);
      expect(salesRect.top - circleRect.top, 16.0);
    },
  );

  test('settings, feedback, and recovery labels stay available', () {
    for (final table in [appLanguageZh, appLanguageEn]) {
      for (final key in [
        'section_common',
        'section_appearance',
        'section_playback',
        'section_data_storage',
        'section_updates_permissions',
        'no_audio_files',
        'no_search_results',
        'batch_metadata_load_failed',
        'dlsite_fetch_failed',
        'import_audio',
        'retry',
        'cancel',
        'export_diagnostics',
        'check_updates',
        'open_release_page',
      ]) {
        expect(
          table[key],
          isA<String>().having((value) => value.trim(), key, isNotEmpty),
          reason: key,
        );
      }
    }
  });
}
