import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crispasr/crispasr.dart';
import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_full/return_code.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/app_log_service.dart';
import '../../../core/media/subtitle_parser.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/platform/windows_media_tools.dart';
import '../../../core/translation/text_translation_service.dart';
import '../../library/application/work_text_service.dart';
import 'subtitle_asr_postprocess.dart';
import 'subtitle_ctc_alignment.dart';
import 'subtitle_generation.dart';
import 'subtitle_model_store.dart';

typedef SubtitleProgressCallback = void Function(SubtitleTaskProgress progress);

typedef SubtitleAudioDecodeHandler =
    Future<void> Function(
      String source,
      File output,
      SubtitleProgressCallback? onProgress,
      bool Function()? isCancelled,
    );

abstract interface class SubtitleTranscriptionDriver {
  Future<VadWindowPlan> planWindow({
    required Uint8List stereoS16Le,
    required int windowStartFrame,
    required bool isFinalWindow,
  });

  Future<List<AsrRawSegment>> transcribeSlice({
    required int windowStartFrame,
    required int startFrame,
    required int endFrame,
  });

  Future<void> close();
}

typedef SubtitleTranscriptionDriverFactory =
    Future<SubtitleTranscriptionDriver> Function(
      String asrModelPath,
      String vadModelPath,
    );

class SubtitleAiEngine {
  SubtitleAiEngine({
    SubtitleModelStore? models,
    FileCachePlatformGateway? files,
    TextTranslationService? translations,
    SubtitleAudioDecodeHandler? stereoAudioDecoder,
    SubtitleTranscriptionDriverFactory? transcriptionDriverFactory,
    SubtitleAsrModelOption Function()? activeAsrModel,
  }) : _models = models ?? SubtitleModelStore(),
       _files = files ?? FileCachePlatformGateway.instance,
       _translations = translations ?? TextTranslationService(),
       _stereoAudioDecoder = stereoAudioDecoder,
       _transcriptionDriverFactory = transcriptionDriverFactory,
       _activeAsrModel =
           activeAsrModel ?? (() => SubtitleModelStore.kotobaWhisperJa);

  final SubtitleModelStore _models;
  final FileCachePlatformGateway _files;
  final TextTranslationService _translations;
  final SubtitleAudioDecodeHandler? _stereoAudioDecoder;
  final SubtitleTranscriptionDriverFactory? _transcriptionDriverFactory;
  final SubtitleAsrModelOption Function() _activeAsrModel;
  static final RegExp _lineBreakPattern = RegExp(r'\r?\n');
  static const int _checkpointBatchInterval = 5;
  static const Duration _checkpointTimeInterval = Duration(seconds: 10);

  SubtitleModelStore get modelStore => _models;
  TextTranslationService get translationService => _translations;
  SubtitleAsrModelOption get currentAsrModel => _activeAsrModel();

