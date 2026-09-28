import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/application/subtitle_generation.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'script recognition writes the audio-named LRC beside a local audio file',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'subtitle_local_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final audio = File(
        '${directory.path}${Platform.pathSeparator}voice-track.mp3',
      );
      await audio.writeAsBytes(const []);
      final service = PlaybackSubtitleService(trackResolver: (_) => null);
      final saved = await service.saveDraft(
        audio.path,
        const SubtitleDraft(
          kind: SubtitleDraftKind.script,
          sourceLanguage: 'ja',
          cues: [
            SubtitleCue(
              start: Duration(seconds: 1),
              end: Duration(seconds: 3),
              text: 'おはようございます。',
            ),
          ],
        ),
      );
      final lrc = File(
        '${directory.path}${Platform.pathSeparator}voice-track.lrc',
      );
      expect(saved.sourcePath, lrc.path);
      expect(await lrc.readAsString(), contains('おはようございます。'));

      SharedPreferences.setMockInitialValues(<String, Object>{});
      final restarted = PlaybackSubtitleService(trackResolver: (_) => null);
      expect((await restarted.load(audio.path))?.sourcePath, lrc.path);
      expect(
        restarted.textAt(audio.path, const Duration(seconds: 2)),
        'おはようございます。',
      );
    },
  );

  test('clearing an edited subtitle remains local after restart', () async {
    final directory = await Directory.systemTemp.createTemp('subtitle_clear_');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}${Platform.pathSeparator}source.srt');
    await source.writeAsString(
      '1\n00:00:01,000 --> 00:00:03,000\nおはようございます。\n',
    );
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      subtitleLoader: (_, _) async => SubtitleTrack(
        sourcePath: source.path,
        cues: const [
          SubtitleCue(
            start: Duration(seconds: 1),
            end: Duration(seconds: 3),
            text: 'おはようございます。',
          ),
        ],
      ),
      subtitlesDirectoryResolver: () async => directory,
    );
    const audioPath = '/music/clear-me.mp3';
    await service.load(audioPath);
    final cleared = await service.saveEditedSubtitle(audioPath, const []);
    expect(cleared.cues, isEmpty);
    expect(service.hasKnownSubtitle(audioPath), isFalse);
    expect(await File(cleared.sourcePath).exists(), isTrue);
    final restarted = PlaybackSubtitleService(
      trackResolver: (_) => null,
      subtitlesDirectoryResolver: () async => directory,
    );
    expect((await restarted.load(audioPath))?.cues, isEmpty);
    expect(restarted.hasKnownSubtitle(audioPath), isFalse);
  });

  test('SAF script writes audio-named LRC to the authorized folder', () async {
    final directory = await Directory.systemTemp.createTemp('subtitle_saf_');
    addTearDown(() => directory.delete(recursive: true));
    const audioPath =
        'content://provider/tree/root/document/root%2Fvoice-track.mp3';
    final gateway = _RecordingSubtitleGateway();
    final service = PlaybackSubtitleService(
      trackResolver: (_) => MusicTrack(
        path: audioPath,
        displayName: 'voice-track.mp3',
        groupKey: 'content://provider/tree/root',
        groupTitle: 'root',
        groupSubtitle: '',
        isSingle: false,
      ),
      fileCacheGateway: gateway,
      subtitlesDirectoryResolver: () async => directory,
    );
    await service.saveDraft(
      audioPath,
      const SubtitleDraft(
        kind: SubtitleDraftKind.script,
        sourceLanguage: 'ja',
        cues: [
          SubtitleCue(
            start: Duration(seconds: 1),
            end: Duration(seconds: 2),
            text: 'こんにちは。',
          ),
        ],
      ),
    );
    expect(gateway.folder, 'content://provider/tree/root');
    expect(gateway.name, 'voice-track.lrc');
    expect(utf8.decode(gateway.bytes!), contains('こんにちは。'));
  });

  test(
    'translation can reuse Japanese text after loading its local SRT',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'subtitle_translation_',
      );
      addTearDown(() => directory.delete(recursive: true));
      const audioPath = '/music/japanese.mp3';
      const japanese = 'お姉ちゃん、今日は一緒に寝ましょうね。';
      final service = PlaybackSubtitleService(
        trackResolver: (_) => null,
        subtitleLoader: (_, _) async => SubtitleTrack(
          sourcePath: 'source.srt',
          cues: const [
            SubtitleCue(
              start: Duration(seconds: 1),
              end: Duration(seconds: 3),
              text: japanese,
            ),
          ],
        ),
        subtitlesDirectoryResolver: () async => directory,
      );
      await service.load(audioPath);
      await service.saveDraft(
        audioPath,
        const SubtitleDraft(
          kind: SubtitleDraftKind.translation,
          sourceLanguage: 'ja',
          targetLanguage: 'zh',
          cues: [
            SubtitleCue(
              start: Duration(seconds: 1),
              end: Duration(seconds: 3),
              text: '$japanese\n姐姐，今晚一起睡吧。',
            ),
          ],
        ),
      );
      final restarted = PlaybackSubtitleService(
        trackResolver: (_) => null,
        subtitlesDirectoryResolver: () async => directory,
      );
      expect(
        (await restarted.japaneseSourceCues(audioPath)).single.text,
        japanese,
      );
    },
  );
}

class _RecordingSubtitleGateway extends FileCachePlatformGateway {
  String? folder;
  String? name;
  Uint8List? bytes;

  @override
  Future<bool> writeTrackSubtitle({
    required String folder,
    required String name,
    required Uint8List bytes,
  }) async {
    this.folder = folder;
    this.name = name;
    this.bytes = bytes;
    return true;
  }
}
