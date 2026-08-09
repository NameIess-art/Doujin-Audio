import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_audio/statistics.dart';
import 'package:path/path.dart' as path;

import 'video_conversion_plan.dart';

typedef VideoConversionProgress = void Function(double progress);

enum VideoConversionStatus { success, canceled, failed }

class VideoConversionResult {
  const VideoConversionResult._(
    this.status, {
    this.outputPath,
    this.errorMessage,
  });

  const VideoConversionResult.success(String outputPath)
    : this._(VideoConversionStatus.success, outputPath: outputPath);

  const VideoConversionResult.canceled()
    : this._(VideoConversionStatus.canceled);

  const VideoConversionResult.failed([String? errorMessage])
    : this._(VideoConversionStatus.failed, errorMessage: errorMessage);

  final VideoConversionStatus status;
  final String? outputPath;
  final String? errorMessage;
}

class VideoConversionExecutionResult {
  const VideoConversionExecutionResult._(this.status, [this.errorMessage]);

  const VideoConversionExecutionResult.success()
    : this._(VideoConversionStatus.success);

  const VideoConversionExecutionResult.canceled()
    : this._(VideoConversionStatus.canceled);

  const VideoConversionExecutionResult.failed([String? errorMessage])
    : this._(VideoConversionStatus.failed, errorMessage);

  final VideoConversionStatus status;
  final String? errorMessage;
}

typedef VideoConversionExecutor =
    Future<VideoConversionExecutionResult> Function({
      required String command,
      required int durationMs,
      required VideoConversionProgress onProgress,
    });

class VideoConversionRunner {
  VideoConversionRunner({
    VideoConversionExecutor? executor,
    Future<void> Function()? cancelExecutor,
  }) : _executor = executor,
       _cancelExecutor = cancelExecutor;

  final VideoConversionExecutor? _executor;
  final Future<void> Function()? _cancelExecutor;
  Future<VideoConversionResult>? _activeConversion;
  int _nextRunId = 0;
  int? _activeRunId;
  int? _cancelRequestedRunId;

  Future<int> readDurationMs(String videoPath) async {
    final mediaInformation = await FFprobeKit.getMediaInformation(videoPath);
    final information = mediaInformation.getMediaInformation();
    return parseVideoDurationMs(information?.getDuration());
  }

  Future<VideoConversionResult> convert({
    required VideoConversionPlan plan,
    required int durationMs,
    required VideoConversionProgress onProgress,
  }) {
    if (_activeConversion != null) {
      return Future<VideoConversionResult>.value(
        const VideoConversionResult.failed('conversion_already_running'),
      );
    }
    final runId = ++_nextRunId;
    _activeRunId = runId;
    final operation = _runConversion(
      runId: runId,
      plan: plan,
      durationMs: durationMs,
      onProgress: onProgress,
    );
    late final Future<VideoConversionResult> tracked;
    tracked = operation.whenComplete(() {
      if (identical(_activeConversion, tracked)) {
        _activeConversion = null;
        if (_activeRunId == runId) {
          _activeRunId = null;
        }
      }
      if (_cancelRequestedRunId == runId) {
        _cancelRequestedRunId = null;
      }
    });
    _activeConversion = tracked;
    return tracked;
  }

  Future<void> cancel() async {
    final runId = _activeRunId;
    final activeConversion = _activeConversion;
    if (runId == null || activeConversion == null) return;
    _cancelRequestedRunId = runId;
    final cancelExecutor = _cancelExecutor;
    if (cancelExecutor != null) {
      await cancelExecutor();
    } else {
      await FFmpegKit.cancel();
    }
    try {
      await activeConversion;
    } catch (_) {
      // The convert caller receives the original failure. Cancellation only
      // waits for the active run to release its resources.
    }
  }

