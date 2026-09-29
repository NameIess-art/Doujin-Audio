import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crispasr/crispasr.dart';
import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/media/subtitle_parser.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/platform/windows_media_tools.dart';
import '../../library/application/work_text_service.dart';
import 'subtitle_ctc_alignment.dart';
import 'subtitle_generation.dart';
import 'subtitle_model_store.dart';

typedef SubtitleProgressCallback = void Function(SubtitleTaskProgress progress);

class SubtitleAiEngine {
  SubtitleAiEngine({
    SubtitleModelStore? models,
    FileCachePlatformGateway? files,
  }) : _models = models ?? SubtitleModelStore(),
       _files = files ?? FileCachePlatformGateway.instance;

  final SubtitleModelStore _models;
  final FileCachePlatformGateway _files;

  SubtitleModelStore get modelStore => _models;

  Future<SubtitleDraft?> prepareScript(
    String trackPath,
    String scriptPath, {
    SubtitleProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    _requireSupported();
    final scriptBytes = await _files.readDocumentBytes(scriptPath);
    if (scriptBytes == null) {
      throw FileSystemException('Script is unavailable', scriptPath);
    }
    final lines = scriptDialogueLines(decodeWorkText(scriptBytes).text);
    if (lines.isEmpty) return null;
    _checkCancelled(isCancelled);
    final model = await _ensureModel(
      SubtitleModelStore.japaneseCtc,
      onProgress,
    );
    _checkCancelled(isCancelled);

    final identity = sha256.convert([
      ...utf8.encode(trackPath),
      ...scriptBytes,
    ]).toString();
    final decoded = File(
      path.join((await getTemporaryDirectory()).path, '$identity.pcm'),
    );
    try {
      await _decodeAudio(trackPath, decoded, onProgress, isCancelled);
      final length = await decoded.length();
      if (length == 0) return null;
      const samplesPerChunk = 16000 * 20;
      const bytesPerChunk = samplesPerChunk * 4;
      final totalChunks = (length / bytesPerChunk).ceil();
      onProgress?.call(const SubtitleTaskProgress('loading', 0, ''));
      final worker = await _SubtitleWorker.open(model, 'asr');
      final reader = await decoded.open();
      try {
        await worker.beginScriptAlignment(lines);
        for (var chunk = 0; chunk < totalChunks; chunk++) {
          _checkCancelled(isCancelled);
          final expectedBytes = math.min(
            bytesPerChunk,
            length - chunk * bytesPerChunk,
          );
          final bytes = await reader.read(expectedBytes);
          if (bytes.length != expectedBytes) {
            throw FileSystemException(
              'Decoded audio is incomplete',
              decoded.path,
            );
          }
          final pcm = Float32List.view(Uint8List.fromList(bytes).buffer);
          await worker.feedScriptAlignment(
            pcm,
            chunk * 20.0,
            bytes.length / (16000 * 4),
          );
          final fraction = (chunk + 1) / totalChunks;
          onProgress?.call(
            SubtitleTaskProgress(
              'matching',
              fraction,
              '${(fraction * 100).round()}%',
            ),
          );
        }
        _checkCancelled(isCancelled);
        final cues = await worker.endScriptAlignment();
        if (cues.length != lines.length) {
          throw StateError(
            'Only ${cues.length}/${lines.length} script lines could be aligned',
          );
        }
        for (var index = 0; index < cues.length; index++) {
          if (cues[index].text != lines[index] ||
              cues[index].end <= cues[index].start ||
              (index > 0 && cues[index].start < cues[index - 1].end)) {
            throw StateError('Script alignment produced invalid cue times');
          }
        }
        return SubtitleDraft(
          cues: cues,
          kind: SubtitleDraftKind.script,
          sourceLanguage: 'ja',
        );
      } finally {
        await reader.close();
        await worker.close();
      }
    } finally {
      if (await decoded.exists()) await decoded.delete();
    }
  }

  Future<SubtitleDraft> prepareTranslation(
    List<SubtitleCue> source,
    String targetLanguage, {
    required String trackPath,
    SubtitleProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    _requireSupported();
    if (targetLanguage != 'zh' && targetLanguage != 'en') {
      throw ArgumentError.value(targetLanguage, 'targetLanguage');
    }
    final originals = source
        .map((cue) => cue.text.split('\n').first.trim())
        .toList();
    final workDir = Directory(
      path.join(
        (await getApplicationSupportDirectory()).path,
        'subtitle_progress',
      ),
    );
    await workDir.create(recursive: true);
    final identity = sha256
        .convert(
          utf8.encode('$trackPath|$targetLanguage|${jsonEncode(originals)}'),
        )
        .toString();
    final checkpoint = File(path.join(workDir.path, '$identity.json'));
    final prior = await _readCheckpoint(checkpoint);
    final model = await _ensureModel(
      SubtitleModelStore.translation,
      onProgress,
    );
    _checkCancelled(isCancelled);
    onProgress?.call(const SubtitleTaskProgress('loading', 0, ''));
    final worker = await _SubtitleWorker.open(model, 'chat');
    final cues = prior.cues.toList();
    try {
      const groupSize = 4;
      for (
        var offset = prior.nextChunk;
        offset < source.length;
        offset += groupSize
      ) {
        _checkCancelled(isCancelled);
        final group = originals.skip(offset).take(groupSize).toList();
        List<String> translated;
        try {
          translated = await worker.translate(group, targetLanguage);
        } on FormatException {
          translated = [];
          for (final line in group) {
            translated.addAll(await worker.translate([line], targetLanguage));
          }
        }
        if (translated.length != group.length ||
            translated.any((text) => text.trim().isEmpty)) {
          throw const FormatException(
            'Translation did not preserve subtitle correspondence',
          );
        }
        for (var index = 0; index < group.length; index++) {
          final original = source[offset + index];
          cues.add(
            SubtitleCue(
              start: original.start,
              end: original.end,
              text: '${group[index]}\n${translated[index].trim()}',
            ),
          );
        }
        await _writeCheckpoint(checkpoint, offset + group.length, cues);
        final fraction = cues.length / source.length;
        onProgress?.call(
          SubtitleTaskProgress(
            'translating',
            fraction,
            '${(fraction * 100).round()}%',
          ),
        );
      }
    } finally {
      await worker.close();
    }
    return SubtitleDraft(
      cues: cues,
      kind: SubtitleDraftKind.translation,
      sourceLanguage: 'ja',
      targetLanguage: targetLanguage,
    );
  }

  Future<String> _ensureModel(
    SubtitleModelSpec spec,
    SubtitleProgressCallback? onProgress,
  ) => _models.ensure(
    spec,
    onProgress: (fraction, received, total) {
      onProgress?.call(
        SubtitleTaskProgress(
          'download',
          fraction,
          '${(received / 1048576).toStringAsFixed(0)} / ${(total / 1048576).toStringAsFixed(0)} MiB',
        ),
      );
    },
  );

  Future<void> _decodeAudio(
    String source,
    File output,
    SubtitleProgressCallback? onProgress,
    bool Function()? isCancelled,
  ) async {
    if (await output.exists()) await output.delete();
    var input = source;
    if (Platform.isAndroid && source.startsWith('content://')) {
      input = await FFmpegKitConfig.getSafParameterForRead(source) ?? '';
      if (input.isEmpty) {
        throw FileSystemException('Cannot access audio document', source);
      }
    }
    final args = [
      '-y',
      '-nostdin',
      '-v',
      'error',
      '-i',
      input,
      '-vn',
      '-ac',
      '1',
      '-ar',
      '16000',
      '-f',
      'f32le',
      output.path,
    ];
    onProgress?.call(
      const SubtitleTaskProgress('decoding', 0, 'Preparing audio'),
    );
    if (Platform.isWindows) {
      final process = await WindowsMediaTools.instance.start('ffmpeg', args);
      final errors = process.stderr.transform(utf8.decoder).join();
      final outputDrain = process.stdout.drain<void>();
      final timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (isCancelled?.call() == true) process.kill();
      });
      try {
        final code = await process.exitCode;
        await outputDrain;
        if (isCancelled?.call() == true) throw const SubtitleTaskCancelled();
        if (code != 0) {
          throw ProcessException('ffmpeg', args, await errors, code);
        }
      } finally {
        timer.cancel();
      }
    } else {
      final completer = Completer<int>();
      final session = await FFmpegKit.executeWithArgumentsAsync(args, (
        result,
      ) async {
        final code = await result.getReturnCode();
        if (!completer.isCompleted) {
          completer.complete(ReturnCode.isSuccess(code) ? 0 : 1);
        }
      });
      final timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (isCancelled?.call() == true) {
          unawaited(FFmpegKit.cancel(session.getSessionId()));
        }
      });
      try {
        final code = await completer.future;
        if (isCancelled?.call() == true) throw const SubtitleTaskCancelled();
        if (code != 0) throw FileSystemException('Cannot decode audio', source);
      } finally {
        timer.cancel();
      }
    }
    if (!await output.exists() || await output.length() == 0) {
      throw FileSystemException('Decoded audio is empty', source);
    }
  }

  static void _requireSupported() {
    if (subtitleGenerationUnavailableReason != null) {
      throw UnsupportedError(subtitleGenerationUnavailableReason!);
    }
  }

  static void _checkCancelled(bool Function()? cancelled) {
    if (cancelled?.call() == true) throw const SubtitleTaskCancelled();
  }
}

