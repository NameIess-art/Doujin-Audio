import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/presentation/playback_providers.dart';
import 'package:doujin_audio/features/player/presentation/playlist/subtitle_editor_page.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('edits cue text and timing in the page', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const trackPath = '/music/test.mp3';
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      subtitleLoader: (_, _) async => SubtitleTrack(
        sourcePath: '/music/test.srt',
        cues: const [
          SubtitleCue(
            start: Duration(seconds: 1),
            end: Duration(seconds: 3),
            text: 'Before',
          ),
        ],
      ),
    );
    await tester.runAsync(() => service.load(trackPath));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            AppLanguageProvider(),
          ),
          playbackSubtitleServiceProvider.overrideWithValue(service),
        ],
        child: const MaterialApp(
          home: SubtitleEditorPage(trackPath: trackPath),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(TopPageHeader), findsOneWidget);
    expect(find.byType(HeaderFloatingButton), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey('subtitle_text_0')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(find.byType(TextField), 'After');
    await tester.tap(find.byType(FilledButton).last);
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.byKey(const ValueKey('subtitle_time_0')));
    await tester.pump(const Duration(milliseconds: 250));
    final timeFields = find.byType(TextField);
    expect(
      tester.getTopLeft(timeFields.last).dy -
          tester.getBottomLeft(timeFields.first).dy,
      greaterThanOrEqualTo(12),
    );
    await tester.enterText(find.byType(TextField).first, '00:00:02.000');
    await tester.enterText(find.byType(TextField).last, '00:00:04.000');
    await tester.tap(find.byType(FilledButton).last);
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('After'), findsOneWidget);
    expect(find.text('00:00:02.000'), findsOneWidget);
    expect(find.text('00:00:04.000'), findsOneWidget);
    expect(find.byIcon(Icons.save_rounded), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.save_rounded),
          )
          .onPressed,
      isNotNull,
    );
  });
}
