import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/core/widgets/app_feedback.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/presentation/playback_providers.dart';
import 'package:doujin_audio/features/player/presentation/playlist/subtitle_editor_page.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/core/widgets/swipe_reveal_card.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingSubtitleService extends PlaybackSubtitleService {
  _RecordingSubtitleService(List<SubtitleCue> initial)
    : super(
        trackResolver: (_) => null,
        subtitleLoader: (_, _) async =>
            SubtitleTrack(sourcePath: 'original.srt', cues: initial),
      );

  List<SubtitleCue>? saved;
  bool failSave = false;

  @override
  Future<SubtitleTrack> saveEditedSubtitle(
    String trackPath,
    List<SubtitleCue> cues,
  ) async {
    if (failSave) throw StateError('Save failed');
    saved = List.of(cues);
    return SubtitleTrack(sourcePath: 'edited.srt', cues: cues);
  }
}

Future<void> _showEditor(
  WidgetTester tester,
  PlaybackSubtitleService service,
) async {
  const trackPath = '/music/test.mp3';
  final language = AppLanguageProvider();
  await tester.runAsync(() => language.setLanguage(AppLanguage.zh));
  await tester.runAsync(() => service.load(trackPath));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appLanguageProviderInstanceProvider.overrideWithValue(language),
        playbackSubtitleServiceProvider.overrideWithValue(service),
      ],
      child: const MaterialApp(home: SubtitleEditorPage(trackPath: trackPath)),
    ),
  );
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('save feedback appears at the top and failure keeps the editor', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final service = _RecordingSubtitleService(const [
      SubtitleCue(
        start: Duration(seconds: 1),
        end: Duration(seconds: 3),
        text: 'Original',
      ),
    ]);
    await _showEditor(tester, service);
    await tester.tap(find.byKey(const ValueKey('subtitle_text_0')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Saved');
    await tester.tap(find.byType(FilledButton).last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.save_rounded));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AppFeedbackSurface), findsOneWidget);
    expect(find.text('字幕已保存'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('subtitle_text_0')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Unsaved');
    await tester.tap(find.byType(FilledButton).last);
    await tester.pumpAndSettle();
    service.failSave = true;
    await tester.tap(find.widgetWithIcon(IconButton, Icons.save_rounded));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('无法保存字幕，请重试。'), findsOneWidget);
    expect(find.text('Unsaved'), findsOneWidget);
    expect(find.byType(AppFeedbackSurface), findsOneWidget);
  });

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

  testWidgets(
    'right swipe inserts a blank row that must be completed',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final service = _RecordingSubtitleService(const [
        SubtitleCue(
          start: Duration(seconds: 1),
          end: Duration(seconds: 3),
          text: 'First',
        ),
        SubtitleCue(
          start: Duration(seconds: 5),
          end: Duration(seconds: 7),
          text: 'Second',
        ),
      ]);
      await _showEditor(tester, service);

      await tester.drag(
        find.byType(SwipeRevealCard).first,
        const Offset(170, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('在下方新增'));
      await tester.pumpAndSettle();
      expect(find.byType(SwipeRevealCard), findsNWidgets(3));
      expect(find.text('填写字幕文字'), findsOneWidget);
      expect(find.text('设置时间段'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.save_rounded),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const ValueKey('subtitle_text_1')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Inserted');
      await tester.tap(find.byType(FilledButton).last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.save_rounded),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const ValueKey('subtitle_time_1')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '00:00:03.200');
      await tester.enterText(find.byType(TextField).last, '00:00:04.800');
      await tester.tap(find.byType(FilledButton).last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithIcon(IconButton, Icons.save_rounded));
      await tester.pump();
      expect(service.saved?.map((cue) => cue.text), [
        'First',
        'Inserted',
        'Second',
      ]);
      expect(service.saved?[0].end, const Duration(seconds: 3));
      expect(service.saved?[1].start, const Duration(milliseconds: 3200));
      expect(service.saved?[2].start, const Duration(seconds: 5));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'left swipe can delete the final row and save empty subtitles',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final service = _RecordingSubtitleService(const [
        SubtitleCue(
          start: Duration(seconds: 1),
          end: Duration(seconds: 3),
          text: 'Only line',
        ),
      ]);
      await _showEditor(tester, service);
      await tester.drag(find.byType(SwipeRevealCard), const Offset(-170, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('删除字幕'));
      await tester.pumpAndSettle();
      expect(find.text('所有字幕已删除，保存后当前音频将不显示字幕'), findsOneWidget);
      await tester.tap(find.widgetWithIcon(IconButton, Icons.save_rounded));
      await tester.pump();
      expect(service.saved, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Windows right-click menu offers insert and delete',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final service = _RecordingSubtitleService(const [
        SubtitleCue(
          start: Duration(seconds: 1),
          end: Duration(seconds: 3),
          text: 'First',
        ),
      ]);
      await _showEditor(tester, service);
      await tester.tapAt(
        tester.getCenter(find.byType(SwipeRevealCard)),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('在下方新增'), findsOneWidget);
      expect(find.text('删除字幕'), findsOneWidget);
      await tester.tap(find.text('在下方新增'));
      await tester.pumpAndSettle();
      expect(find.byType(SwipeRevealCard), findsNWidgets(2));
      await tester.tapAt(
        tester.getCenter(find.byType(SwipeRevealCard).first),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除字幕'));
      await tester.pumpAndSettle();
      expect(find.byType(SwipeRevealCard), findsOneWidget);
      expect(find.text('填写字幕文字'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