typedef _Checkpoint = ({int nextChunk, List<SubtitleCue> cues});

Future<_Checkpoint> _readCheckpoint(File file) async {
  if (!await file.exists()) {
    return (nextChunk: 0, cues: <SubtitleCue>[]);
  }
  try {
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if ((data['version'] as int? ?? 1) != 1) {
      return (nextChunk: 0, cues: <SubtitleCue>[]);
    }
    final cues = (data['cues'] as List).map((item) {
      final cue = item as List;
      return SubtitleCue(
        start: Duration(milliseconds: cue[0] as int),
        end: Duration(milliseconds: cue[1] as int),
        text: cue[2] as String,
      );
    }).toList();
    return (nextChunk: data['nextChunk'] as int, cues: cues);
  } catch (_) {
    return (nextChunk: 0, cues: <SubtitleCue>[]);
  }
}

Future<void> _writeCheckpoint(
  File file,
  int nextChunk,
  List<SubtitleCue> cues,
) async {
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(
    jsonEncode({
      'version': 1,
      'nextChunk': nextChunk,
      'cues': cues
          .map(
            (cue) => [
              cue.start.inMilliseconds,
              cue.end.inMilliseconds,
              cue.text,
            ],
          )
          .toList(),
    }),
    flush: true,
  );
  if (await file.exists()) await file.delete();
  await temporary.rename(file.path);
}