  Future<SubtitleDraft?> prepareScript(
    String trackPath,
    String scriptPath, {
    SubtitleProgressCallback? onProgress,
    bool Function()? isCancelled,
    Future<void>? cancellation,
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
      isCancelled,
      cancellation,
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
      final worker = await _SubtitleWorker.open(model);
      try {
        final reader = await decoded.open();
        try {
          // The pinned Japanese wav2vec2 model downsamples by 320 at 16 kHz.
          // Round up and allow chunk boundaries; the aligner also checks actual
          // frames before every append so a changed model cannot bypass its cap.
          final expectedFrames = (length / (320 * 4)).ceil() + totalChunks * 2;
          await worker.beginScriptAlignment(lines, expectedFrames);
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
            final byteCount = bytes.length;
            final pcm = TransferableTypedData.fromList([bytes]);
            await worker.feedScriptAlignment(
              pcm,
              chunk * 20.0,
              byteCount / (16000 * 4),
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
          try {
            await reader.close();
          } catch (error, stackTrace) {
            AppLogService.warning(
              'subtitle_ai_reader_close_failed',
              error: error,
              stackTrace: stackTrace,
            );
          }
        }
      } finally {
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
    Future<void>? cancellation,
  }) async {
    if (targetLanguage != 'zh' && targetLanguage != 'en') {
      throw ArgumentError.value(targetLanguage, 'targetLanguage');
    }
    final originals = source
        .map((cue) => (cue.originalText ?? cue.text).trim())
        .toList();
    final workDir = Directory(
      path.join(
        (await getApplicationSupportDirectory()).path,
        'subtitle_progress',
      ),
    );
    await workDir.create(recursive: true);
    final sourceIdentity = sha256
        .convert(utf8.encode(jsonEncode([trackPath, targetLanguage])))
        .toString();
    final input = [
      for (var index = 0; index < source.length; index++)
        [
          source[index].start.inMicroseconds,
          source[index].end.inMicroseconds,
          originals[index],
        ],
    ];
    final backendSignature = _translations.backendSignatureFor(
      TextTranslationScene.subtitle,
    );
    final useCustomBackend = _translations.usesCustomBackendFor(
      TextTranslationScene.subtitle,
    );
    final maxBatchItems = useCustomBackend
        ? textTranslationLlmBatchMaxItems
        : textTranslationBatchMaxItems;
    final maxBatchChars = useCustomBackend
        ? textTranslationLlmBatchMaxCharacters
        : textTranslationBatchMaxCharacters;
    final identityPayload = backendSignature == 'google'
        ? input
        : <Object>[backendSignature, input];
    final identity = sha256
        .convert(utf8.encode(jsonEncode(identityPayload)))
        .toString();
    final checkpoint = File(
      path.join(workDir.path, '${sourceIdentity}_v3_$identity.json'),
    );
    final legacyIdentity = sha256
        .convert(
          utf8.encode('$trackPath|$targetLanguage|${jsonEncode(originals)}'),
        )
        .toString();
    await for (final entry in workDir.list()) {
      final name = path.basename(entry.path);
      if (entry is File &&
          entry.path != checkpoint.path &&
          (name.startsWith('${sourceIdentity}_v2_') ||
              name.startsWith('${sourceIdentity}_v3_') ||
              name == '$legacyIdentity.json')) {
        await entry.delete();
      }
    }
    final prior = await _readCheckpoint(checkpoint);
    _checkCancelled(isCancelled);
    if (prior.nextChunk == source.length &&
        prior.cues.length == source.length) {
      return SubtitleDraft(
        cues: prior.cues,
        kind: SubtitleDraftKind.translation,
        sourceLanguage: 'ja',
        targetLanguage: targetLanguage,
      );
    }
    final request = _translations.newRequest();
    final cancelled = cancellation?.then<void>((_) => request.cancel());
    final cues = prior.cues.toList();
    var offset = prior.nextChunk;
    var lastPersistedOffset = offset;
    var batchesSinceCheckpoint = 0;
    final checkpointClock = Stopwatch()..start();
    var completedNormally = false;
    try {
      final initialFraction = cues.length / source.length;
      onProgress?.call(
        SubtitleTaskProgress(
          'translating',
          initialFraction,
          '${(initialFraction * 100).round()}%',
        ),
      );
      while (offset < source.length) {
        _checkCancelled(isCancelled);
        if (request.cancelled) throw const SubtitleTaskCancelled();
        // Cue groups retain positional mapping; the shared service deduplicates
        // their text and serializes network batches with the same global limits.
        var end = offset;
        var characters = 0;
        while (end < source.length && end - offset < maxBatchItems) {
          final length = originals[end].length;
          if (end > offset && characters + length > maxBatchChars) {
            break;
          }
          characters += length;
          end++;
        }
        final group = originals.sublist(offset, end);
        final contextBefore = offset > 0
            ? originals.sublist(math.max(0, offset - 4), offset)
            : const <String>[];
        // Keep a cue's lines together so translation sees the complete sentence.
        final parts = group
            .map(
              (text) => text.length <= textTranslationBatchMaxCharacters
                  ? [text]
                  : textTranslationSegments(text),
            )
            .toList();
        final texts = parts
            .expand((parts) => parts)
            .where(canTranslateText)
            .toList();
        final task = _translations.translateInScene(
          texts,
          target: targetLanguage == 'zh' ? 'zh-CN' : 'en',
          source: 'ja',
          scene: TextTranslationScene.subtitle,
          contextBefore: contextBefore,
          request: request,
        );
        final result = cancelled == null
            ? await task
            : await Future.any<TextTranslationResult>([
                task,
                cancelled.then<TextTranslationResult>(
                  (_) => throw const SubtitleTaskCancelled(),
                ),
              ]);
        _checkCancelled(isCancelled);
        if (request.cancelled) throw const SubtitleTaskCancelled();
        if (result.failure != null) throw result.failure!;
        if (texts.any(
          (text) => result.translations[text]?.trim().isNotEmpty != true,
        )) {
          throw TextTranslationFailure.invalidResponse;
        }
        for (var index = 0; index < group.length; index++) {
          final original = source[offset + index];
          // SRT reserves blank lines for cue separators, not paragraph breaks.
          final translated = parts[index]
              .map((part) => result.translations[part] ?? part)
              .join()
              .split(_lineBreakPattern)
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty)
              .join('\n');
          cues.add(
            SubtitleCue(
              start: original.start,
              end: original.end,
              text: '${group[index]}\n$translated',
              originalText: group[index],
            ),
          );
        }
        offset = end;
        batchesSinceCheckpoint++;
        if (offset >= source.length ||
            batchesSinceCheckpoint >= _checkpointBatchInterval ||
            checkpointClock.elapsed >= _checkpointTimeInterval) {
          await _writeCheckpoint(checkpoint, offset, cues);
          lastPersistedOffset = offset;
          batchesSinceCheckpoint = 0;
          checkpointClock.reset();
        }
        final fraction = cues.length / source.length;
        onProgress?.call(
          SubtitleTaskProgress(
            'translating',
            fraction,
            '${(fraction * 100).round()}%',
          ),
        );
      }
      completedNormally = true;
    } finally {
      request.cancel();
      if (!completedNormally && offset > lastPersistedOffset) {
        try {
          await _writeCheckpoint(checkpoint, offset, cues);
        } catch (_) {
          // Preserve the original failure or cancellation.
        }
      }
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
    bool Function()? isCancelled,
    Future<void>? cancellation,
  ) async {
    _checkCancelled(isCancelled);
    void reportProgress(double fraction, int received, int total) {
      if (isCancelled?.call() == true) return;
      onProgress?.call(
        SubtitleTaskProgress(
          'download',
          fraction,
          '${(received / 1048576).toStringAsFixed(0)} / ${(total / 1048576).toStringAsFixed(0)} MiB',
        ),
      );
    }

    final snapshot = _models.snapshot(spec);
    if (snapshot.active) {
      reportProgress(snapshot.fraction, snapshot.received, snapshot.total);
    }
    // Models are shared with the settings page and later generation jobs.
    // Cancel this waiter without interrupting their download.
    final download = _models.ensure(spec, onProgress: reportProgress);
    if (cancellation == null) return download;
    return Future.any<String>([
      download,
      cancellation.then<String>((_) => throw const SubtitleTaskCancelled()),
    ]);
  }

  Future<List<String>> _ensureModelBundle(
    List<SubtitleModelSpec> specs,
    SubtitleProgressCallback? onProgress,
    bool Function()? isCancelled,
    Future<void>? cancellation,
  ) async {
    _checkCancelled(isCancelled);
    void reportProgress(double fraction, int received, int total) {
      if (isCancelled?.call() == true) return;
      onProgress?.call(
        SubtitleTaskProgress(
          'download',
          fraction,
          '${(received / 1048576).toStringAsFixed(0)} / ${(total / 1048576).toStringAsFixed(0)} MiB',
        ),
      );
    }

    final snapshot = _models.bundleSnapshot(specs);
    if (snapshot.active) {
      reportProgress(snapshot.fraction, snapshot.received, snapshot.total);
    }
    final download = _models.ensureBundle(specs, onProgress: reportProgress);
    if (cancellation == null) return download;
    return Future.any<List<String>>([
      download,
      cancellation.then<List<String>>(
        (_) => throw const SubtitleTaskCancelled(),
      ),
    ]);
  }

  Future<SubtitleDraft?> prepareTranscription(
    String trackPath, {
    SubtitleProgressCallback? onProgress,
    bool Function()? isCancelled,
    Future<void>? cancellation,
  }) async {
    _requireSupported();
    _checkCancelled(isCancelled);
    final asrOption = currentAsrModel;
    final workDir = Directory(
      path.join(
        (await getApplicationSupportDirectory()).path,
        'subtitle_progress',
      ),
    );
    await workDir.create(recursive: true);
    final trackSourceKey = sha256
        .convert(utf8.encode(jsonEncode(['asr', trackPath])))
        .toString();
    final localStatSignature = await _localFileSignature(
      trackPath,
      asrOption.checkpointSignature,
    );
    if (localStatSignature != null) {
      final fastCheckpoint = await _findCompletedLocalAsrCheckpoint(
        workDir,
        trackSourceKey,
        localStatSignature,
      );
      if (fastCheckpoint != null) {
        _checkCancelled(isCancelled);
        final cues = buildSanitizedTranscriptionCues(
          fastCheckpoint.segments,
          maxDuration: Duration(
            microseconds: (fastCheckpoint.totalFrames * 1000000) ~/ 16000,
          ),
        );
        if (cues.isEmpty) return null;
        return SubtitleDraft(
          cues: cues,
          kind: SubtitleDraftKind.transcription,
          sourceLanguage: asrOption.supportedLanguages.first,
        );
      }
    }

    final modelPaths = await _ensureModelBundle(
      asrOption.bundleSpecs,
      onProgress,
      isCancelled,
      cancellation,
    );
    final vadModelPath = asrOption.vadModel != null ? modelPaths.first : '';
    final asrModelPath = modelPaths.last;
    _checkCancelled(isCancelled);

    final decoded = File(
      path.join(
        (await getTemporaryDirectory()).path,
        'asr_$trackSourceKey.s16le.pcm',
      ),
    );
    try {
      final decode = _stereoAudioDecoder;
      if (decode != null) {
        await decode(trackPath, decoded, onProgress, isCancelled);
      } else {
        await _decodeAudio(
          trackPath,
          decoded,
          onProgress,
          isCancelled,
          channels: 2,
          sampleFormat: 's16le',
        );
      }
      final length = await decoded.length();
      final totalFrames = length ~/ 4;
      if (totalFrames <= 0) return null;

      final asrIdentity = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                trackPath,
                totalFrames,
                for (final spec in asrOption.bundleSpecs) spec.sha256,
              ]),
            ),
          )
          .toString();
      final checkpoint = File(
        path.join(workDir.path, 'asr_${trackSourceKey}_v1_$asrIdentity.json'),
      );
      await for (final entry in workDir.list()) {
        final name = path.basename(entry.path);
        if (entry is File &&
            entry.path != checkpoint.path &&
            name.startsWith('asr_${trackSourceKey}_')) {
          await entry.delete();
        }
      }

