import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/i18n/app_language_provider.dart';
import 'package:nameless_audio/i18n/app_language_ja.dart';
import 'package:nameless_audio/widgets/library_like_cards.dart';
import 'package:nameless_audio/widgets/marquee_text.dart';
import 'package:nameless_audio/widgets/top_page_header.dart';
import 'package:provider/provider.dart';

Widget _buildApp(Widget child) {
  return ChangeNotifierProvider(
    create: (_) => AppLanguageProvider(),
    child: MaterialApp(home: Scaffold(body: child)),
  );
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
}