class _SubtitleWorker {
  _SubtitleWorker(this._isolate, this._port, this._commands);
  final Isolate _isolate;
  final ReceivePort _port;
  final SendPort _commands;

  static Future<_SubtitleWorker> open(String model, String mode) async {
    final port = ReceivePort();
    final ready = Completer<SendPort>();
    final subscription = port.listen((message) {
      if (!ready.isCompleted) {
        if (message is SendPort) {
          ready.complete(message);
        } else {
          ready.completeError(StateError(message.toString()));
        }
      }
    });
    final isolate = await Isolate.spawn(_workerMain, [
      port.sendPort,
      model,
      mode,
    ]);
    try {
      final commands = await ready.future.timeout(const Duration(minutes: 5));
      await subscription.cancel();
      return _SubtitleWorker(isolate, port, commands);
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      port.close();
      rethrow;
    }
  }

  Future<dynamic> _request(
    String action,
    Object? payload, [
    Object? extra,
  ]) async {
    final reply = ReceivePort();
    try {
      _commands.send([reply.sendPort, action, payload, extra]);
      final result =
          await reply.first.timeout(const Duration(minutes: 10)) as List;
      if (result[0] != true) throw StateError(result[1].toString());
      return result[1];
    } finally {
      reply.close();
    }
  }

  Future<void> beginScriptAlignment(List<String> lines) async {
    await _request('beginScriptAlignment', lines);
  }

  Future<void> feedScriptAlignment(
    Float32List pcm,
    double start,
    double duration,
  ) async {
    await _request('feedScriptAlignment', [pcm, start, duration]);
  }

  Future<List<SubtitleCue>> endScriptAlignment() async {
    final raw = await _request('endScriptAlignment', null) as List;
    return raw.map((item) {
      final cue = item as List;
      return SubtitleCue(
        start: Duration(milliseconds: ((cue[1] as double) * 1000).round()),
        end: Duration(milliseconds: ((cue[2] as double) * 1000).round()),
        text: cue[0] as String,
      );
    }).toList();
  }

  Future<List<String>> translate(List<String> text, String language) async {
    final raw = await _request('translate', text, language) as String;
    if (text.length == 1) {
      return [parseSingleSubtitleTranslation(raw, language)];
    }
    return parseSubtitleTranslations(raw, text.length, language);
  }

  Future<void> close() async {
    final reply = ReceivePort();
    try {
      _commands.send([reply.sendPort, 'close', null, null]);
      await reply.first.timeout(const Duration(seconds: 10));
    } finally {
      reply.close();
      _isolate.kill();
      _port.close();
    }
  }
}

