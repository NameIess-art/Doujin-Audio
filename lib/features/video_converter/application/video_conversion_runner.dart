import 'dart:async';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_audio/statistics.dart';

import 'video_conversion_plan.dart';

typedef VideoConversionProgress = void Function(double progress);

enum VideoConversionStatus { success, canceled, failed }

class VideoConversionResult {
  const VideoConversionResult._(this.status, [this.errorMessage]);

  const VideoConversionResult.success() : this._(VideoConversionStatus.success);

  const VideoConversionResult.canceled()
    : this._(VideoConversionStatus.canceled);

  const VideoConversionResult.failed([String? errorMessage])
    : this._(VideoConversionStatus.failed, errorMessage);

  final VideoConversionStatus status;
  final String? errorMessage;
}

class VideoConversionRunner {
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
    final operation = _convertWithFfmpegKit(
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
    await FFmpegKit.cancel();
    try {
      await activeConversion;
    } catch (_) {
      // The convert caller receives the original failure. Cancellation only
      // waits for the active run to release its resources.
    }
  }

  Future<VideoConversionResult> _convertWithFfmpegKit({
    required int runId,
    required VideoConversionPlan plan,
    required int durationMs,
    required VideoConversionProgress onProgress,
  }) async {
    if (_cancelRequestedRunId == runId) {
      return const VideoConversionResult.canceled();
    }
    final completer = Completer<VideoConversionResult>();

    try {
      final session = await FFmpegKit.executeAsync(
        plan.command,
        (session) async {
          if (completer.isCompleted) return;
          final returnCode = await session.getReturnCode();
          if (_cancelRequestedRunId == runId ||
              ReturnCode.isCancel(returnCode)) {
            completer.complete(const VideoConversionResult.canceled());
          } else if (ReturnCode.isSuccess(returnCode)) {
            completer.complete(const VideoConversionResult.success());
          } else {
            final logs = await session.getLogsAsString();
            completer.complete(VideoConversionResult.failed(logs));
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
        return const VideoConversionResult.canceled();
      }
      return VideoConversionResult.failed(error.toString());
    }
  }
}
