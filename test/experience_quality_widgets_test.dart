import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/i18n/app_language_en.dart';
import 'package:nameless_audio/i18n/app_language_zh.dart';
import 'package:nameless_audio/widgets/library_like_cards.dart';
import 'package:nameless_audio/widgets/marquee_text.dart';

Widget _buildSurface(Widget child) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  home: Scaffold(
    body: Center(child: SizedBox(width: 360, child: child)),
  ),
);

LibraryLikeFeaturedCardContent _buildFeaturedCard({
  required String title,
  required List<LibraryLikeInfoLineData> lines,
  required Key coverKey,
  bool showExpandIndicator = true,
}) {
  return LibraryLikeFeaturedCardContent(
    title: title,
    lines: lines,
    playTooltip: 'add',
    onPlay: () {},
    showExpandIndicator: showExpandIndicator,
    enableMarquee: false,
    enableTitleMarquee: false,
    coverBuilder: (coverWidth) => Container(
      key: coverKey,
      width: coverWidth,
      height: LibraryLikeCardMetrics.infoBlockHeight,
      decoration: BoxDecoration(
        color: Colors.pink,
        borderRadius: BorderRadius.circular(LibraryLikeCardMetrics.coverRadius),
      ),
    ),
  );
}

void main() {
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

    expect(LibraryLikeCardMetrics.rootTileHeight, 148);
    expect(LibraryLikeCardMetrics.contentHeight, 140);
    expect(LibraryLikeCardMetrics.infoBlockHeight, 96);
    expect(LibraryLikeCardMetrics.titleBlockHeight, 38);
    expect(LibraryLikeCardMetrics.actionButtonSize, 40);
    expect(LibraryLikeCardMetrics.coverRadius, 12);

    expect(
      tester.getSize(find.byType(LibraryLikeFeaturedCardContent)),
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
    expect(find.byType(MarqueeText), findsNothing);
    expect(find.byIcon(Icons.add_circle_rounded), findsOneWidget);
    expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);

    final titleText = tester.widget<Text>(find.text(title));
    expect(titleText.maxLines, 2);
    expect(titleText.overflow, TextOverflow.ellipsis);
    expect(titleText.softWrap, isTrue);
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
    expect(tester.getSize(find.byKey(coverKey)).height, 96);
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

  test('settings, feedback, and recovery labels stay available', () {
    for (final table in [appLanguageZh, appLanguageEn]) {
      for (final key in [
        'section_general',
        'section_appearance',
        'section_playback',
        'section_data_storage',
        'section_system_updates',
        'permission_center',
        'data_and_support',
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
