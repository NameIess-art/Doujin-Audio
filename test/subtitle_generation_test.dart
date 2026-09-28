import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/features/player/application/subtitle_ai_engine.dart';
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

  test('matches in order and rejects an unrelated script', () {
    final lines = [
      '第一章 タイトル',
      '今日はお姉ちゃんのおうちに泊まるわけだし',
      '抱き枕がないと困っちゃうよね',
      '遠慮しないでね',
    ];
    final match = matchScriptWindow(
      '今日からお姉ちゃんのうちに泊まるわけだし、抱き枕がないと困っちゃうよね',
      lines,
      0,
    );
    expect(match, isNotNull);
    expect(match!.startIndex, 1);
    expect(match.endIndex, 3);
    expect(matchScriptWindow('電車は明日の朝に出発します', lines, 0), isNull);
  });

  test('coarse recognition finds a later spoken line', () {
    final lines = scriptDialogueLines('''
第一章 タイトル
今日はお姉ちゃんのおうちに泊まるわけだし
抱き枕がないと困っちゃうよね
遠慮しないでね
''');
    const recognized = '今日はお姉ちゃんのうちに泊まるわけだし抱き枕がないと困っちゃうよね';
    final match = matchScriptWindow(recognized, lines, 0);
    expect(match, isNotNull);
    expect(
      lines.sublist(match!.startIndex, match.endIndex).join(),
      contains('泊まるわけだし'),
    );
  });

  test('spoken opening matches after script notes', () {
    final lines = scriptDialogueLines('''
※ 開始まで環境音
【ドアが開く】
お姉ちゃん：起きていてくださったのですね
お姉ちゃん：一日中お外で働いてお疲れでしょうに
''');
    const recognized = '起きていてくださったのです一日中お外で働いてお疲れでしょうに';
    final match = matchScriptWindow(recognized, lines, 0);
    expect(match, isNotNull);
    expect(lines[match!.startIndex], contains('起きていてくださった'));
  });

  test('long script recovers dialogue beyond the default search window', () {
    final lines = List<String>.generate(
      180,
      (index) => '第$index幕では静かに風が吹いています',
    );
    lines[4] = '横からハグしてお耳をなめて差し上げますね';
    lines[45] = 'どんどん気持ちよくなってください';
    lines[80] = 'ご奉仕はまだまだこんなものではありませんよ';
    lines[100] = '我慢の限界までお付き合いくださいね';
    const openingRecognition = '横からハグしてお耳をなめて差し上げますね';
    final opening = matchScriptWindow(
      openingRecognition,
      lines,
      0,
      minimumScore: 0.26,
      minimumCommonLength: 3,
    );
    expect(opening, isNotNull);
    expect(opening!.startIndex, 4);
    const spoken = 'ご奉仕はまだまだこんなものではありませんよ';
    expect(matchScriptWindow(spoken, lines, 10), isNull);
    final recovered = matchScriptWindow(
      spoken,
      lines,
      10,
      lookAhead: 160,
      minimumScore: 0.45,
    );
    expect(recovered, isNotNull);
    expect(lines[recovered!.startIndex], contains('ご奉仕はまだまだ'));
    const lateRecognition = '我慢の限界までお付き合いくださいね';
    expect(
      matchScriptWindow(
        lateRecognition,
        lines,
        4,
        minimumScore: 0.26,
        minimumCommonLength: 3,
      ),
      isNull,
    );
    final late = matchScriptWindow(
      lateRecognition,
      lines,
      4,
      lookAhead: 160,
      minimumScore: 0.42,
    );
    expect(late, isNotNull);
    expect(late!.startIndex, 100);
    const noisyRecognition = 'どんどん気持ちよくなってください';
    final temporal = matchScriptNearTime(noisyRecognition, lines, 4, 12, 49);
    expect(temporal, isNotNull);
    expect(temporal!.startIndex, 45);
    expect(matchScriptNearTime('電車は明日の朝に出発します', lines, 4, 12, 49), isNull);
  });

  test('aligned cues retain their own timing and speech gaps', () {
    final cues = alignedScriptCues(
      ['おはよう', '元気ですか'],
      [
        (text: 'お', start: 1.0, end: 1.2),
        (text: 'は', start: 1.2, end: 1.4),
        (text: 'よ', start: 1.4, end: 1.6),
        (text: 'う', start: 1.6, end: 1.8),
        (text: '元', start: 3.0, end: 3.2),
        (text: '気', start: 3.2, end: 3.4),
        (text: 'で', start: 3.4, end: 3.6),
        (text: 'す', start: 3.6, end: 3.8),
        (text: 'か', start: 3.8, end: 4.0),
      ],
    );
    expect(cues, hasLength(2));
    expect(cues[0].start, const Duration(seconds: 1));
    expect(cues[0].end, const Duration(milliseconds: 1800));
    expect(cues[1].start, const Duration(seconds: 3));
  });

  test('untimed sentence-end tokens do not discard aligned dialogue', () {
    final cues = alignedScriptCues(
      ['出来ぃ～', '持って'],
      [
        (text: '出', start: 20.36, end: 20.38),
        (text: '来', start: 21.90, end: 21.92),
        (text: 'ぃ～', start: 20.0, end: 20.0),
        (text: '持', start: 26.74, end: 26.76),
        (text: 'って', start: 27.42, end: 27.68),
      ],
    );
    expect(cues, hasLength(2));
    expect(cues.first.start, const Duration(milliseconds: 20360));
    expect(cues.first.end, const Duration(milliseconds: 21920));
    expect(cues.last.start, const Duration(milliseconds: 26740));
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

  test('translation response preserves cue IDs and target language', () {
    expect(
      parseSubtitleTranslations(
        '[{"id":0,"text":"你好。"},{"id":1,"text":"天气很好。"}]',
        2,
        'zh',
      ),
      ['你好。', '天气很好。'],
    );
    expect(
      () => parseSubtitleTranslations(
        '[{"id":0,"text":"Good morning."}]',
        1,
        'zh',
      ),
      throwsFormatException,
    );
    expect(
      () => parseSubtitleTranslations(
        '[{"id":1,"text":"Good morning."}]',
        1,
        'en',
      ),
      throwsFormatException,
    );
  });

  test(
    'single subtitle translation accepts natural text but rejects Japanese',
    () {
      expect(parseSingleSubtitleTranslation('哦，真可爱！', 'zh'), '哦，真可爱！');
      expect(
        parseSingleSubtitleTranslation('English: What a lovely day.', 'en'),
        'What a lovely day.',
      );
      expect(
        () => parseSingleSubtitleTranslation('っふふ…♡', 'zh'),
        throwsFormatException,
      );
      expect(
        () => parseSingleSubtitleTranslation('［{"id":0,"text":"你好"}', 'zh'),
        throwsFormatException,
      );
    },
  );
}
