import 'dart:async';

import 'package:flutter/material.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/core/widgets/search_highlight.dart';
import 'package:doujin_audio/core/widgets/rj_code_overlay.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_en.dart';
import 'package:doujin_audio/app/localization/app_language_ja.dart';
import 'package:doujin_audio/app/localization/app_language_zh.dart';
import 'package:doujin_audio/app/theme/app_styles.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/widgets/library_like_cards.dart';
import 'package:doujin_audio/core/widgets/marquee_text.dart';
import 'package:doujin_audio/core/widgets/operation_feedback.dart';
import 'package:doujin_audio/core/widgets/scroll_activity_gate.dart';
import 'package:doujin_audio/core/widgets/shimmer_loading.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/library/presentation/library_card_artwork.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_tree_widgets.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_list_view.dart';

import 'support/app_runtime_test_fixture.dart';

Widget _buildSurface(Widget child) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  home: Scaffold(
    body: Center(child: SizedBox(width: 360, child: child)),
  ),
);

Widget _buildScrollableHeader() {
  return ProviderScope(
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

Widget _buildPageAppBar() {
  return const ProviderScope(
    child: MaterialApp(
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
  Widget? trailingActions,
}) {
  return LibraryLikeWorkCardContent(
    title: title,
    lines: lines,
    trailingActions: trailingActions,
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
  testWidgets('RJ search highlights inherit and clear with the query', (
    tester,
  ) async {
    Future<void> pumpCode(String query) => tester.pumpWidget(
      _buildSurface(
        SearchHighlightScope(
          query: query,
          child: const RjCodeOverlay(rjCode: 'RJ123456', maxWidth: 90),
        ),
      ),
    );

    await pumpCode('rj123');
    final richText = tester.widget<RichText>(
      find.descendant(
        of: find.byType(RjCodeOverlay),
        matching: find.byType(RichText),
      ),
    );
    final spans = (richText.text as TextSpan).children!.cast<TextSpan>();
    expect(
      spans
          .where((span) => span.style?.fontWeight == FontWeight.w900)
          .single
          .text,
      'RJ123',
    );
    expect(richText.text.toPlainText(), 'RJ123456');
    await pumpCode('');
    expect(find.text('RJ123456'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('nested search rows inherit category terms on $platform', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final track = testMusicTrack(
        name: 'Rain audio',
        path: '/library/Rain folder/audio.mp3',
        groupKey: '/library',
        groupTitle: 'Library',
      );
      final folder = FolderNode('Rain folder', '/library/Rain folder', depth: 1)
        ..addChildren([TrackNode(track)]);
      await tester.pumpWidget(
        fixture.build(
          SearchHighlightScope(
            query: 'rain',
            child: LibraryTreeItem(node: folder),
          ),
        ),
      );
      await tester.pumpAndSettle();
      bool hasHighlightedRain(String text) {
        final richText = tester.widget<RichText>(
          find.text(text, findRichText: true),
        );
        final spans = (richText.text as TextSpan).children!.cast<TextSpan>();
        return spans.any(
          (span) =>
              span.text == 'Rain' && span.style?.fontWeight == FontWeight.w900,
        );
      }

      expect(hasHighlightedRain('Rain folder'), isTrue);
      await tester.tap(find.text('Rain folder', findRichText: true));
      await tester.pumpAndSettle();
      expect(hasHighlightedRain('Rain audio'), isTrue);
      await tester.tap(find.text('Rain folder', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.text('Rain audio', findRichText: true), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('top header stays opaque while scrolling', (tester) async {
    await tester.pumpWidget(_buildScrollableHeader());
    await tester.pump();

    expect(find.byType(BackdropFilter), findsNothing);

    await tester.drag(
      find.byKey(const ValueKey('header_scroll_list')),
      const Offset(0, -240),
    );
    await tester.pump(const Duration(milliseconds: 170));

    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('secondary page app bar has no backdrop blur', (tester) async {
    await tester.pumpWidget(_buildPageAppBar());
    await tester.pump();

    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('placeholder content fades over the shared 450ms duration', (
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
      const Duration(milliseconds: 450),
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

    await tester.pump(const Duration(milliseconds: 225));
    final midpointOpacities = tester
        .widgetList<FadeTransition>(fadeFinder)
        .map((fade) => fade.opacity.value)
        .toList(growable: false);
    expect(midpointOpacities, hasLength(2));
    expect(midpointOpacities[0], inInclusiveRange(0.3, 0.7));
    expect(midpointOpacities[1], inInclusiveRange(0.3, 0.7));
    expect(midpointOpacities[0] + midpointOpacities[1], closeTo(1, 0.001));

    await tester.pump(const Duration(milliseconds: 224));
    expect(find.byKey(const ValueKey('placeholder')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1));
    expect(
      tester.widgetList<FadeTransition>(fadeFinder).last.opacity.value,
      closeTo(1, 0.001),
    );
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.byKey(const ValueKey('placeholder')), findsNothing);
    expect(find.byKey(contentKey), findsOneWidget);

    update(() => showPlaceholder = true);
    await tester.pump();
    update(() => showPlaceholder = false);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
  });

  testWidgets('inline loading can restart, skip motion and dispose mid-fade', (
    tester,
  ) async {
    var loading = true;
    var reducedMotion = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: reducedMotion),
              child: Column(
                children: [
                  PlaceholderContentTransition(
                    fit: StackFit.loose,
                    showPlaceholder: loading,
                    placeholder: const SizedBox(
                      key: ValueKey('inline_loading'),
                      height: 40,
                    ),
                    content: const SizedBox(
                      key: ValueKey('inline_data'),
                      height: 80,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    update(() => loading = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      tester.getSize(find.byType(PlaceholderContentTransition)).height,
      80,
    );
    update(() => loading = true);
    await tester.pump();
    expect(find.byKey(const ValueKey('inline_data')), findsNothing);
    update(() {
      reducedMotion = true;
      loading = false;
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('inline_loading')), findsNothing);
    expect(find.byKey(const ValueKey('inline_data')), findsOneWidget);
    update(() {
      reducedMotion = false;
      loading = true;
    });
    await tester.pump();
    update(() => loading = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('covered loading completes without replay on return', (
    tester,
  ) async {
    var loading = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return PlaceholderContentTransition(
              showPlaceholder: loading,
              placeholder: const SizedBox(key: ValueKey('covered_loading')),
              content: const SizedBox(key: ValueKey('covered_data')),
            );
          },
        ),
      ),
    );
    final navigator = Navigator.of(
      tester.element(find.byType(PlaceholderContentTransition)),
    );
    for (final completeWhileCovered in [true, false]) {
      update(() => loading = true);
      await tester.pump();
      if (!completeWhileCovered) {
        update(() => loading = false);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
      }
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Covering page')),
          ),
        ),
      );
      await tester.pump();
      if (completeWhileCovered) {
        update(() => loading = false);
        await tester.pump();
      }
      expect(
        find.byKey(const ValueKey('covered_loading'), skipOffstage: false),
        findsNothing,
      );
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('covered_data')), findsOneWidget);
      expect(
        tester
            .widget<FadeTransition>(
              find.descendant(
                of: find.byType(PlaceholderContentTransition),
                matching: find.byType(FadeTransition),
              ),
            )
            .opacity
            .value,
        1,
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
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
      metadata: LibraryLikeInfoMetadata(
        voiceActors: detail.voiceActors,
        circleName: detail.circleName,
        tags: detail.tags,
        releaseDate: detail.releaseDate,
        rating: detail.rating,
      ),
      voiceActorLabel: appLanguageZh['card_info_voice_actors']!,
      circleLabel: 'Circle',
      tagsLabel: 'Tags',
      releaseDateLabel: 'Release',
      ratingLabel: 'Rating',
    );

    expect(
      lines.map(
        (line) =>
            '${line.label}:${line.text}:${line.lines}:${line.isSecondary}',
      ),
      <String>[
        '声优:Alice，Bob:1:false',
        'Circle:Circle:1:false',
        'Tags:#sleep #voice:1:false',
        'Release:2026-07-02:1:true',
        'Rating:4:1:true',
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
      metadata: LibraryLikeInfoMetadata(
        voiceActors: work.voiceActors,
        circleName: work.circleName,
        tags: work.tags,
        releaseDate: work.releaseDate,
        rating: work.rating,
      ),
      voiceActorLabel: appLanguageJa['card_info_voice_actors']!,
      circleLabel: 'Circle',
      tagsLabel: 'Tags',
      releaseDateLabel: 'Release',
      ratingLabel: 'Rating',
      listSeparator: '、',
    );

    expect(
      lines.map(
        (line) =>
            '${line.label}:${line.text}:${line.lines}:${line.isSecondary}',
      ),
      <String>[
        '声優:Voice A、Voice B:1:false',
        'Circle:Circle:1:false',
        'Tags:#ASMR #Sleep:1:false',
        'Release:2026-06-09:1:true',
        'Rating:4.5:1:true',
      ],
    );
  });

  testWidgets('five metadata lines fit the fixed work card info block', (
    tester,
  ) async {
    final lines = buildLibraryLikeInfoLines(
      metadata: LibraryLikeInfoMetadata(
        voiceActors: const ['Voice'],
        circleName: 'Circle',
        tags: List.generate(30, (index) => 'A long tag $index'),
        releaseDate: DateTime(2026, 6, 9),
        rating: 4.5,
      ),
      voiceActorLabel: 'Voice',
      circleLabel: 'Circle',
      tagsLabel: 'Tags',
      releaseDateLabel: 'Release',
      ratingLabel: 'Rating',
    );
    await tester.pumpWidget(
      _buildSurface(
        _buildFeaturedCard(
          title: 'Work',
          lines: lines,
          coverKey: const ValueKey('five-line-cover'),
        ),
      ),
    );
    expect(lines.fold<int>(0, (total, line) => total + line.lines), 5);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'card title and metadata stay on the right with muted footer',
    (tester) async {
      final lines = buildLibraryLikeInfoLines(
        metadata: LibraryLikeInfoMetadata(
          voiceActors: const ['Voice'],
          circleName: 'Circle',
          tags: const ['ASMR', 'Sleep'],
          releaseDate: DateTime(2026, 6, 9),
          rating: 4.5,
        ),
        voiceActorLabel: 'Voice label',
        circleLabel: 'Circle label',
        tagsLabel: 'Tags',
        releaseDateLabel: 'Release',
        ratingLabel: 'Rating',
      );
      await tester.pumpWidget(
        _buildSurface(
          _buildFeaturedCard(
            title: 'Work',
            coverKey: const ValueKey('footer-info-cover'),
            lines: lines,
          ),
        ),
      );
      expect(
        lines.where((line) => line.isSecondary).map((line) => line.label),
        ['Release', 'Rating'],
      );
      for (final icon in [
        Icons.record_voice_over_rounded,
        Icons.storefront_outlined,
        Icons.local_offer_rounded,
        Icons.calendar_today_rounded,
        Icons.star_rounded,
      ]) {
        expect(find.byIcon(icon), findsOneWidget);
      }
      for (final label in [
        'Voice label',
        'Circle label',
        'Tags',
        'Release',
        'Rating',
      ]) {
        expect(find.text(label), findsNothing);
        expect(find.byTooltip(label), findsOneWidget);
      }
      final cover = tester.getRect(
        find.byKey(const ValueKey('footer-info-cover')),
      );
      final title = tester.getRect(find.text('Work'));
      final date = tester.getRect(find.text('2026-06-09'));
      final rating = tester.getRect(find.text('4.5'));
      expect(title.top, cover.top);
      expect(title.left, cover.right + 10);
      expect(date.left, greaterThan(cover.right));
      expect(date.bottom, closeTo(cover.bottom, 0.001));
      for (final value in [
        'Work',
        'Voice',
        'Circle',
        '#ASMR #Sleep',
        '2026-06-09',
        '4.5',
      ]) {
        final rect = tester.getRect(find.text(value));
        expect(rect.left, greaterThan(cover.right));
        expect(rect.top, greaterThanOrEqualTo(cover.top));
        expect(rect.bottom, lessThanOrEqualTo(cover.bottom + 0.001));
      }
      expect(
        date.top,
        greaterThan(tester.getRect(find.text('#ASMR #Sleep')).top),
      );
      expect(rating.center.dy, closeTo(date.center.dy, 0.001));
      expect(rating.left, greaterThan(date.right));
      final titleText = tester.widget<Text>(find.text('Work'));
      expect(titleText.maxLines, 1);
      final dateStyle = tester.widget<Text>(find.text('2026-06-09')).style!;
      final ratingStyle = tester.widget<Text>(find.text('4.5')).style!;
      final voiceStyle = tester.widget<Text>(find.text('Voice')).style!;
      expect(dateStyle.fontSize, 11);
      expect(ratingStyle.fontSize, 11);
      expect(dateStyle.color, ratingStyle.color);
      expect(dateStyle.color, isNot(voiceStyle.color));
      expect(find.byType(IconButton), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'card actions fit after rating and consume taps at text scale $scale',
      (tester) async {
        var additions = 0;
        var plays = 0;
        var outerTaps = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: SizedBox(
                    width: 320,
                    child: InkWell(
                      onTap: () => outerTaps++,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: _buildFeaturedCard(
                          title: 'A long work title in a small card',
                          coverKey: const ValueKey('actions-cover'),
                          lines: const [
                            LibraryLikeInfoLineData(
                              'Voice',
                              'Actor',
                              icon: Icons.record_voice_over_rounded,
                            ),
                            LibraryLikeInfoLineData(
                              'Date',
                              '2026-10-09',
                              icon: Icons.calendar_today_rounded,
                              isSecondary: true,
                            ),
                            LibraryLikeInfoLineData(
                              'Rating',
                              '4.5',
                              icon: Icons.star_rounded,
                              isSecondary: true,
                            ),
                          ],
                          trailingActions: LibraryLikeCardActions(
                            addLabel: 'Add',
                            playLabel: 'Play',
                            onAdd: () => additions++,
                            onPlay: () => plays++,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final content = tester.getRect(find.byType(LibraryLikeWorkCardContent));
        final cover = tester.getRect(
          find.byKey(const ValueKey('actions-cover')),
        );
        final add = tester.getRect(
          find.widgetWithIcon(IconButton, Icons.add_circle_rounded),
        );
        final play = tester.getRect(
          find.widgetWithIcon(IconButton, Icons.play_arrow_rounded),
        );
        final rating = tester.getRect(find.text('4.5'));
        expect(find.text('Add'), findsNothing);
        expect(find.text('Play'), findsNothing);
        expect(find.byTooltip('Add'), findsOneWidget);
        expect(find.byTooltip('Play'), findsOneWidget);
        expect(content.height, 90);
        expect(cover.height, 90);
        expect(add.height, 18);
        expect(play.height, 18);
        expect(
          tester.getSize(find.byIcon(Icons.add_circle_rounded)),
          const Size(18, 18),
        );
        expect(
          tester.getSize(find.byIcon(Icons.play_arrow_rounded)),
          const Size(18, 18),
        );
        expect(add.left, greaterThanOrEqualTo(rating.right));
        expect(play.left, greaterThanOrEqualTo(add.right));
        expect(play.right, lessThanOrEqualTo(content.right + 0.001));
        expect(play.bottom, lessThanOrEqualTo(content.bottom + 0.001));
        expect(add.center.dy, closeTo(play.center.dy, 0.001));
        expect(add.center.dy, closeTo(rating.center.dy, 0.001));
        await tester.tap(
          find.widgetWithIcon(IconButton, Icons.add_circle_rounded),
        );
        await tester.tap(
          find.widgetWithIcon(IconButton, Icons.play_arrow_rounded),
        );
        await tester.pump();
        expect(additions, 1);
        expect(plays, 1);
        expect(outerTaps, 0);
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets('card actions disable unavailable callbacks', (tester) async {
    await tester.pumpWidget(
      _buildSurface(
        const LibraryLikeCardActions(addLabel: 'Add', playLabel: 'Play'),
      ),
    );
    final buttons = tester.widgetList<IconButton>(find.byType(IconButton));
    expect(buttons, hasLength(2));
    expect(buttons.map((button) => button.onPressed), everyElement(isNull));
  });

  testWidgets('library card retains cover dimensions without action buttons', (
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
            LibraryLikeInfoLineData(
              'CV',
              '聖純シオ',
              icon: Icons.record_voice_over_rounded,
            ),
            LibraryLikeInfoLineData(
              '社团',
              'えたーなるわーくす',
              icon: Icons.storefront_outlined,
            ),
            LibraryLikeInfoLineData(
              '标签',
              '搾乳，産卵，百合，触手，双子，丸呑み，バイノーラル',
              icon: Icons.local_offer_rounded,
            ),
            LibraryLikeInfoLineData(
              '发售',
              '2026-10-09',
              icon: Icons.calendar_today_rounded,
              isSecondary: true,
            ),
            LibraryLikeInfoLineData(
              '评分',
              '4.5',
              icon: Icons.star_rounded,
              isSecondary: true,
            ),
          ],
        ),
      ),
    );

    expect(LibraryLikeCardMetrics.rootTileHeight, 106);
    expect(
      LibraryLikeCardMetrics.contentHeight,
      LibraryLikeCardMetrics.coverHeight,
    );
    expect(LibraryLikeCardMetrics.coverRadius, 8);
    expect(LibraryLikeCardMetrics.coverDistance, 8);
    expect(
      LibraryLikeCardMetrics.cardRadius,
      LibraryLikeCardMetrics.coverRadius + LibraryLikeCardMetrics.coverDistance,
    );
    expect(LibraryLikeCardMetrics.coverAspectRatio, kStandardCoverAspectRatio);

    expect(
      tester.getSize(find.byType(LibraryLikeWorkCardContent)),
      const Size(360, LibraryLikeCardMetrics.contentHeight),
    );
    expect(
      tester.getSize(find.byKey(coverKey)),
      const Size(
        LibraryLikeCardMetrics.coverHeight *
            LibraryLikeCardMetrics.coverAspectRatio,
        LibraryLikeCardMetrics.coverHeight,
      ),
    );
    expect(
      tester.getTopLeft(find.text('聖純シオ')).dy,
      greaterThan(tester.getTopLeft(find.byKey(coverKey)).dy),
    );
    expect(find.byType(MarqueeText), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    final titleText = tester.widget<Text>(find.text(title));
    expect(titleText.maxLines, 1);
    expect(titleText.overflow, TextOverflow.visible);
    expect(titleText.softWrap, isFalse);
  });

  testWidgets('metadata card keeps the full layout while the cover loads', (
    tester,
  ) async {
    const coverKey = ValueKey('metadata-compact-cover');

    Widget buildCard({required bool loading}) {
      return _buildSurface(
        LibraryLikeMetadataWorkCardContent(
          title: 'Work',
          metadata: const LibraryLikeInfoMetadata(),
          voiceActorLabel: appLanguageEn['card_info_voice_actors']!,
          circleLabel: 'Circle',
          tagsLabel: 'Tags',
          releaseDateLabel: 'Release',
          ratingLabel: 'Rating',
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
      LibraryLikeCardMetrics.contentHeight,
    );

    await tester.pumpWidget(buildCard(loading: false));
    expect(
      tester.getSize(find.byType(LibraryLikeWorkCardContent)).height,
      LibraryLikeCardMetrics.contentHeight,
    );
  });

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

  testWidgets('library-like skeleton keeps all text beside the cover', (
    tester,
  ) async {
    await tester.pumpWidget(_buildSurface(const LibraryLikeSkeletonCard()));
    final cover = tester.getRect(
      find.byWidgetPredicate(
        (widget) =>
            widget is ShimmerContainer &&
            widget.height == LibraryLikeCardMetrics.coverHeight,
      ),
    );
    final smallShimmers = find.byWidgetPredicate(
      (widget) =>
          widget is ShimmerContainer &&
          (widget.height == 11 || widget.height == 9),
    );
    expect(smallShimmers, findsWidgets);
    for (var index = 0; index < smallShimmers.evaluate().length; index++) {
      final rect = tester.getRect(smallShimmers.at(index));
      expect(rect.left, greaterThan(cover.right));
      expect(rect.bottom, lessThanOrEqualTo(cover.bottom + 0.001));
    }
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is ShimmerContainer &&
            widget.width == 25 &&
            widget.height == 25,
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  for (final count in [1, 5]) {
    testWidgets(
      'library skeleton fills and resizes viewport with itemCount $count',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 1200);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LibrarySkeletonListView(
                topInset: 64,
                bottomInset: 24,
                itemCount: count,
              ),
            ),
          ),
        );
        for (final size in [const Size(390, 1200), const Size(1280, 1000)]) {
          tester.view.physicalSize = size;
          await tester.pump();
          final cards = find.byType(LibraryLikeSkeletonCard);
          final first = tester.getRect(cards.first);
          final last = tester.getRect(cards.last);
          expect(first.top, 64);
          expect(last.bottom, greaterThanOrEqualTo(size.height - 24));
          expect(cards.evaluate().length, greaterThan(count));
          final second = tester.getRect(cards.at(1));
          if (size.width == 390) {
            expect(second.left, first.left);
            expect(second.top, first.bottom);
          } else {
            expect(second.top, first.top);
            expect(second.left, greaterThan(first.right));
          }
          final list = find.descendant(
            of: find.byType(LibrarySkeletonListView),
            matching: find.byType(ListView),
          );
          expect(
            tester.widget<ListView>(list).physics,
            isA<NeverScrollableScrollPhysics>(),
          );
          final position = tester
              .state<ScrollableState>(
                find.descendant(of: list, matching: find.byType(Scrollable)),
              )
              .position;
          await tester.drag(list, const Offset(0, -250));
          await tester.pump(const Duration(milliseconds: 200));
          expect(position.pixels, 0);
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  for (final showHeader in [false, true]) {
    testWidgets(
      'operation skeleton fills bounded viewport with header $showHeader',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 1200);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: OperationSkeletonList(
                itemCount: 1,
                showHeader: showHeader,
                padding: const EdgeInsets.fromLTRB(12, 16, 12, 24),
              ),
            ),
          ),
        );
        final rows = find.byWidgetPredicate(
          (widget) =>
              widget is Container &&
              widget.constraints?.minHeight == 58 &&
              widget.constraints?.maxHeight == 58,
        );
        for (final size in [const Size(390, 1200), const Size(1280, 1000)]) {
          tester.view.physicalSize = size;
          await tester.pump();
          final first = tester.getRect(rows.first);
          final last = tester.getRect(rows.last);
          expect(first.top, 16 + (showHeader ? 66 : 0));
          expect(first.left, 12);
          expect(first.width, size.width - 24);
          expect(last.bottom, greaterThanOrEqualTo(size.height - 24 - 10));
          expect(rows.evaluate().length, greaterThan(1));
          expect(tester.getRect(rows.at(1)).top - first.top, 68);
          final list = find.descendant(
            of: find.byType(OperationSkeletonList),
            matching: find.byType(ListView),
          );
          expect(
            tester.widget<ListView>(list).physics,
            isA<NeverScrollableScrollPhysics>(),
          );
          final position = tester
              .state<ScrollableState>(
                find.descendant(of: list, matching: find.byType(Scrollable)),
              )
              .position;
          await tester.drag(list, const Offset(0, -250));
          await tester.pump(const Duration(milliseconds: 200));
          expect(position.pixels, 0);
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets('operation skeleton fills the screen when height is unbounded', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: OperationSkeletonList(itemCount: 2, showHeader: false),
          ),
        ),
      ),
    );
    final rows = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.constraints?.minHeight == 58 &&
          widget.constraints?.maxHeight == 58,
    );
    expect(rows, findsAtLeastNWidgets(9));
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.shrinkWrap, isTrue);
    expect(list.physics, isA<NeverScrollableScrollPhysics>());
    expect(
      tester.getSize(find.byType(OperationSkeletonList)).height,
      greaterThanOrEqualTo(600),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'playlist skeleton fills visible area and resizes without scrolling',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PlaylistLoadingSkeleton(topPadding: 64, bottomPadding: 24),
          ),
        ),
      );
      final rows = find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'playlist_skeleton_card_',
            ),
      );
      for (final size in [const Size(390, 1200), const Size(1280, 1000)]) {
        tester.view.physicalSize = size;
        await tester.pump();
        expect(tester.getRect(rows.first).top, 64);
        expect(
          tester.getRect(rows.last).bottom,
          greaterThanOrEqualTo(size.height - 24),
        );
        final list = find.byType(ListView);
        expect(
          tester.widget<ListView>(list).physics,
          isA<NeverScrollableScrollPhysics>(),
        );
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position;
        await tester.drag(list, const Offset(0, -250));
        await tester.pump(const Duration(milliseconds: 200));
        expect(position.pixels, 0);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('card keeps symmetric edge insets and a single title row', (
    tester,
  ) async {
    const tileKey = ValueKey('library-like-tile');
    await tester.pumpWidget(
      _buildSurface(
        ListTile(
          key: tileKey,
          contentPadding: LibraryLikeCardMetrics.rootTilePadding,
          minTileHeight: LibraryLikeCardMetrics.rootTileHeight,
          title: _buildFeaturedCard(
            title: 'Work',
            coverKey: const ValueKey('library-like-cover'),
            lines: const [
              LibraryLikeInfoLineData(
                'CV',
                'Actor',
                icon: Icons.record_voice_over_rounded,
              ),
              LibraryLikeInfoLineData(
                'Circle label',
                'Circle',
                icon: Icons.storefront_outlined,
              ),
              LibraryLikeInfoLineData(
                'Tags',
                '#ASMR #Sleep',
                icon: Icons.local_offer_rounded,
              ),
              LibraryLikeInfoLineData(
                'Release',
                '2026-10-09',
                icon: Icons.calendar_today_rounded,
                isSecondary: true,
              ),
              LibraryLikeInfoLineData(
                'Rating',
                '4.5',
                icon: Icons.star_rounded,
                isSecondary: true,
              ),
            ],
          ),
        ),
      ),
    );
    final tile = tester.getRect(find.byKey(tileKey));
    final content = tester.getRect(find.byType(LibraryLikeWorkCardContent));
    expect(content.top - tile.top, AppSpacing.xs);
    expect(tile.bottom - content.bottom, AppSpacing.xs);
    expect(content.left - tile.left, AppSpacing.xs);
    expect(tile.right - content.right, AppSpacing.xs);
    final title = tester.getRect(
      find.byWidgetPredicate(
        (widget) =>
            widget is LibraryLikeScrollableText && widget.text == 'Work',
      ),
    );
    expect(title.top, content.top);
    expect(
      title.height,
      lessThanOrEqualTo(LibraryLikeCardMetrics.contentHeight / 5),
    );
    expect(tester.widget<Text>(find.text('Work')).maxLines, 1);
    final date = tester.getRect(find.text('2026-10-09'));
    final rating = tester.getRect(find.text('4.5'));
    expect(date.center.dy, closeTo(rating.center.dy, 0.001));
    expect(date.bottom, closeTo(content.bottom, 0.001));
    expect(
      date.bottom,
      greaterThan(content.bottom - LibraryLikeCardMetrics.contentHeight / 5),
    );
  });

  testWidgets(
    'card scales long metadata within its bounds at double text size',
    (tester) async {
      final lines = buildLibraryLikeInfoLines(
        metadata: LibraryLikeInfoMetadata(
          voiceActors: const ['A voice actor with a long name'],
          circleName: 'A circle with a long name',
          tags: const ['ASMR', 'Sleep', 'A long tag'],
          releaseDate: DateTime(2026, 10, 9),
          rating: 4.5,
        ),
        voiceActorLabel: 'Voice',
        circleLabel: 'Circle',
        tagsLabel: 'Tags',
        releaseDateLabel: 'Release',
        ratingLabel: 'Rating',
      );
      await tester.pumpWidget(
        _buildSurface(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: _buildFeaturedCard(
              title: 'A long work name that must remain on a single row',
              lines: lines,
              coverKey: const ValueKey('large-text-cover'),
            ),
          ),
        ),
      );
      final content = tester.getRect(find.byType(LibraryLikeWorkCardContent));
      final footer = tester.getRect(find.text('2026-10-09'));
      final cover = tester.getRect(
        find.byKey(const ValueKey('large-text-cover')),
      );
      expect(content.height, cover.height);
      expect(footer.bottom, lessThanOrEqualTo(cover.bottom + 0.001));
      expect(footer.left, greaterThan(content.left + 120));
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('ASMR-style cards show a single scrollable title', (
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
            LibraryLikeInfoLineData(
              'CV',
              '未想可みいろ',
              icon: Icons.record_voice_over_rounded,
            ),
            LibraryLikeInfoLineData(
              '社团',
              'あまとうむし',
              icon: Icons.storefront_outlined,
            ),
            LibraryLikeInfoLineData(
              '标签',
              '#耳舐め #ASMR',
              icon: Icons.local_offer_rounded,
            ),
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
    expect(titleText.maxLines, 1);
    expect(titleText.overflow, TextOverflow.visible);
  });

  testWidgets('short tag values do not reserve empty configured rows', (
    tester,
  ) async {
    const style = TextStyle(fontSize: 10, height: 1.6);

    await tester.pumpWidget(
      _buildSurface(
        const LibraryLikeDetailInfoLine(
          label: '标签',
          icon: Icons.local_offer_rounded,
          text: '耳舐め，ASMR',
          style: style,
          loading: false,
          lines: 4,
          enableMarquee: false,
        ),
      ),
    );

    expect(find.byType(MarqueeText), findsNothing);
    expect(
      tester.getSize(find.byType(LibraryLikeDetailInfoLine)).height,
      closeTo(LibraryLikeCardMetrics.contentHeight / 5, 0.001),
    );
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
              LibraryLikeInfoLineData(
                'CV',
                '圣纯シオ',
                icon: Icons.record_voice_over_rounded,
              ),
              LibraryLikeInfoLineData(
                '社团',
                'えたーなるわーくす',
                icon: Icons.storefront_outlined,
              ),
              LibraryLikeInfoLineData(
                '销量',
                '2070',
                icon: Icons.info_outline_rounded,
              ),
            ],
          ),
        ),
      );

      final titleRect = tester.getRect(find.text('Track Title'));
      final cvRect = tester.getRect(find.text('圣纯シオ'));
      final circleRect = tester.getRect(find.text('えたーなるわーくす'));
      final salesRect = tester.getRect(find.text('2070'));

      // 4px spacing between title and info block
      expect(cvRect.top - titleRect.bottom, closeTo(4.0, 0.5));

      expect(
        circleRect.top - cvRect.top,
        closeTo(LibraryLikeCardMetrics.contentHeight / 5, 0.001),
      );
      expect(
        salesRect.top - circleRect.top,
        closeTo(LibraryLikeCardMetrics.contentHeight / 5, 0.001),
      );
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

  testWidgets(
    'LibrarySelectionIndicator performs 450ms fade-in and fade-out with 22x22 cutout border',
    (tester) async {
      final checkmarkFinder = find.byKey(
        const ValueKey<String>('library_selection_indicator_lib-fade-test'),
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LibrarySelectionIndicator(
              path: 'lib-fade-test',
              isSelected: false,
            ),
          ),
        ),
      );

      expect(checkmarkFinder, findsNothing);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LibrarySelectionIndicator(path: 'lib-fade-test'),
          ),
        ),
      );

      await tester.pump();
      expect(checkmarkFinder, findsOneWidget);

      final switcherFinder = find.byType(AnimatedSwitcher);
      final switcher = tester.widget<AnimatedSwitcher>(switcherFinder);
      expect(switcher.duration, const Duration(milliseconds: 450));
      expect(switcher.reverseDuration, const Duration(milliseconds: 450));

      expect(tester.getSize(checkmarkFinder), const Size(22.0, 22.0));
      final container = tester.widget<Container>(checkmarkFinder);
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.shape, BoxShape.circle);
      expect(decoration.border?.top.width, 2.0);

      // Verify mid-animation opacity
      await tester.pump(const Duration(milliseconds: 225));
      final fadeFinder = find
          .ancestor(of: checkmarkFinder, matching: find.byType(FadeTransition))
          .first;
      final midOpacity = tester
          .widget<FadeTransition>(fadeFinder)
          .opacity
          .value;
      expect(midOpacity, greaterThan(0.0));
      expect(midOpacity, lessThan(1.0));

      // After remaining duration
      await tester.pump(const Duration(milliseconds: 225));
      final fullOpacity = tester
          .widget<FadeTransition>(fadeFinder)
          .opacity
          .value;
      expect(fullOpacity, closeTo(1.0, 0.001));

      // Deselect
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LibrarySelectionIndicator(
              path: 'lib-fade-test',
              isSelected: false,
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 225));
      expect(checkmarkFinder, findsOneWidget);

      await tester.pump(const Duration(milliseconds: 250));
      expect(checkmarkFinder, findsNothing);
    },
  );

  for (final kind in [
    'library',
    'library anonymous',
    'playlist',
    'library leading',
  ]) {
    Widget buildPinned(bool pinned, {bool disableAnimations = false}) {
      final indicator = switch (kind) {
        'library' => LibraryPinnedIndicator(path: 'fade-pin', isPinned: pinned),
        'library anonymous' => LibraryPinnedIndicator(isPinned: pinned),
        'playlist' => PlaylistPinnedIndicator(
          sessionId: 'fade-pin',
          isPinned: pinned,
        ),
        _ => LibraryLeadingIndicators(
          path: 'fade-pin',
          isSelected: false,
          isPinned: pinned,
        ),
      };
      return MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(disableAnimations: disableAnimations),
            child: SizedBox(height: 52, child: indicator),
          ),
        ),
      );
    }

    testWidgets('$kind pin fades in and out over 450ms', (tester) async {
      final pin = find.byIcon(Icons.push_pin_rounded);
      double opacity() => tester
          .widgetList<FadeTransition>(
            find.ancestor(of: pin, matching: find.byType(FadeTransition)),
          )
          .fold(1.0, (value, fade) => value * fade.opacity.value);

      await tester.pumpWidget(buildPinned(false));
      expect(pin, findsNothing);
      await tester.pumpWidget(buildPinned(true));
      await tester.pump();
      expect(opacity(), 0);
      await tester.pump(const Duration(milliseconds: 225));
      expect(opacity(), closeTo(0.5, 0.01));
      await tester.pump(const Duration(milliseconds: 225));
      expect(opacity(), 1);
      await tester.pump(const Duration(milliseconds: 1));

      await tester.pumpWidget(buildPinned(false));
      await tester.pump();
      expect(pin, findsOneWidget);
      expect(opacity(), 1);
      await tester.pump(const Duration(milliseconds: 225));
      expect(opacity(), closeTo(0.5, 0.01));
      await tester.pump(const Duration(milliseconds: 225));
      await tester.pump(const Duration(milliseconds: 1));
      expect(pin, findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$kind pin respects disabled animations', (tester) async {
      await tester.pumpWidget(buildPinned(false, disableAnimations: true));
      await tester.pumpWidget(buildPinned(true, disableAnimations: true));
      await tester.pump();
      expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
      await tester.pumpWidget(buildPinned(false, disableAnimations: true));
      await tester.pump();
      expect(find.byIcon(Icons.push_pin_rounded), findsNothing);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  }

  testWidgets(
    'LibraryPinnedIndicator renders 22x22 circle with cutout border and pin icon',
    (tester) async {
      final pinFinder = find.byKey(
        const ValueKey<String>('library_pinned_pin-test'),
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: LibraryPinnedIndicator(path: 'pin-test')),
        ),
      );

      expect(pinFinder, findsOneWidget);
      expect(tester.getSize(pinFinder), const Size(22.0, 22.0));
      final container = tester.widget<Container>(pinFinder);
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.shape, BoxShape.circle);
      expect(decoration.border?.top.width, 2.0);
      expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
    },
  );

  testWidgets(
    'SingleMediaFileCardContent places selection checkmark at bottom-left and pin at top-right',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);

      final track = MusicTrack(
        path: '/test/audio.mp3',
        displayName: 'audio.mp3',
        groupKey: '/test',
        groupTitle: 'test',
        groupSubtitle: '',
        isSingle: true,
      );

      await tester.pumpWidget(
        fixture.build(
          SingleMediaFileCardContent(
            track: track,
            title: 'audio.mp3',
            detail: null,
            detailLoading: false,
            isSelected: true,
            isPinned: true,
          ),
        ),
      );

      final selectionPosition = tester.widget<Positioned>(
        find
            .ancestor(
              of: find.byType(LibrarySelectionIndicator),
              matching: find.byType(Positioned),
            )
            .first,
      );
      expect(selectionPosition.left, -2);
      expect(selectionPosition.bottom, -2);
      expect(selectionPosition.top, isNull);

      final pinPosition = tester.widget<Positioned>(
        find
            .ancestor(
              of: find.byType(LibraryPinnedIndicator),
              matching: find.byType(Positioned),
            )
            .first,
      );
      expect(pinPosition.right, -2);
      expect(pinPosition.top, -2);
      expect(pinPosition.bottom, isNull);
    },
  );
}