  Future<VideoConversionResult> _runConversion({
    required int runId,
    required VideoConversionPlan plan,
    required int durationMs,
    required VideoConversionProgress onProgress,
  }) async {
    var committed = false;
    late VideoConversionResult result;
    try {
      if (_cancelRequestedRunId == runId) {
        result = const VideoConversionResult.canceled();
      } else {
        final executor = _executor;
        final executionResult = executor != null
            ? await executor(
                command: plan.command,
                durationMs: durationMs,
                onProgress: onProgress,
              )
            : await _convertWithFfmpegKit(
                runId: runId,
                command: plan.command,
                durationMs: durationMs,
                onProgress: onProgress,
              );
        if (_cancelRequestedRunId == runId ||
            executionResult.status == VideoConversionStatus.canceled) {
          result = const VideoConversionResult.canceled();
        } else if (executionResult.status == VideoConversionStatus.failed) {
          result = VideoConversionResult.failed(executionResult.errorMessage);
        } else {
          final outputPath = await _commitOutput(plan);
          committed = true;
          result = VideoConversionResult.success(outputPath);
        }
      }
    } catch (error) {
      result = _cancelRequestedRunId == runId
          ? const VideoConversionResult.canceled()
          : VideoConversionResult.failed(error.toString());
    }

    if (!committed) {
      try {
        await _deleteTemporaryOutput(plan.temporaryOutputPath);
      } catch (error) {
        return VideoConversionResult.failed(error.toString());
      }
    }
    return result;
  }

  Future<VideoConversionExecutionResult> _convertWithFfmpegKit({
    required int runId,
    required String command,
    required int durationMs,
    required VideoConversionProgress onProgress,
  }) async {
    if (_cancelRequestedRunId == runId) {
      return const VideoConversionExecutionResult.canceled();
    }
    final completer = Completer<VideoConversionExecutionResult>();

    try {
      final session = await FFmpegKit.executeAsync(
        command,
        (session) async {
          if (completer.isCompleted) return;
          final returnCode = await session.getReturnCode();
          if (_cancelRequestedRunId == runId ||
              ReturnCode.isCancel(returnCode)) {
            completer.complete(const VideoConversionExecutionResult.canceled());
          } else if (ReturnCode.isSuccess(returnCode)) {
            completer.complete(const VideoConversionExecutionResult.success());
          } else {
            final logs = await session.getLogsAsString();
            completer.complete(VideoConversionExecutionResult.failed(logs));
          }
        },
        null,
        (Statistics statistics) {
          if (durationMs <= 0 || _cancelRequestedRunId == runId) return;
          final timeInMilliseconds = statistics.getTime();
          onProgress((timeInMilliseconds / durationMs).clamp(0.0, 1.0));
        },
      );
      if (_cancelRequestedRunId == runId) {
        await FFmpegKit.cancel(session.getSessionId());
      }
      return await completer.future;
    } catch (error) {
      if (_cancelRequestedRunId == runId) {
        return const VideoConversionExecutionResult.canceled();
      }
      return VideoConversionExecutionResult.failed(error.toString());
    }
  }

  Future<String> _commitOutput(VideoConversionPlan plan) async {
    final temporaryFile = File(plan.temporaryOutputPath);
    if (!await temporaryFile.exists() || await temporaryFile.length() <= 0) {
      throw const FileSystemException(
        'FFmpeg did not produce a non-empty temporary output.',
      );
    }

    var candidatePath = plan.outputPath;
    while (true) {
      if (await File(candidatePath).exists()) {
        candidatePath = await resolveVideoConversionOutputPath(
          outputDirectoryPath: path.dirname(plan.outputPath),
          fileNameNoExt: path.basenameWithoutExtension(plan.inputPath),
          format: plan.format,
        );
      }
      try {
        await temporaryFile.rename(candidatePath);
        return candidatePath;
      } on FileSystemException {
        if (!await File(candidatePath).exists()) rethrow;
      }
    }
  }

  Future<void> _deleteTemporaryOutput(String temporaryOutputPath) async {
    final temporaryFile = File(temporaryOutputPath);
    if (await temporaryFile.exists()) {
      await temporaryFile.delete();
    }
  }
}