      final prior = await _readAsrCheckpoint(checkpoint, totalFrames);
      _checkCancelled(isCancelled);
      final maxDuration = Duration(
        microseconds: (totalFrames * 1000000) ~/ 16000,
      );
      if (prior.nextFrame >= totalFrames) {
        final cues = buildSanitizedTranscriptionCues(
          prior.segments,
          maxDuration: maxDuration,
        );
        if (cues.isEmpty) return null;
        return SubtitleDraft(
          cues: cues,
          kind: SubtitleDraftKind.transcription,
          sourceLanguage: 'ja',
        );
      }

      onProgress?.call(const SubtitleTaskProgress('loading', 0, ''));
      final factory = _transcriptionDriverFactory;
      final driver = factory != null
          ? await factory(asrModelPath, vadModelPath)
          : await _SubtitleWorker.openTranscription(
              asrModelPath,
              vadModelPath,
              backend: asrOption.backend,
            );

      var frameOffset = prior.nextFrame;
      var lastPersistedFrame = frameOffset;
      final segments = prior.segments.toList();
      var windowsSinceCheckpoint = 0;
      final checkpointClock = Stopwatch()..start();
      var completedNormally = false;

      Future<T> runCancellable<T>(Future<T> operation) {
        if (cancellation == null) return operation;
        return Future.any<T>([
          operation,
          cancellation.then<T>((_) => throw const SubtitleTaskCancelled()),
        ]);
      }

      try {
        final reader = await decoded.open();
        try {
          const windowFrames = 16000 * 60;
          final initialFraction = (frameOffset / totalFrames).clamp(0.0, 1.0);
          onProgress?.call(
            SubtitleTaskProgress(
              'transcribing',
              initialFraction,
              '${(initialFraction * 100).round()}%',
            ),
          );

          while (frameOffset < totalFrames) {
            _checkCancelled(isCancelled);
            final currentFrames = math.min(
              windowFrames,
              totalFrames - frameOffset,
            );
            final isFinalWindow = frameOffset + currentFrames >= totalFrames;
            await reader.setPosition(frameOffset * 4);
            final expectedBytes = currentFrames * 4;
            final bytes = await reader.read(expectedBytes);
            if (bytes.length < 4) {
              throw FileSystemException(
                'Decoded audio is incomplete',
                decoded.path,
              );
            }

            final plan = await runCancellable(
              driver.planWindow(
                stereoS16Le: bytes,
                windowStartFrame: frameOffset,
                isFinalWindow: isFinalWindow,
              ),
            );
            _checkCancelled(isCancelled);

            for (final slice in plan.slices) {
              _checkCancelled(isCancelled);
              final sliceSegments = await runCancellable(
                driver.transcribeSlice(
                  windowStartFrame: frameOffset,
                  startFrame: slice.startFrame,
                  endFrame: slice.endFrame,
                ),
              );
              _checkCancelled(isCancelled);
              segments.addAll(sliceSegments);
              final sliceEndFrame = math.min(
                totalFrames,
                frameOffset + slice.endFrame,
              );
              final sliceFraction = (sliceEndFrame / totalFrames).clamp(
                0.0,
                1.0,
              );
              onProgress?.call(
                SubtitleTaskProgress(
                  'transcribing',
                  sliceFraction,
                  '${(sliceFraction * 100).round()}%',
                ),
              );
            }

            final nextOffset = math.max(
              frameOffset + 1,
              math.min(totalFrames, plan.nextFrameOffset),
            );
            frameOffset = nextOffset;
            windowsSinceCheckpoint++;
            if (frameOffset >= totalFrames ||
                windowsSinceCheckpoint >= 2 ||
                checkpointClock.elapsed >= _checkpointTimeInterval) {
              await _writeAsrCheckpoint(
                checkpoint,
                totalFrames: totalFrames,
                nextFrame: frameOffset,
                segments: segments,
                fileSignature: localStatSignature,
              );
              lastPersistedFrame = frameOffset;
              windowsSinceCheckpoint = 0;
              checkpointClock.reset();
            }

            final fraction = (frameOffset / totalFrames).clamp(0.0, 1.0);
            onProgress?.call(
              SubtitleTaskProgress(
                'transcribing',
                fraction,
                '${(fraction * 100).round()}%',
              ),
            );
          }
          completedNormally = true;
        } finally {
          try {
            await reader.close();
          } catch (error, stackTrace) {
            AppLogService.warning(
              'subtitle_ai_reader_close_failed',
              error: error,
              stackTrace: stackTrace,
            );
          }
        }
      } finally {
        if (!completedNormally && frameOffset > lastPersistedFrame) {
          try {
            await _writeAsrCheckpoint(
              checkpoint,
              totalFrames: totalFrames,
              nextFrame: frameOffset,
              segments: segments,
              fileSignature: localStatSignature,
            );
          } catch (_) {
            // Preserve the original failure or cancellation.
          }
        }
        await driver.close();
      }

      final cues = buildSanitizedTranscriptionCues(
        segments,
        maxDuration: maxDuration,
      );
      if (cues.isEmpty) return null;
      return SubtitleDraft(
        cues: cues,
        kind: SubtitleDraftKind.transcription,
        sourceLanguage: 'ja',
      );
    } finally {
      if (await decoded.exists()) await decoded.delete();
    }
  }

  static Future<String?> _localFileSignature(
    String trackPath,
    String modelSignature,
  ) async {
    if (trackPath.isEmpty ||
        trackPath.startsWith('content://') ||
        trackPath.startsWith('http://') ||
        trackPath.startsWith('https://')) {
      return null;
    }
    final stat = await File(trackPath).stat();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) return null;
    return '${stat.size}:${stat.modified.millisecondsSinceEpoch}:$modelSignature';
  }

  Future<void> _decodeAudio(
    String source,
    File output,
    SubtitleProgressCallback? onProgress,
    bool Function()? isCancelled, {
    int channels = 1,
    String sampleFormat = 'f32le',
  }) async {
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
      '$channels',
      '-ar',
      '16000',
      '-f',
      sampleFormat,
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
    if (data['version'] != 3) {
      return (nextChunk: 0, cues: <SubtitleCue>[]);
    }
    final cues = (data['cues'] as List).map((item) {
      final cue = item as List;
      return SubtitleCue(
        start: Duration(milliseconds: cue[0] as int),
        end: Duration(milliseconds: cue[1] as int),
        text: cue[2] as String,
        originalText: cue[3] as String,
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
      'version': 3,
      'nextChunk': nextChunk,
      'cues': cues
          .map(
            (cue) => [
              cue.start.inMilliseconds,
              cue.end.inMilliseconds,
              cue.text,
              cue.originalText,
            ],
          )
          .toList(),
    }),
    flush: true,
  );
  if (await file.exists()) await file.delete();
  await temporary.rename(file.path);
}

