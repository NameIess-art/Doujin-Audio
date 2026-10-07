import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/features/player/application/subtitle_generation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('untimed script notes are excluded from dialogue', () {
    final lines = scriptDialogueLines('''
※ 場面説明
# 収録メモ
【扉を開ける】
1. お姉ちゃん：もっとこっちに来て（小声で）

・ お姉ちゃん：今日は一緒に眠りましょう
''');
    expect(lines, ['もっとこっちに来て', '今日は一緒に眠りましょう']);
  });

  test('source language is explicit only with enough Japanese evidence', () {
    List<SubtitleCue> cues(String text) => [
      SubtitleCue(
        start: Duration.zero,
        end: const Duration(seconds: 2),
        text: text,
      ),
    ];
    expect(
      classifySubtitleLanguage(cues('お姉ちゃん、今日は一緒に寝ましょうね。')),
      SubtitleLanguage.japanese,
    );
    expect(
      classifySubtitleLanguage(
        cues('This is an English subtitle with plenty of words.'),
      ),
      SubtitleLanguage.other,
    );
    expect(classifySubtitleLanguage(cues('はい')), SubtitleLanguage.unknown);
  });

  test('32-bit Android reports why subtitle generation is unavailable', () {
    expect(
      subtitleGenerationUnavailableReasonFor(
        isAndroid: true,
        isWindows: false,
        pointerBytes: 4,
      ),
      'subtitle_unsupported_32bit',
    );
    expect(
      subtitleGenerationUnavailableReasonFor(
        isAndroid: true,
        isWindows: false,
        pointerBytes: 8,
      ),
      isNull,
    );
  });
}
