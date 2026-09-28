import 'dart:io';

import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/features/library/application/work_text_service.dart';
import 'package:doujin_audio/features/player/application/subtitle_ai_engine.dart';
import 'package:doujin_audio/features/player/application/subtitle_generation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'the unaligned sample is parsed as dialogue, not a timed subtitle',
    () async {
      final file = File('docs/测试/1/トラック１.txt');
      final lines = scriptDialogueLines(
        decodeWorkText(await file.readAsBytes()).text,
      );
      expect(lines.length, greaterThan(200));
      expect(lines.first, contains('もっとこっち'));
      expect(lines.every((line) => line.trim().isNotEmpty), isTrue);
    },
  );

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

  test(
    'coarse recognition from the supplied audio finds a later spoken line',
    () async {
      final lines = scriptDialogueLines(
        decodeWorkText(await File('docs/测试/1/トラック１.txt').readAsBytes()).text,
      );
      const recognized = 'あ歩八駅の痛とだったの皇ま手下で窓松茶たでしのかしまらこは洗いちゃんの大ちご泊まるわけだ';
      final match = matchScriptWindow(recognized, lines, 0);
      expect(match, isNotNull);
      expect(
        lines.sublist(match!.startIndex, match.endIndex).join(),
        contains('泊まるわけだし'),
      );
    },
  );

  test(
    'the second sample matches its spoken opening after script notes',
    () async {
      final lines = scriptDialogueLines(
        decodeWorkText(
          await File('docs/测试/2/セリフ初稿台本_トラック１.txt').readAsBytes(),
        ).text,
      );
      const recognized = 'は起きていて下さったのですこ一日中お外で働いてお疲れでしょうにやっぱり姉中さにはたたかんいお食事よりもれ';
      final match = matchScriptWindow(recognized, lines, 0);
      expect(match, isNotNull);
      expect(lines[match!.startIndex], contains('起きていてくださった'));
    },
  );

  test('the third sample finds dialogue beyond repeated sounds', () async {
    final lines = scriptDialogueLines(
      decodeWorkText(
        await File('docs/测试/3/セリフ初稿台本_トラック２.txt').readAsBytes(),
      ).text,
    );
    expect(lines.length, greaterThan(100));
    expect(lines.first, startsWith('さあでは'));
    expect(lines.any((line) => line.startsWith('…やんっ')), isTrue);
    const openingRecognition = '三出あくはしってお耳をなめて差しあけますねばこち廊頃九ない';
    final opening = matchScriptWindow(
      openingRecognition,
      lines,
      0,
      minimumScore: 0.26,
      minimumCommonLength: 3,
    );
    expect(opening, isNotNull);
    expect(lines[opening!.startIndex], startsWith('横からハグ'));
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
    const lateRecognition = '砂学前の玄階で目でにかけていますまあ何ってス敵なお行でシょ';
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
    expect(lines[late!.startIndex], contains('我慢の限界'));
    const noisyRecognition = 'どん田寒ををもったたば紅泳しいドンドをどた';
    final temporal = matchScriptNearTime(noisyRecognition, lines, 4, 12, 49);
    expect(temporal, isNotNull);
    expect(lines[temporal!.startIndex], startsWith('どんどん'));
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