typedef _AsrCheckpoint = ({
  int totalFrames,
  int nextFrame,
  List<AsrRawSegment> segments,
  String? fileSignature,
});

Future<_AsrCheckpoint?> _findCompletedLocalAsrCheckpoint(
  Directory workDir,
  String trackSourceKey,
  String expectedSignature,
) async {
  if (!await workDir.exists()) return null;
  await for (final entry in workDir.list()) {
    final name = path.basename(entry.path);
    if (entry is! File || !name.startsWith('asr_${trackSourceKey}_v1_')) {
      continue;
    }
    try {
      final data =
          jsonDecode(await entry.readAsString()) as Map<String, dynamic>;
      if (data['version'] != 1 || data['fileSignature'] != expectedSignature) {
        continue;
      }
      final totalFrames = data['totalFrames'] as int;
      final nextFrame = data['nextFrame'] as int;
      if (totalFrames <= 0 || nextFrame < totalFrames) continue;
      return (
        totalFrames: totalFrames,
        nextFrame: nextFrame,
        segments: _decodeAsrSegments(data['segments'] as List),
        fileSignature: expectedSignature,
      );
    } catch (_) {
      continue;
    }
  }
  return null;
}

Future<_AsrCheckpoint> _readAsrCheckpoint(
  File file,
  int expectedTotalFrames,
) async {
  if (!await file.exists()) {
    return (
      totalFrames: expectedTotalFrames,
      nextFrame: 0,
      segments: <AsrRawSegment>[],
      fileSignature: null,
    );
  }
  try {
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (data['version'] != 1 || data['totalFrames'] != expectedTotalFrames) {
      return (
        totalFrames: expectedTotalFrames,
        nextFrame: 0,
        segments: <AsrRawSegment>[],
        fileSignature: null,
      );
    }
    final nextFrame = (data['nextFrame'] as int).clamp(0, expectedTotalFrames);
    return (
      totalFrames: expectedTotalFrames,
      nextFrame: nextFrame,
      segments: _decodeAsrSegments(data['segments'] as List),
      fileSignature: data['fileSignature'] as String?,
    );
  } catch (_) {
    return (
      totalFrames: expectedTotalFrames,
      nextFrame: 0,
      segments: <AsrRawSegment>[],
      fileSignature: null,
    );
  }
}

List<AsrRawSegment> _decodeAsrSegments(List<dynamic> rawList) {
  return rawList.map((item) {
    final seg = item as List;
    final rawWords = seg.length > 4 ? (seg[4] as List) : const <dynamic>[];
    return AsrRawSegment(
      text: seg[0] as String,
      startSeconds: (seg[1] as num).toDouble(),
      endSeconds: (seg[2] as num).toDouble(),
      noSpeechProb: (seg[3] as num).toDouble(),
      words: rawWords.map((wordItem) {
        final w = wordItem as List;
        return AsrWordTiming(
          text: w[0] as String,
          startSeconds: (w[1] as num).toDouble(),
          endSeconds: (w[2] as num).toDouble(),
        );
      }).toList(growable: false),
    );
  }).toList();
}

Future<void> _writeAsrCheckpoint(
  File file, {
  required int totalFrames,
  required int nextFrame,
  required List<AsrRawSegment> segments,
  String? fileSignature,
}) async {
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(
    jsonEncode({
      'version': 1,
      'totalFrames': totalFrames,
      'nextFrame': nextFrame,
      'fileSignature': ?fileSignature,
      'segments': segments
          .map(
            (seg) => [
              seg.text,
              seg.startSeconds,
              seg.endSeconds,
              seg.noSpeechProb,
              [
                for (final w in seg.words)
                  [w.text, w.startSeconds, w.endSeconds],
              ],
            ],
          )
          .toList(),
    }),
    flush: true,
  );
  if (await file.exists()) await file.delete();
  await temporary.rename(file.path);
}

class _SubtitleWorker implements SubtitleTranscriptionDriver {
  _SubtitleWorker(
    this._isolate,
    this._port,
    this._exitPort,
    this._unexpectedExit,
    this._commands, {
    Duration defaultCloseTimeout = const Duration(seconds: 10),
  }) : _defaultCloseTimeout = defaultCloseTimeout;

  final Isolate _isolate;
  final ReceivePort _port;
  final ReceivePort _exitPort;
  final Future<Never> _unexpectedExit;
  final SendPort _commands;
  final Duration _defaultCloseTimeout;

  static Future<_SubtitleWorker> open(String model) =>
      _spawn([model], defaultCloseTimeout: const Duration(seconds: 10));

  static Future<_SubtitleWorker> openTranscription(
    String asrModel,
    String vadModel, {
    SubtitleAsrBackend backend = SubtitleAsrBackend.whisperWithVad,
  }) => _spawn(
    [asrModel, vadModel, backend.name],
    defaultCloseTimeout: const Duration(seconds: 45),
  );

