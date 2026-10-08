import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/localization/app_language_ja.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/library_like_cards.dart';
import 'package:doujin_audio/core/widgets/horizontal_edge_fade_scroll.dart';
import 'package:doujin_audio/core/widgets/marquee_text.dart';
import 'package:doujin_audio/core/widgets/scroll_activity_gate.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';

Widget _buildApp(Widget child) {
  return ProviderScope(
    overrides: [
      appLanguageProviderInstanceProvider.overrideWithValue(
        AppLanguageProvider(),
      ),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

Future<void> _withPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  final previousPlatform = debugDefaultTargetPlatformOverride;
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = previousPlatform;
  }
}

Future<(int, int, int)> _edgeMaskAlphas(
  WidgetTester tester,
  Finder wrapper,
) async {
  final mask = tester.widget<ShaderMask>(
    find.descendant(of: wrapper, matching: find.byType(ShaderMask)),
  );
  expect(mask.blendMode, BlendMode.dstIn);
  final width = tester.getSize(wrapper).width.round();
  final result = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final bounds = Rect.fromLTWH(0, 0, width.toDouble(), 20);
    canvas.drawRect(bounds, Paint()..shader = mask.shaderCallback(bounds));
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, 20);
    final pixels = (await image.toByteData())!;
    int alpha(int x) => pixels.getUint8((10 * width + x) * 4 + 3);
    final result = (alpha(1), alpha(width ~/ 2), alpha(width - 2));
    image.dispose();
    picture.dispose();
    return result;
  });
  return result!;
}