Future<void> _workerMain(List<Object> args) async {
  final outgoing = args[0] as SendPort;
  final model = args[1] as String;
  final mode = args[2] as String;
  final incoming = ReceivePort();
  CrispasrSession? asr;
  CrispasrChatSession? chat;
  SubtitleCtcAlignment? scriptAlignment;
  SendPort? closeReply;
  try {
    if (mode == 'asr') {
      asr = CrispasrSession.open(
        model,
        backend: 'wav2vec2',
        nThreads: Platform.isWindows
            ? math.min(12, Platform.numberOfProcessors)
            : 4,
      );
    } else {
      chat = CrispasrChatSession.open(
        model,
        params: const ChatOpenParams(nCtx: 2048, nGpuLayers: 0),
      );
    }
    outgoing.send(incoming.sendPort);
    await for (final message in incoming) {
      final command = message as List;
      final reply = command[0] as SendPort?;
      final action = command[1] as String;
      if (action == 'close') {
        closeReply = reply;
        break;
      }
      try {
        switch (action) {
          case 'beginScriptAlignment':
            final vocab = asr!.ctcVocab();
            if (vocab == null || vocab.isEmpty || vocab[0] != '<pad>') {
              throw StateError('CTC vocabulary is unavailable');
            }
            scriptAlignment = SubtitleCtcAlignment(
              lines: (command[2] as List).cast<String>(),
              vocab: vocab,
              blankId: 0,
            );
            reply!.send([true, null]);
          case 'feedScriptAlignment':
            final data = command[2] as List;
            final pcm = data[0] as Float32List;
            final start = data[1] as double;
            final duration = data[2] as double;
            final (_, logits) = asr!.transcribeWithLogits(pcm);
            if (logits == null) {
              scriptAlignment!.addSilence(
                startSeconds: start,
                durationSeconds: duration,
              );
            } else {
              scriptAlignment!.addChunk(
                logits: logits.data,
                nFrames: logits.nFrames,
                nVocab: logits.nVocab,
                startSeconds: start,
                durationSeconds: duration,
              );
            }
            reply!.send([true, null]);
          case 'endScriptAlignment':
            final timed = scriptAlignment!.finish();
            scriptAlignment = null;
            reply!.send([
              true,
              timed
                  .whereType<CtcAlignedLine>()
                  .map(
                    (line) => [line.text, line.startSeconds, line.endSeconds],
                  )
                  .toList(),
            ]);
          case 'translate':
            final inputs = (command[2] as List).cast<String>();
            final chinese = command[3] == 'zh';
            final single = inputs.length == 1;
            chat!.reset();
            final answer = await chat.generate([
              ChatMessage.system(
                single
                    ? chinese
                          ? '你是日语字幕翻译员。将日语台词、拟声词和舞台说明翻译成自然的简体中文。只输出一句中文译文，必须包含汉字，不要输出日文、JSON、原文或解释。'
                          : 'Translate this Japanese subtitle, sound effect, or stage direction into natural English. Output only one English translation, with no Japanese, JSON, original text, or explanation.'
                    : chinese
                    ? '你是日语字幕翻译员。请把每条日语字幕翻译成简体中文，绝对不要使用英文。只返回 JSON 数组，保持每条 id 和原顺序不变；每个 text 是简体中文译文，不要解释。'
                    : 'Translate each Japanese subtitle to English. Return only a JSON array of exactly ${inputs.length} objects with integer id and translated text. Keep each id unchanged and in order. Preserve meaning. Do not add notes.',
              ),
              ChatMessage.user(
                single
                    ? chinese
                          ? '日语：${inputs.single}\n简体中文：'
                          : 'Japanese: ${inputs.single}\nEnglish:'
                    : '${chinese ? '输入：' : ''}${jsonEncode(inputs.indexed.map((entry) => {'id': entry.$1, 'text': entry.$2}).toList())}${chinese ? '\n输出（简体中文）：' : ''}',
              ),
            ], params: const ChatGenerateParams(maxTokens: 400, temperature: 0.1));
            reply!.send([true, answer]);
        }
      } catch (error) {
        reply?.send([false, error.toString()]);
      }
    }
  } catch (error) {
    outgoing.send(error.toString());
  } finally {
    asr?.close();
    chat?.close();
    closeReply?.send([true, null]);
    incoming.close();
  }
}