  static Future<_SubtitleWorker> _spawn(
    List<Object> extraArgs, {
    required Duration defaultCloseTimeout,
  }) async {
    final port = ReceivePort();
    final exitPort = ReceivePort();
    final exitSignal = Completer<Object?>();
    exitPort.listen((message) {
      if (!exitSignal.isCompleted) {
        exitSignal.complete(message);
      }
    });
    final Future<Never> unexpectedExit = exitSignal.future.then(
      (detail) => throw StateError(
        detail == null
            ? 'Subtitle worker isolate exited unexpectedly'
            : 'Subtitle worker isolate failed: $detail',
      ),
    );
    // Prevent unhandled async error if the isolate exits during normal close().
    unexpectedExit.ignore();

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
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _workerMain,
        [port.sendPort, ...extraArgs],
        onExit: exitPort.sendPort,
        onError: exitPort.sendPort,
      );
    } catch (_) {
      await subscription.cancel();
      exitPort.close();
      port.close();
      rethrow;
    }
    try {
      final commands = await Future.any<SendPort>([
        ready.future,
        unexpectedExit,
      ]).timeout(const Duration(minutes: 5));
      await subscription.cancel();
      return _SubtitleWorker(
        isolate,
        port,
        exitPort,
        unexpectedExit,
        commands,
        defaultCloseTimeout: defaultCloseTimeout,
      );
    } catch (_) {
      await subscription.cancel();
      isolate.kill(priority: Isolate.immediate);
      exitPort.close();
      port.close();
      rethrow;
    }
  }

  Future<dynamic> _request(String action, Object? payload) async {
    final reply = ReceivePort();
    try {
      _commands.send([reply.sendPort, action, payload]);
      final result =
          await Future.any<Object?>([
                reply.first,
                _unexpectedExit,
              ]).timeout(const Duration(minutes: 10))
              as List;
      if (result[0] != true) {
        if (result[1] == 'alignment_too_large') {
          throw const SubtitleAlignmentTooLarge();
        }
        throw StateError(result[1].toString());
      }
      return result[1];
    } finally {
      reply.close();
    }
  }

  Future<void> beginScriptAlignment(
    List<String> lines,
    int expectedFrames,
  ) async {
    await _request('beginScriptAlignment', [lines, expectedFrames]);
  }

  Future<void> feedScriptAlignment(
    TransferableTypedData pcm,
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

  @override
  Future<VadWindowPlan> planWindow({
    required Uint8List stereoS16Le,
    required int windowStartFrame,
    required bool isFinalWindow,
  }) async {
    final raw = await _request('vadWindow', [
      TransferableTypedData.fromList([stereoS16Le]),
      windowStartFrame,
      isFinalWindow,
    ]) as List;
    final nextFrameOffset = raw[0] as int;
    final rawSlices = raw[1] as List;
    return VadWindowPlan(
      nextFrameOffset: nextFrameOffset,
      slices: rawSlices.map((item) {
        final pair = item as List;
        return (startFrame: pair[0] as int, endFrame: pair[1] as int);
      }).toList(growable: false),
    );
  }

  @override
  Future<List<AsrRawSegment>> transcribeSlice({
    required int windowStartFrame,
    required int startFrame,
    required int endFrame,
  }) async {
    final raw = await _request('transcribeWindowSlice', [
      windowStartFrame,
      startFrame,
      endFrame,
    ]) as List;
    return _decodeAsrSegments(raw);
  }

  @override
  Future<void> close({Duration? timeout}) async {
    final effectiveTimeout = timeout ?? _defaultCloseTimeout;
    final reply = ReceivePort();
    var timedOut = false;
    try {
      _commands.send([reply.sendPort, 'close', null]);
      await reply.first.timeout(effectiveTimeout);
    } on TimeoutException catch (error, stackTrace) {
      timedOut = true;
      AppLogService.warning(
        'subtitle_ai_worker_close_timeout',
        error: error,
        stackTrace: stackTrace,
      );
    } catch (error, stackTrace) {
      AppLogService.warning(
        'subtitle_ai_worker_close_failed',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      reply.close();
      _isolate.kill(
        priority: timedOut ? Isolate.immediate : Isolate.beforeNextEvent,
      );
      _exitPort.close();
      _port.close();
    }
  }
}

Future<void> _workerMain(List<Object> args) async {
  final outgoing = args[0] as SendPort;
  final model = args[1] as String;
  final vadModel = args.length > 2 ? args[2] as String : null;
  final asrBackendName = args.length > 3
      ? args[3] as String
      : SubtitleAsrBackend.whisperWithVad.name;
  final useQwen3Session =
      asrBackendName == SubtitleAsrBackend.qwen3WithVad.name;
  final incoming = ReceivePort();
  final nThreads = Platform.isWindows
      ? math.min(12, Platform.numberOfProcessors)
      : (vadModel != null
            ? math.min(6, math.max(4, Platform.numberOfProcessors - 2))
            : 4);
  CrispasrSession? asr;
  _NativeWhisperRuntime? whisper;
  Float32List? currentWindowMono;
  SubtitleCtcAlignment? scriptAlignment;
  SendPort? closeReply;
  try {
    if (vadModel != null) {
      whisper = useQwen3Session
          ? _NativeWhisperRuntime.openSession(
              model,
              backend: 'qwen3',
              nThreads: nThreads,
            )
          : _NativeWhisperRuntime.open(model);
    } else {
      asr = CrispasrSession.open(
        model,
        backend: 'wav2vec2',
        nThreads: nThreads,
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
            final input = command[2] as List;
            final vocab = asr!.ctcVocab();
            if (vocab == null || vocab.isEmpty || vocab[0] != '<pad>') {
              throw StateError('CTC vocabulary is unavailable');
            }
            scriptAlignment = SubtitleCtcAlignment(
              lines: (input[0] as List).cast<String>(),
              vocab: vocab,
              blankId: 0,
              expectedFrames: input[1] as int,
            );
            reply!.send([true, null]);
          case 'feedScriptAlignment':
            final data = command[2] as List;
            final pcm = (data[0] as TransferableTypedData)
                .materialize()
                .asFloat32List();
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
          case 'vadWindow':
            final data = command[2] as List;
            final stereoBytes = (data[0] as TransferableTypedData)
                .materialize()
                .asUint8List();
            final windowStartFrame = data[1] as int;
            final isFinalWindow = data[2] as bool;
            final mono = downmixBinauralS16LeToMonoF32(stereoBytes);
            currentWindowMono = mono;
            final maxSliceSec = useQwen3Session ? 12.0 : 26.0;
            final mergeGapSec = useQwen3Session ? 0.45 : 1.8;
            final spans = whisper!.vadSlices(
              mono,
              modelPath: vadModel!,
              nThreads: nThreads,
              maxSegmentSeconds: maxSliceSec,
            );
            final plan = planVadWindowSlices(
              windowStartFrame: windowStartFrame,
              windowFrameCount: mono.length,
              isFinalWindow: isFinalWindow,
              spans: spans,
              mergeGapSeconds: mergeGapSec,
              maxSliceSeconds: maxSliceSec,
            );
            reply!.send([
              true,
              [
                plan.nextFrameOffset,
                [
                  for (final slice in plan.slices)
                    [slice.startFrame, slice.endFrame],
                ],
              ],
            ]);
          case 'transcribeWindowSlice':
            final data = command[2] as List;
            final windowStartFrame = data[0] as int;
            final startFrame = data[1] as int;
            final endFrame = data[2] as int;
            final mono = currentWindowMono;
            if (mono == null ||
                startFrame < 0 ||
                endFrame > mono.length ||
                endFrame <= startFrame) {
              reply!.send([true, const <Object>[]]);
              break;
            }
            final normalized = normalizeWhisperSlice(
              Float32List.sublistView(mono, startFrame, endFrame),
            );
            if (normalized == null) {
              reply!.send([true, const <Object>[]]);
              break;
            }
            final offsetSec = (windowStartFrame + startFrame) / 16000.0;
            final decodedSegments = whisper!.transcribePcm(
              normalized,
              nThreads: nThreads,
              offsetSeconds: offsetSec,
            );
            reply!.send([
              true,
              [
                for (final seg in decodedSegments)
                  [
                    seg.text,
                    seg.startSeconds,
                    seg.endSeconds,
                    seg.noSpeechProb,
                    [
                      for (final word in seg.words)
                        [word.text, word.startSeconds, word.endSeconds],
                    ],
                  ],
              ],
            ]);
        }
      } on SubtitleAlignmentTooLarge {
        reply?.send([false, 'alignment_too_large']);
      } catch (error) {
        reply?.send([false, error.toString()]);
      }
    }
  } catch (error) {
    outgoing.send(error.toString());
  } finally {
    currentWindowMono = null;
    whisper?.dispose();
    asr?.close();
    closeReply?.send([true, null]);
    incoming.close();
  }
}