Future<void> _pumpMarqueeFrames(WidgetTester tester, int milliseconds) async {
  for (var elapsed = 0; elapsed < milliseconds; elapsed += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

ScrollPosition _cardTextPosition(
  WidgetTester tester,
  Finder card,
  String text,
) {
  final line = find.descendant(
    of: card,
    matching: find.byWidgetPredicate(
      (widget) => widget is LibraryLikeScrollableText && widget.text == text,
    ),
  );
  return tester
      .state<ScrollableState>(
        find.descendant(of: line, matching: find.byType(Scrollable)),
      )
      .position;
}

void main() {
  testWidgets(
    'Windows marquee starts at the beginning when rows enter a scrolled list',
    (tester) async {
      final verticalController = ScrollController();
      addTearDown(verticalController.dispose);
      await tester.pumpWidget(
        _buildApp(
          ListView.builder(
            key: const PageStorageKey('marquee-list'),
            controller: verticalController,
            cacheExtent: 0,
            itemExtent: 100,
            itemCount: 30,
            itemBuilder: (context, index) => MarqueePauseScope(
              isPaused: true,
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 160,
                  child: LibraryLikeScrollableText(
                    text:
                        'A long work title for row $index that exceeds the available width',
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      verticalController.jumpTo(1000);
      await tester.pump();
      await tester.pump();
      final rows = find.byType(LibraryLikeScrollableText);
      expect(rows, findsWidgets);
      for (final row in rows.evaluate()) {
        final position = tester
            .state<ScrollableState>(
              find.descendant(
                of: find.byElementPredicate((e) => e == row),
                matching: find.byType(Scrollable),
              ),
            )
            .position;
        expect(position.maxScrollExtent, greaterThan(0));
        expect(position.pixels, 0);
      }
      expect(verticalController.offset, 1000);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'Windows cover hover starts only that work card and exit resets every row',
    (tester) async {
      const values = [
        'A very long title that extends beyond the visible card width',
        'Voice actor one and voice actor two with a long display name',
        '#ASMR #Sleep #A_very_long_tag #Another_very_long_tag',
      ];
      Widget card(int index) => SizedBox(
        width: 260,
        child: LibraryLikeWorkCardContent(
          key: ValueKey('hover-card-$index'),
          title: values[0],
          lines: [
            LibraryLikeInfoLineData(
              'Voice',
              values[1],
              icon: Icons.record_voice_over_rounded,
            ),
            LibraryLikeInfoLineData(
              'Tags',
              values[2],
              icon: Icons.local_offer_rounded,
            ),
          ],
          coverBuilder: (width) => SizedBox(
            key: ValueKey('hover-cover-$index'),
            width: width,
            height: 90,
            child: const ColoredBox(color: Colors.blue),
          ),
        ),
      );
      await tester.pumpWidget(_buildApp(Row(children: [card(0), card(1)])));
      await tester.pump();
      final first = find.byKey(const ValueKey('hover-card-0'));
      final second = find.byKey(const ValueKey('hover-card-1'));
      for (final marquee in tester.widgetList<MarqueeText>(
        find.descendant(of: first, matching: find.byType(MarqueeText)),
      )) {
        expect(marquee.pauseDuration, const Duration(seconds: 1));
        expect(marquee.scrollSpeed, 30);
      }
      await _pumpMarqueeFrames(tester, 4000);
      for (final value in values) {
        expect(_cardTextPosition(tester, first, value).pixels, 0);
        expect(_cardTextPosition(tester, second, value).pixels, 0);
      }
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(700, 500));
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('hover-cover-0'))),
      );
      await tester.pump();
      await _pumpMarqueeFrames(tester, 700);
      for (final value in values) {
        expect(_cardTextPosition(tester, first, value).pixels, 0);
      }
      await _pumpMarqueeFrames(tester, 2300);
      for (final value in values) {
        expect(_cardTextPosition(tester, first, value).pixels, greaterThan(0));
        expect(_cardTextPosition(tester, second, value).pixels, 0);
      }
      final beforeMovingInside = _cardTextPosition(
        tester,
        first,
        values[0],
      ).pixels;
      await mouse.moveTo(
        tester.getCenter(
          find.descendant(
            of: first,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is LibraryLikeScrollableText &&
                  widget.text == values[0],
            ),
          ),
        ),
      );
      await _pumpMarqueeFrames(tester, 500);
      expect(
        _cardTextPosition(tester, first, values[0]).pixels,
        greaterThan(beforeMovingInside),
      );
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('hover-cover-1'))),
      );
      await tester.pump();
      await _pumpMarqueeFrames(tester, 3000);
      for (final value in values) {
        expect(_cardTextPosition(tester, first, value).pixels, 0);
        expect(_cardTextPosition(tester, second, value).pixels, greaterThan(0));
      }
      await mouse.moveTo(const Offset(700, 500));
      await tester.pump();
      await _pumpMarqueeFrames(tester, 3000);
      for (final value in values) {
        expect(_cardTextPosition(tester, second, value).pixels, 0);
      }
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
      expect(tester.binding.transientCallbackCount, 0);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'Windows audio card hover starts title and metadata then exit resets both',
    (tester) async {
      const title =
          'A single audio title that is far wider than its visible row';
      const voice = 'A voice actor display name that is far wider than the row';
      await tester.pumpWidget(
        _buildApp(
          const SizedBox(
            width: 220,
            child: LibraryLikeSingleAudioCardContent(
              title: title,
              lines: [
                LibraryLikeInfoLineData(
                  'Voice',
                  voice,
                  icon: Icons.record_voice_over_rounded,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final card = find.byType(LibraryLikeSingleAudioCardContent);
      await _pumpMarqueeFrames(tester, 3000);
      expect(_cardTextPosition(tester, card, title).pixels, 0);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(700, 500));
      await mouse.moveTo(tester.getCenter(card));
      await tester.pump();
      await _pumpMarqueeFrames(tester, 3000);
      expect(_cardTextPosition(tester, card, title).pixels, greaterThan(0));
      expect(_cardTextPosition(tester, card, voice).pixels, greaterThan(0));
      await mouse.moveTo(const Offset(700, 500));
      await tester.pump();
      expect(_cardTextPosition(tester, card, title).pixels, 0);
      expect(_cardTextPosition(tester, card, voice).pixels, 0);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'Windows marquee moves forward at 30px per second then pauses and jumps back',
    (tester) async {
      await tester.pumpWidget(
        _buildApp(
          const SizedBox(
            width: 120,
            child: MarqueeText(
              text: 'A long marquee text that overflows',
              edgePadding: 0,
            ),
          ),
        ),
      );
      await tester.pump();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      await _pumpMarqueeFrames(tester, 1000);
      expect(position.pixels, 0);
      await _pumpMarqueeFrames(tester, 1200);
      expect(position.pixels, greaterThan(0));
      final before = position.pixels;
      await _pumpMarqueeFrames(tester, 500);
      expect(position.pixels - before, closeTo(15, 0.5));
      for (
        var frame = 0;
        frame < 300 && position.pixels < position.maxScrollExtent;
        frame++
      ) {
        final previous = position.pixels;
        await tester.pump(const Duration(milliseconds: 100));
        expect(position.pixels, greaterThanOrEqualTo(previous));
      }
      expect(position.pixels, position.maxScrollExtent);
      await _pumpMarqueeFrames(tester, 1000);
      expect(position.pixels, position.maxScrollExtent);
      for (var frame = 0; frame < 10 && position.pixels > 0; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(position.pixels, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'Windows marquee stops cleanly when long text becomes short',
    (tester) async {
      var text = 'A very long marquee value that needs to keep scrolling';
      late StateSetter update;
      await tester.pumpWidget(
        _buildApp(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return SizedBox(width: 120, child: MarqueeText(text: text));
            },
          ),
        ),
      );
      await tester.pump();
      await _pumpMarqueeFrames(tester, 3000);
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
        greaterThan(0),
      );
      update(() => text = 'Short');
      await tester.pump();
      await _pumpMarqueeFrames(tester, 3000);
      expect(find.text('Short'), findsOneWidget);
      expect(find.byType(Scrollable), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'Windows marquee respects hidden pages reduced motion and pause scopes',
    (tester) async {
      var visible = true;
      var reducedMotion = false;
      var scopePaused = false;
      late StateSetter update;
      await tester.pumpWidget(
        _buildApp(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MediaQuery(
                data: MediaQueryData(disableAnimations: reducedMotion),
                child: TickerMode(
                  enabled: visible,
                  child: MarqueePauseScope(
                    isPaused: scopePaused,
                    child: const SizedBox(
                      width: 120,
                      child: MarqueeText(
                        text:
                            'A very long marquee value that needs to keep scrolling',
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      await _pumpMarqueeFrames(tester, 3000);
      expect(position.pixels, greaterThan(0));
      for (var mode = 0; mode < 3; mode++) {
        update(() {
          visible = mode != 0;
          reducedMotion = mode == 1;
          scopePaused = mode == 2;
        });
        await tester.pump();
        await _pumpMarqueeFrames(tester, 3000);
        expect(position.pixels, 0, reason: 'Pause mode $mode');
        update(() {
          visible = true;
          reducedMotion = false;
          scopePaused = false;
        });
        await tester.pump();
        await _pumpMarqueeFrames(tester, 3000);
        expect(position.pixels, greaterThan(0));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
      expect(tester.binding.transientCallbackCount, 0);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'Windows marquee pauses resets and resumes with vertical scrolling',
    (tester) async {
      final interaction = UiInteractionCoordinator.instance;
      interaction.resetForTest();
      addTearDown(interaction.resetForTest);
      await tester.pumpWidget(
        _buildApp(
          const ScrollActivityGate(
            idleDelay: Duration(seconds: 3),
            child: SizedBox(
              width: 120,
              child: MarqueeText(
                text: 'A very long marquee value that needs to keep scrolling',
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      await _pumpMarqueeFrames(tester, 3000);
      expect(position.pixels, greaterThan(0));
      final element = tester.element(find.byType(MarqueeText));
      ScrollStartNotification(
        metrics: FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: 100,
          pixels: 0,
          viewportDimension: 100,
          axisDirection: AxisDirection.down,
          devicePixelRatio: 1,
        ),
        context: element,
      ).dispatch(element);
      await tester.pump();
      await _pumpMarqueeFrames(tester, 2000);
      expect(position.pixels, 0);
      await _pumpMarqueeFrames(tester, 4000);
      expect(position.pixels, greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  for (final direction in [TextDirection.ltr, TextDirection.rtl]) {
    testWidgets(
      'edge fade follows visible content in $direction',
      (tester) async {
        const fadeKey = ValueKey('sample-edge-fade');
        late ScrollController controller;
        await tester.pumpWidget(
          _buildApp(
            Directionality(
              textDirection: direction,
              child: SizedBox(
                width: 120,
                child: HorizontalEdgeFadeScroll(
                  key: fadeKey,
                  builder: (value) {
                    controller = value;
                    return SingleChildScrollView(
                      controller: value,
                      scrollDirection: Axis.horizontal,
                      child: const SizedBox(width: 600, height: 20),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final wrapper = find.byKey(fadeKey);
        final start = await _edgeMaskAlphas(tester, wrapper);
        expect(start.$2, 255);
        expect(direction == TextDirection.ltr ? start.$1 : start.$3, 255);
        expect(
          direction == TextDirection.ltr ? start.$3 : start.$1,
          lessThan(100),
        );
        controller.jumpTo(controller.position.maxScrollExtent / 2);
        await tester.pumpAndSettle();
        final middle = await _edgeMaskAlphas(tester, wrapper);
        expect(middle.$1, lessThan(100));
        expect(middle.$2, 255);
        expect(middle.$3, lessThan(100));
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pumpAndSettle();
        final end = await _edgeMaskAlphas(tester, wrapper);
        expect(direction == TextDirection.ltr ? end.$3 : end.$1, 255);
        expect(direction == TextDirection.ltr ? end.$1 : end.$3, lessThan(100));
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets('edge fade updates when content and viewport change', (
    tester,
  ) async {
    const fadeKey = ValueKey('resizing-edge-fade');
    var viewportWidth = 120.0;
    var contentWidth = 60.0;
    late StateSetter update;
    late ScrollController scrollController;
    await tester.pumpWidget(
      _buildApp(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return SizedBox(
              width: viewportWidth,
              child: HorizontalEdgeFadeScroll(
                key: fadeKey,
                builder: (controller) {
                  scrollController = controller;
                  return SingleChildScrollView(
                    controller: controller,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(width: contentWidth, height: 20),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final wrapper = find.byKey(fadeKey);
    expect(await _edgeMaskAlphas(tester, wrapper), (255, 255, 255));
    update(() => contentWidth = 600);
    await tester.pumpAndSettle();
    expect((await _edgeMaskAlphas(tester, wrapper)).$3, lessThan(100));
    scrollController.jumpTo(scrollController.position.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    final middle = await _edgeMaskAlphas(tester, wrapper);
    expect(middle.$1, lessThan(100));
    expect(middle.$3, lessThan(100));
    update(() => viewportWidth = 700);
    await tester.pumpAndSettle();
    expect(await _edgeMaskAlphas(tester, wrapper), (255, 255, 255));
    update(() => viewportWidth = 120);
    await tester.pumpAndSettle();
    expect((await _edgeMaskAlphas(tester, wrapper)).$3, lessThan(100));
    update(() => contentWidth = 60);
    await tester.pumpAndSettle();
    expect(await _edgeMaskAlphas(tester, wrapper), (255, 255, 255));
    expect(tester.takeException(), isNull);
  });

  testWidgets('top page header can render marquee title', (tester) async {
    await tester.pumpWidget(
      _buildApp(
        const TopPageHeader(
          title: 'プレイリスト',
          marqueeTitle: true,
          useSafeAreaTop: false,
        ),
      ),
    );

    final marquee = tester.widget<MarqueeText>(find.byType(MarqueeText).first);
    expect(marquee.text, 'プレイリスト');
    expect(marquee.edgePadding, 2);
  });

  testWidgets('top page header always renders a stable page title', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildApp(
        const TopPageHeader(title: 'Local library', useSafeAreaTop: false),
      ),
    );

    expect(find.text('Local library'), findsOneWidget);
    expect(find.text('Loading...'), findsNothing);
  });

  testWidgets('marquee text forwards custom edge padding', (tester) async {
    await _withPlatform(TargetPlatform.windows, () async {
      await tester.pumpWidget(
        _buildApp(
          const SizedBox(
            width: 120,
            child: MarqueeText(text: 'long text', edgePadding: 3),
          ),
        ),
      );

      final scrollView = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(scrollView.padding, const EdgeInsets.symmetric(horizontal: 3));
    });
  });

  testWidgets('android marquee text renders static text', (tester) async {
    await _withPlatform(TargetPlatform.android, () async {
      await tester.pumpWidget(
        _buildApp(
          const SizedBox(
            width: 120,
            child: MarqueeText(text: 'long text', edgePadding: 3),
          ),
        ),
      );

      expect(find.byType(SingleChildScrollView), findsNothing);
      final text = tester.widget<Text>(find.text('long text'));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
    });
  });

  testWidgets('android forced marquee still renders static text', (
    tester,
  ) async {
    await _withPlatform(TargetPlatform.android, () async {
      await tester.pumpWidget(
        _buildApp(
          const SizedBox(
            width: 40,
            child: MarqueeText(
              text: 'A very long text that should scroll',
              forceMarquee: true,
            ),
          ),
        ),
      );

      expect(find.byType(SingleChildScrollView), findsNothing);
      final text = tester.widget<Text>(
        find.text('A very long text that should scroll'),
      );
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
    });
  });

  testWidgets('library detail title is an icon with a localized tooltip', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildApp(
        const Material(
          child: SizedBox(
            width: 220,
            child: LibraryLikeDetailInfoLine(
              label: 'Circle',
              icon: Icons.groups_rounded,
              text: 'Label value',
              style: TextStyle(fontSize: 10),
              loading: false,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Circle'), findsNothing);
    expect(find.byIcon(Icons.groups_rounded), findsOneWidget);
    expect(find.byTooltip('Circle'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is MarqueeText && widget.text == 'Circle',
      ),
      findsNothing,
    );
  });

  testWidgets('library detail multiline text does not reserve blank rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildApp(
        const Material(
          child: SizedBox(
            width: 220,
            child: LibraryLikeDetailInfoLine(
              label: 'Tags',
              icon: Icons.sell_rounded,
              text: 'ASMR',
              style: TextStyle(fontSize: 10),
              loading: false,
              lines: 4,
              enableMarquee: false,
            ),
          ),
        ),
      ),
    );

    final size = tester.getSize(find.byType(LibraryLikeDetailInfoLine));
    expect(size.height, lessThan(24));
  });

  testWidgets('search hint marquee can fill available width', (tester) async {
    final hint = appLanguageJa['asmr_search_hint']!;

    await tester.pumpWidget(
      _buildApp(
        SizedBox(
          width: 220,
          height: 18,
          child: MarqueeText(text: hint, edgePadding: 0),
        ),
      ),
    );

    final size = tester.getSize(
      find.byWidgetPredicate(
        (widget) => widget is MarqueeText && widget.text == hint,
      ),
    );
    expect(size.width, 220);
  });

  testWidgets(
    'card text stays idle until hover and supports dragging on both platforms',
    (tester) async {
      const title =
          'A very long work title\nthat extends far beyond the cover card';
      const voice =
          'Voice actor one and voice actor two with a long display name';
      const tags = '#ASMR #Sleep #A_very_long_tag #Another_very_long_tag';
      const circle = 'A very long circle name that exceeds the card width';
      await tester.pumpWidget(
        _buildApp(
          SizedBox(
            width: 260,
            child: LibraryLikeWorkCardContent(
              title: title,
              lines: const [
                LibraryLikeInfoLineData(
                  'Voice',
                  voice,
                  icon: Icons.record_voice_over_rounded,
                ),
                LibraryLikeInfoLineData(
                  'Circle',
                  circle,
                  icon: Icons.storefront_outlined,
                ),
                LibraryLikeInfoLineData(
                  'Tags',
                  tags,
                  icon: Icons.local_offer_rounded,
                ),
              ],
              coverBuilder: (_) => const SizedBox(width: 120, height: 90),
            ),
          ),
        ),
      );
      await _pumpMarqueeFrames(tester, 3000);
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pump();
      for (final value in [title, voice, circle, tags]) {
        final line = find.byWidgetPredicate(
          (widget) =>
              widget is LibraryLikeScrollableText && widget.text == value,
        );
        final view = find.descendant(
          of: line,
          matching: find.byType(SingleChildScrollView),
        );
        final scrollable = tester.state<ScrollableState>(
          find.descendant(of: view, matching: find.byType(Scrollable)),
        );
        expect(scrollable.position.maxScrollExtent, greaterThan(0));
        expect(scrollable.position.pixels, 0);
        final mouse = defaultTargetPlatform == TargetPlatform.windows
            ? await tester.createGesture(kind: PointerDeviceKind.mouse)
            : null;
        if (mouse != null) {
          final start = tester.getCenter(view) + const Offset(40, 0);
          await mouse.addPointer(location: start);
          await tester.pump();
          await mouse.down(start);
          await mouse.moveBy(const Offset(-70, 0));
          await mouse.up();
        } else {
          await tester.drag(view, const Offset(-70, 0));
        }
        await tester.pumpAndSettle();
        final forwardOffset = scrollable.position.pixels;
        expect(forwardOffset, greaterThan(0));
        if (mouse != null) {
          final start = tester.getCenter(view) - const Offset(40, 0);
          await mouse.moveTo(start);
          await mouse.down(start);
          await mouse.moveBy(const Offset(70, 0));
          await mouse.up();
        } else {
          await tester.drag(view, const Offset(70, 0));
        }
        await tester.pumpAndSettle();
        expect(scrollable.position.pixels, lessThan(forwardOffset));
        if (mouse != null) {
          await mouse.removePointer();
          await tester.pump();
        }
        final text = tester.widget<Text>(
          find.text(value.replaceAll('\n', ' ')),
        );
        expect(text.maxLines, 1);
        expect(text.softWrap, isFalse);
        expect(text.overflow, TextOverflow.visible);
      }
      expect(
        find.byType(MarqueeText),
        defaultTargetPlatform == TargetPlatform.windows
            ? findsNWidgets(4)
            : findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Windows card text accepts mouse wheel scrolling',
    (tester) async {
      const title =
          'A very long work title that extends far beyond the cover card';
      await tester.pumpWidget(
        _buildApp(
          const SizedBox(
            width: 120,
            child: LibraryLikeScrollableText(
              text: title,
              style: TextStyle(fontSize: 14),
            ),
          ),
        ),
      );
      final view = find.byType(SingleChildScrollView);
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(view),
          scrollDelta: const Offset(0, 60),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(scrollable.position.pixels, greaterThan(0));
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets('windows marquee resumes after vertical scrolling becomes idle', (
    tester,
  ) async {
    await _withPlatform(TargetPlatform.windows, () async {
      const marqueeKey = ValueKey('resuming_marquee');
      await tester.pumpWidget(
        _buildApp(
          const ScrollActivityGate(
            idleDelay: Duration(milliseconds: 10),
            child: SizedBox(
              width: 80,
              height: 20,
              child: MarqueeText(
                key: marqueeKey,
                text: 'A very long information value that must scroll',
                pauseDuration: Duration(milliseconds: 1),
                scrollSpeed: 100,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2));

      final element = tester.element(find.byKey(marqueeKey));
      final metrics = FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 100,
        pixels: 0,
        viewportDimension: 100,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      );
      ScrollStartNotification(
        metrics: metrics,
        context: element,
      ).dispatch(element);
      await tester.pump();
      expect(find.byType(SingleChildScrollView), findsOneWidget);

      ScrollEndNotification(
        metrics: metrics,
        context: element,
      ).dispatch(element);
      await tester.pump(const Duration(milliseconds: 12));
      await tester.pump();
      expect(find.byType(SingleChildScrollView), findsOneWidget);

      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final scrollView = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(scrollView.controller!.offset, greaterThan(0));
    });
  });

  testWidgets('scroll activity gate can track a nested scrollable', (
    tester,
  ) async {
    const nestedListKey = ValueKey('nested_scroll_list');
    final coordinator = UiInteractionCoordinator.instance;

    await tester.pumpWidget(
      _buildApp(
        ScrollActivityGate(
          idleDelay: const Duration(milliseconds: 10),
          maxNotificationDepth: 1,
          child: SizedBox(
            height: 160,
            child: PageView(
              physics: const NeverScrollableScrollPhysics(),
              children: [
                ListView.builder(
                  key: nestedListKey,
                  itemExtent: 40,
                  itemCount: 20,
                  itemBuilder: (_, index) => Text('Item $index'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(coordinator.isInteracting, isFalse);
    await tester.drag(find.byKey(nestedListKey), const Offset(0, -120));
    await tester.pump();

    expect(coordinator.isInteracting, isTrue);
    await tester.pump(const Duration(milliseconds: 180));
    expect(coordinator.isInteracting, isFalse);
  });
}
