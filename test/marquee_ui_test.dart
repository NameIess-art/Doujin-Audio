import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/i18n/app_language_provider.dart';
import 'package:nameless_audio/i18n/app_language_ja.dart';
import 'package:nameless_audio/widgets/library_like_cards.dart';
import 'package:nameless_audio/widgets/marquee_text.dart';
import 'package:nameless_audio/widgets/scroll_activity_gate.dart';
import 'package:nameless_audio/widgets/top_page_header.dart';
import 'package:provider/provider.dart';

Widget _buildApp(Widget child) {
  return ProviderScope(
    child: ChangeNotifierProvider(
      create: (_) => AppLanguageProvider(),
      child: MaterialApp(home: Scaffold(body: child)),
    ),
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

void main() {
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

  testWidgets('android marquee can be allowed explicitly', (tester) async {
    await _withPlatform(TargetPlatform.android, () async {
      await tester.pumpWidget(
        _buildApp(
          const SizedBox(
            width: 40,
            child: MarqueeText(
              text: 'A very long text that should scroll',
              allowAndroidMarquee: true,
            ),
          ),
        ),
      );

      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });
  });

  testWidgets('library detail label uses tighter marquee padding', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildApp(
        const Material(
          child: SizedBox(
            width: 220,
            child: LibraryLikeDetailInfoLine(
              label: 'Circle',
              text: 'Label value',
              style: TextStyle(fontSize: 10),
              loading: false,
            ),
          ),
        ),
      ),
    );

    final marquee = tester.widget<MarqueeText>(
      find.byWidgetPredicate(
        (widget) => widget is MarqueeText && widget.text == 'Circle',
      ),
    );
    expect(marquee.edgePadding, 2);
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

  testWidgets('library-like card can keep title static and info marquee', (
    tester,
  ) async {
    const title = 'A very long work title that should stay static';
    const info = 'A very long information value that should keep scrolling';
    await tester.pumpWidget(
      _buildApp(
        SizedBox(
          width: 260,
          child: LibraryLikeFeaturedCardContent(
            title: title,
            lines: const [LibraryLikeInfoLineData('Info', info)],
            coverBuilder: (_) => const SizedBox(width: 120),
            onPlay: () {},
            playTooltip: 'Play',
            enableTitleMarquee: false,
          ),
        ),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (widget) => widget is MarqueeText && widget.text == title,
      ),
      findsNothing,
    );
    final staticTitle = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == title,
      ),
    );
    expect(staticTitle.maxLines, 2);
    expect(staticTitle.softWrap, isTrue);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is MarqueeText && widget.text == info,
      ),
      findsOneWidget,
    );
  });

  testWidgets('library-like card can disable list info marquee', (
    tester,
  ) async {
    const title = 'Static list title';
    const info = 'A very long information value that should stay static';
    await tester.pumpWidget(
      _buildApp(
        SizedBox(
          width: 260,
          child: LibraryLikeFeaturedCardContent(
            title: title,
            lines: const [LibraryLikeInfoLineData('Info', info)],
            coverBuilder: (_) => const SizedBox(width: 120),
            onPlay: () {},
            playTooltip: 'Play',
            enableMarquee: false,
            enableTitleMarquee: false,
          ),
        ),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (widget) => widget is MarqueeText && widget.text == info,
      ),
      findsNothing,
    );
    final staticInfo = tester.widget<Text>(
      find.byWidgetPredicate((widget) => widget is Text && widget.data == info),
    );
    expect(staticInfo.overflow, TextOverflow.ellipsis);
  });

  testWidgets('marquee resumes after vertical scrolling becomes idle', (
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
}