/// Direct C-ABI binding over `libcrispasr` for Whisper VAD + transcription.
///
/// `package:crispasr`'s high-level `CrispASR.transcribePcm(wordTimestamps: true)`
/// decodes each raw BPE token via `Utf8Pointer.toDartString()`, which throws
/// `FormatException` whenever a multi-byte UTF-8 CJK character is split across
/// byte-level BPE tokens. Reading raw C byte slices and reassembling complete
/// UTF-8 sequences preserves character-level timestamps safely.
class _NativeWhisperRuntime {
  _NativeWhisperRuntime._({
    required DynamicLibrary lib,
    required DynamicLibrary crt,
    Pointer<Void>? ctx,
    Pointer<Void>? session,
  }) : _ctx = ctx ?? nullptr,
       _session = session ?? nullptr,
       _malloc = crt.lookupFunction<
         Pointer<Void> Function(IntPtr),
         Pointer<Void> Function(int)
       >('malloc'),
       _free = crt.lookupFunction<
         Void Function(Pointer<Void>),
         void Function(Pointer<Void>)
       >('free'),
       _whisperFree = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Void Function(Pointer<Void>),
               void Function(Pointer<Void>)
             >('whisper_free'),
       _defaultFullParams = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Pointer<Void> Function(Int32),
               Pointer<Void> Function(int)
             >('whisper_full_default_params_by_ref'),
       _freeFullParams = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Void Function(Pointer<Void>),
               void Function(Pointer<Void>)
             >('whisper_free_params'),
       _fullByRef = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Int32 Function(
                 Pointer<Void>,
                 Pointer<Void>,
                 Pointer<Float>,
                 Int32,
               ),
               int Function(Pointer<Void>, Pointer<Void>, Pointer<Float>, int)
             >('whisper_full_by_ref'),
       _setLanguage = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Void Function(Pointer<Void>, Pointer<Uint8>),
               void Function(Pointer<Void>, Pointer<Uint8>)
             >('crispasr_params_set_language'),
       _setNThreads = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Void Function(Pointer<Void>, Int32),
               void Function(Pointer<Void>, int)
             >('crispasr_params_set_n_threads'),
       _setTokenTimestamps = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Void Function(Pointer<Void>, Int32),
               void Function(Pointer<Void>, int)
             >('crispasr_params_set_token_timestamps'),
       _setNoContext = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Void Function(Pointer<Void>, Int32),
               void Function(Pointer<Void>, int)
             >('crispasr_params_set_no_context'),
       _setPrintRealtime = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Void Function(Pointer<Void>, Int32),
               void Function(Pointer<Void>, int)
             >('crispasr_params_set_print_realtime'),
       _setPrintProgress = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Void Function(Pointer<Void>, Int32),
               void Function(Pointer<Void>, int)
             >('crispasr_params_set_print_progress'),
       _setPrintTimestamps = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Void Function(Pointer<Void>, Int32),
               void Function(Pointer<Void>, int)
             >('crispasr_params_set_print_timestamps'),
       _setPrintSpecial = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Void Function(Pointer<Void>, Int32),
               void Function(Pointer<Void>, int)
             >('crispasr_params_set_print_special'),
       _nSegments = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Int32 Function(Pointer<Void>),
               int Function(Pointer<Void>)
             >('whisper_full_n_segments'),
       _segmentText = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Pointer<Uint8> Function(Pointer<Void>, Int32),
               Pointer<Uint8> Function(Pointer<Void>, int)
             >('whisper_full_get_segment_text'),
       _segmentT0 = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Int64 Function(Pointer<Void>, Int32),
               int Function(Pointer<Void>, int)
             >('whisper_full_get_segment_t0'),
       _segmentT1 = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Int64 Function(Pointer<Void>, Int32),
               int Function(Pointer<Void>, int)
             >('whisper_full_get_segment_t1'),
       _segmentNoSpeechProb = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Float Function(Pointer<Void>, Int32),
               double Function(Pointer<Void>, int)
             >('whisper_full_get_segment_no_speech_prob'),
       _nTokens = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Int32 Function(Pointer<Void>, Int32),
               int Function(Pointer<Void>, int)
             >('whisper_full_n_tokens'),
       _tokenId = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Int32 Function(Pointer<Void>, Int32, Int32),
               int Function(Pointer<Void>, int, int)
             >('whisper_full_get_token_id'),
       _tokenText = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Pointer<Uint8> Function(Pointer<Void>, Int32, Int32),
               Pointer<Uint8> Function(Pointer<Void>, int, int)
             >('whisper_full_get_token_text'),
       _tokenT0 = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Int64 Function(Pointer<Void>, Int32, Int32),
               int Function(Pointer<Void>, int, int)
             >('crispasr_token_t0'),
       _tokenT1 = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Int64 Function(Pointer<Void>, Int32, Int32),
               int Function(Pointer<Void>, int, int)
             >('crispasr_token_t1'),
       _tokenEot = (ctx ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Int32 Function(Pointer<Void>),
               int Function(Pointer<Void>)
             >('whisper_token_eot'),
       _sessionClose = (session ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Void Function(Pointer<Void>),
               void Function(Pointer<Void>)
             >('crispasr_session_close'),
       _sessionTranscribeLang = (session ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Pointer<Void> Function(
                 Pointer<Void>,
                 Pointer<Float>,
                 Int32,
                 Pointer<Uint8>,
               ),
               Pointer<Void> Function(
                 Pointer<Void>,
                 Pointer<Float>,
                 int,
                 Pointer<Uint8>,
               )
             >('crispasr_session_transcribe_lang'),
       _sessionResultNSegments = (session ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Int32 Function(Pointer<Void>),
               int Function(Pointer<Void>)
             >('crispasr_session_result_n_segments'),
       _sessionResultSegmentText = (session ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Pointer<Uint8> Function(Pointer<Void>, Int32),
               Pointer<Uint8> Function(Pointer<Void>, int)
             >('crispasr_session_result_segment_text'),
       _sessionResultSegmentT0 = (session ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Int64 Function(Pointer<Void>, Int32),
               int Function(Pointer<Void>, int)
             >('crispasr_session_result_segment_t0'),
       _sessionResultSegmentT1 = (session ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Int64 Function(Pointer<Void>, Int32),
               int Function(Pointer<Void>, int)
             >('crispasr_session_result_segment_t1'),
       _sessionResultFree = (session ?? nullptr) == nullptr
           ? null
           : lib.lookupFunction<
               Void Function(Pointer<Void>),
               void Function(Pointer<Void>)
             >('crispasr_session_result_free'),
       _vadSlices = lib.lookupFunction<
         Int32 Function(
           Pointer<Uint8>,
           Pointer<Float>,
           Int32,
           Int32,
           Float,
           Int32,
           Int32,
           Int32,
           Float,
           Int32,
           Pointer<Pointer<Float>>,
         ),
         int Function(
           Pointer<Uint8>,
           Pointer<Float>,
           int,
           int,
           double,
           int,
           int,
           int,
           double,
           int,
           Pointer<Pointer<Float>>,
         )
       >('crispasr_vad_slices'),
       _vadFree = lib.lookupFunction<
         Void Function(Pointer<Float>),
         void Function(Pointer<Float>)
       >('crispasr_vad_free');

  factory _NativeWhisperRuntime.open(String modelPath) {
    final lib = DynamicLibrary.open(CrispASR.defaultLibName());
    final crt = Platform.isWindows
        ? DynamicLibrary.open('ucrtbase.dll')
        : DynamicLibrary.process();
    final mallocFn = crt.lookupFunction<
      Pointer<Void> Function(IntPtr),
      Pointer<Void> Function(int)
    >('malloc');
    final freeFn = crt.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)
    >('free');
    final defaultCtxParams = lib.lookupFunction<
      Pointer<Void> Function(),
      Pointer<Void> Function()
    >('whisper_context_default_params_by_ref');
    final freeCtxParams = lib.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)
    >('whisper_free_context_params');
    final initByRef = lib.lookupFunction<
      Pointer<Void> Function(Pointer<Uint8>, Pointer<Void>),
      Pointer<Void> Function(Pointer<Uint8>, Pointer<Void>)
    >('whisper_init_from_file_with_params_by_ref');

    final encodedPath = utf8.encode(modelPath);
    final pathPtr = mallocFn(encodedPath.length + 1).cast<Uint8>();
    if (pathPtr == nullptr) {
      throw StateError('Failed to allocate native model path');
    }
    if (encodedPath.isNotEmpty) {
      pathPtr.asTypedList(encodedPath.length).setAll(0, encodedPath);
    }
    pathPtr[encodedPath.length] = 0;

    final ctxParams = defaultCtxParams();
    Pointer<Void> ctx = nullptr;
    try {
      ctx = initByRef(pathPtr, ctxParams);
    } finally {
      if (ctxParams != nullptr) freeCtxParams(ctxParams);
      freeFn(pathPtr.cast());
    }
    if (ctx == nullptr) {
      throw StateError('Failed to load Whisper model: $modelPath');
    }
    return _NativeWhisperRuntime._(lib: lib, crt: crt, ctx: ctx);
  }

  factory _NativeWhisperRuntime.openSession(
    String modelPath, {
    required String backend,
    required int nThreads,
  }) {
    final lib = DynamicLibrary.open(CrispASR.defaultLibName());
    final crt = Platform.isWindows
        ? DynamicLibrary.open('ucrtbase.dll')
        : DynamicLibrary.process();
    final mallocFn = crt.lookupFunction<
      Pointer<Void> Function(IntPtr),
      Pointer<Void> Function(int)
    >('malloc');
    final freeFn = crt.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)
    >('free');
    final openExplicit = lib.lookupFunction<
      Pointer<Void> Function(Pointer<Uint8>, Pointer<Uint8>, Int32),
      Pointer<Void> Function(Pointer<Uint8>, Pointer<Uint8>, int)
    >('crispasr_session_open_explicit');

    final encodedPath = utf8.encode(modelPath);
    final encodedBackend = utf8.encode(backend);
    final pathPtr = mallocFn(encodedPath.length + 1).cast<Uint8>();
    final backendPtr = mallocFn(encodedBackend.length + 1).cast<Uint8>();
    if (pathPtr == nullptr || backendPtr == nullptr) {
      if (pathPtr != nullptr) freeFn(pathPtr.cast());
      if (backendPtr != nullptr) freeFn(backendPtr.cast());
      throw StateError('Failed to allocate native session open arguments');
    }
    if (encodedPath.isNotEmpty) {
      pathPtr.asTypedList(encodedPath.length).setAll(0, encodedPath);
    }
    pathPtr[encodedPath.length] = 0;
    if (encodedBackend.isNotEmpty) {
      backendPtr.asTypedList(encodedBackend.length).setAll(0, encodedBackend);
    }
    backendPtr[encodedBackend.length] = 0;

    Pointer<Void> session = nullptr;
    try {
      session = openExplicit(pathPtr, backendPtr, nThreads);
    } finally {
      freeFn(pathPtr.cast());
      freeFn(backendPtr.cast());
    }
    if (session == nullptr) {
      throw StateError('Failed to open ASR session ($backend): $modelPath');
    }
    return _NativeWhisperRuntime._(lib: lib, crt: crt, session: session);
  }

  final Pointer<Void> _ctx;
  final Pointer<Void> _session;
  bool _disposed = false;

  final Pointer<Void> Function(int) _malloc;
  final void Function(Pointer<Void>) _free;
  final void Function(Pointer<Void>)? _whisperFree;
  final Pointer<Void> Function(int)? _defaultFullParams;
  final void Function(Pointer<Void>)? _freeFullParams;
  final int Function(Pointer<Void>, Pointer<Void>, Pointer<Float>, int)?
  _fullByRef;
  final void Function(Pointer<Void>, Pointer<Uint8>)? _setLanguage;
  final void Function(Pointer<Void>, int)? _setNThreads;
  final void Function(Pointer<Void>, int)? _setTokenTimestamps;
  final void Function(Pointer<Void>, int)? _setNoContext;
  final void Function(Pointer<Void>, int)? _setPrintRealtime;
  final void Function(Pointer<Void>, int)? _setPrintProgress;
  final void Function(Pointer<Void>, int)? _setPrintTimestamps;
  final void Function(Pointer<Void>, int)? _setPrintSpecial;
  final int Function(Pointer<Void>)? _nSegments;
  final Pointer<Uint8> Function(Pointer<Void>, int)? _segmentText;
  final int Function(Pointer<Void>, int)? _segmentT0;
  final int Function(Pointer<Void>, int)? _segmentT1;
  final double Function(Pointer<Void>, int)? _segmentNoSpeechProb;
  final int Function(Pointer<Void>, int)? _nTokens;
  final int Function(Pointer<Void>, int, int)? _tokenId;
  final Pointer<Uint8> Function(Pointer<Void>, int, int)? _tokenText;
  final int Function(Pointer<Void>, int, int)? _tokenT0;
  final int Function(Pointer<Void>, int, int)? _tokenT1;
  final int Function(Pointer<Void>)? _tokenEot;
  final void Function(Pointer<Void>)? _sessionClose;
  final Pointer<Void> Function(
    Pointer<Void>,
    Pointer<Float>,
    int,
    Pointer<Uint8>,
  )?
  _sessionTranscribeLang;
  final int Function(Pointer<Void>)? _sessionResultNSegments;
  final Pointer<Uint8> Function(Pointer<Void>, int)? _sessionResultSegmentText;
  final int Function(Pointer<Void>, int)? _sessionResultSegmentT0;
  final int Function(Pointer<Void>, int)? _sessionResultSegmentT1;
  final void Function(Pointer<Void>)? _sessionResultFree;
  final int Function(
    Pointer<Uint8>,
    Pointer<Float>,
    int,
    int,
    double,
    int,
    int,
    int,
    double,
    int,
    Pointer<Pointer<Float>>,
  )
  _vadSlices;
  final void Function(Pointer<Float>) _vadFree;

  Pointer<Uint8> _allocCString(String value) {
    final encoded = utf8.encode(value);
    final ptr = _malloc(encoded.length + 1).cast<Uint8>();
    if (ptr == nullptr) throw StateError('Native C string allocation failed');
    if (encoded.isNotEmpty) {
      ptr.asTypedList(encoded.length).setAll(0, encoded);
    }
    ptr[encoded.length] = 0;
    return ptr;
  }

  static Uint8List _readCStringBytes(Pointer<Uint8> ptr) {
    if (ptr == nullptr) return Uint8List(0);
    var length = 0;
    while (ptr[length] != 0) {
      length++;
    }
    if (length == 0) return Uint8List(0);
    return Uint8List.fromList(ptr.asTypedList(length));
  }

  List<AsrVadSpan> vadSlices(
    Float32List pcm, {
    required String modelPath,
    required int nThreads,
    double maxSegmentSeconds = 26.0,
  }) {
    if (_disposed) throw StateError('ASR runtime is disposed');
    if (pcm.isEmpty) return const <AsrVadSpan>[];
    final samples = _malloc(pcm.length * sizeOf<Float>()).cast<Float>();
    if (samples == nullptr) throw StateError('Native PCM allocation failed');
    samples.asTypedList(pcm.length).setAll(0, pcm);
    final modelPtr = _allocCString(modelPath);
    final outPtr = _malloc(sizeOf<Pointer<Float>>()).cast<Pointer<Float>>();
    if (outPtr == nullptr) {
      _free(modelPtr.cast());
      _free(samples.cast());
      throw StateError('Native VAD pointer allocation failed');
    }
    outPtr.value = nullptr;
    try {
      final count = _vadSlices(
        modelPtr,
        samples,
        pcm.length,
        16000,
        0.0,
        200,
        250,
        120,
        maxSegmentSeconds,
        nThreads,
        outPtr,
      );
      if (count < 0) throw StateError('VAD slices failed ($count)');
      if (count == 0) return const <AsrVadSpan>[];
      final data = outPtr.value;
      if (data == nullptr) return const <AsrVadSpan>[];
      try {
        final raw = data.asTypedList(count * 2);
        return List<AsrVadSpan>.generate(
          count,
          (i) => AsrVadSpan(startSeconds: raw[2 * i], endSeconds: raw[2 * i + 1]),
          growable: false,
        );
      } finally {
        _vadFree(data);
      }
    } finally {
      _free(outPtr.cast());
      _free(modelPtr.cast());
      _free(samples.cast());
    }
  }

  List<AsrRawSegment> transcribePcm(
    Float32List pcm, {
    required int nThreads,
    required double offsetSeconds,
  }) {
    if (_disposed) throw StateError('ASR runtime is disposed');
    if (pcm.isEmpty) return const <AsrRawSegment>[];
    if (_session != nullptr) {
      return _transcribeSessionPcm(pcm, offsetSeconds: offsetSeconds);
    }
    final samples = _malloc(pcm.length * sizeOf<Float>()).cast<Float>();
    if (samples == nullptr) throw StateError('Native PCM allocation failed');
    samples.asTypedList(pcm.length).setAll(0, pcm);
    final params = _defaultFullParams!(0);
    if (params == nullptr) {
      _free(samples.cast());
      throw StateError('Whisper params allocation failed');
    }
    final langPtr = _allocCString('ja');
    try {
      _setPrintRealtime!(params, 0);
      _setPrintProgress!(params, 0);
      _setPrintTimestamps!(params, 0);
      _setPrintSpecial!(params, 0);
      _setNThreads!(params, nThreads);
      _setLanguage!(params, langPtr);
      _setTokenTimestamps!(params, 1);
      _setNoContext!(params, 1);

      final rc = _fullByRef!(_ctx, params, samples, pcm.length);
      if (rc != 0) throw StateError('Whisper transcription failed ($rc)');

      final eotId = _tokenEot!(_ctx);
      final segmentCount = _nSegments!(_ctx);
      final segments = <AsrRawSegment>[];
      for (var i = 0; i < segmentCount; i++) {
        final textBytes = _readCStringBytes(_segmentText!(_ctx, i));
        final text = utf8
            .decode(textBytes, allowMalformed: true)
            .replaceAll('\uFFFD', '');
        final startSec = offsetSeconds + _segmentT0!(_ctx, i) / 100.0;
        final endSec = offsetSeconds + _segmentT1!(_ctx, i) / 100.0;
        final noSpeechProb = _segmentNoSpeechProb!(_ctx, i);

        final tokenCount = _nTokens!(_ctx, i);
        final rawTokens = <AsrRawTokenBytes>[];
        for (var k = 0; k < tokenCount; k++) {
          final tokId = _tokenId!(_ctx, i, k);
          if (eotId > 0 && tokId >= eotId) continue;
          final tokBytes = _readCStringBytes(_tokenText!(_ctx, i, k));
          if (tokBytes.isEmpty) continue;
          rawTokens.add((
            bytes: tokBytes,
            startSeconds: offsetSeconds + _tokenT0!(_ctx, i, k) / 100.0,
            endSeconds: offsetSeconds + _tokenT1!(_ctx, i, k) / 100.0,
          ));
        }

        segments.add(
          AsrRawSegment(
            text: text,
            startSeconds: startSec,
            endSeconds: endSec,
            noSpeechProb: noSpeechProb,
            words: assembleUtf8AsrTokenWords(rawTokens),
          ),
        );
      }
      return segments;
    } finally {
      _freeFullParams!(params);
      _free(langPtr.cast());
      _free(samples.cast());
    }
  }

  List<AsrRawSegment> _transcribeSessionPcm(
    Float32List pcm, {
    required double offsetSeconds,
  }) {
    final samples = _malloc(pcm.length * sizeOf<Float>()).cast<Float>();
    if (samples == nullptr) throw StateError('Native PCM allocation failed');
    samples.asTypedList(pcm.length).setAll(0, pcm);
    final langPtr = _allocCString('ja');
    Pointer<Void> res = nullptr;
    try {
      res = _sessionTranscribeLang!(_session, samples, pcm.length, langPtr);
    } finally {
      _free(langPtr.cast());
      _free(samples.cast());
    }
    if (res == nullptr) {
      throw StateError('ASR session transcription failed');
    }
    try {
      final segmentCount = _sessionResultNSegments!(res);
      final segments = <AsrRawSegment>[];
      for (var i = 0; i < segmentCount; i++) {
        final textBytes = _readCStringBytes(_sessionResultSegmentText!(res, i));
        final text = utf8
            .decode(textBytes, allowMalformed: true)
            .replaceAll('\uFFFD', '')
            .trim();
        if (text.isEmpty) continue;
        final startSec = offsetSeconds + _sessionResultSegmentT0!(res, i) / 100.0;
        final endSec = offsetSeconds + _sessionResultSegmentT1!(res, i) / 100.0;
        segments.add(
          AsrRawSegment(
            text: text,
            startSeconds: startSec,
            endSeconds: endSec,
            noSpeechProb: 0.0,
          ),
        );
      }
      return segments;
    } finally {
      _sessionResultFree!(res);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_session != nullptr) {
      _sessionClose!(_session);
    }
    if (_ctx != nullptr) {
      _whisperFree!(_ctx);
    }
  }
}
