import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_audio/statistics.dart';
import 'package:flutter/foundation.dart';

import '../platform/app_platform.dart';
import 'video_conversion_plan.dart';
import 'windows_ffmpeg_service.dart';

typedef VideoConversionProgress = void Function(double progress);
typedef VideoProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

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
  VideoConversionRunner({
    VideoProcessStarter? windowsProcessStarter,
    bool Function()? isWindows,
    bool Function()? isWindowsFfmpegAvailable,
  }) : _startWindowsProcess = windowsProcessStarter ?? Process.start,
       _isWindows = isWindows ?? (() => AppPlatform.isWindows),
       _isWindowsFfmpegAvailable =
           isWindowsFfmpegAvailable ?? (() => WindowsFfmpegService.isAvailable);

  final VideoProcessStarter _startWindowsProcess;
  final bool Function() _isWindows;
  final bool Function() _isWindowsFfmpegAvailable;

  Process? _windowsProcess;
  Future<int>? _windowsExitFuture;
  Future<VideoConversionResult>? _activeConversion;
  int _nextRunId = 0;
  int? _activeRunId;
  int? _cancelRequestedRunId;

  Future<int> readDurationMs(String videoPath) async {
    if (_isWindows()) {
      try {
        final result = await Process.run(WindowsFfmpegService.ffprobePath, [
          '-v',
          'error',
          '-show_entries',
          'format=duration',
          '-of',
          'default=noprint_wrappers=1:nokey=1',
          videoPath,
        ]);
        if (result.exitCode == 0) {
          return parseVideoDurationMs(result.stdout.toString().trim());
        }
      } catch (error) {
        debugPrint('Windows ffprobe error: $error');
      }
      return 0;
    }

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
    final operation = _isWindows()
        ? _convertWithWindowsFfmpeg(
            runId: runId,
            plan: plan,
            durationMs: durationMs,
            onProgress: onProgress,
          )
        : _convertWithFfmpegKit(
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
    Object? cancellationError;
    StackTrace? cancellationStackTrace;
    try {
      if (_isWindows()) {
        _windowsProcess?.kill();
      } else {
        await FFmpegKit.cancel();
      }
    } catch (error, stackTrace) {
      cancellationError = error;
      cancellationStackTrace = stackTrace;
    }
    try {
      await activeConversion;
    } catch (_) {
      // The convert caller receives the original failure. Cancellation only
      // waits for the active run to release its resources.
    }
    if (cancellationError != null) {
      Error.throwWithStackTrace(cancellationError, cancellationStackTrace!);
    }
  }

  Future<VideoConversionResult> _convertWithWindowsFfmpeg({
    required int runId,
    required VideoConversionPlan plan,
    required int durationMs,
    required VideoConversionProgress onProgress,
  }) async {
    if (!_isWindowsFfmpegAvailable()) {
      return const VideoConversionResult.failed('ffmpeg_not_available');
    }

    Process? process;
    Future<int>? exitFuture;
    StreamSubscription<List<int>>? stdoutSubscription;
    StreamSubscription<String>? stderrSubscription;
    try {
      if (_cancelRequestedRunId == runId) {
        return const VideoConversionResult.canceled();
      }
      process = await _startWindowsProcess(WindowsFfmpegService.ffmpegPath, [
        '-y',
        ...plan.commandArgs,
      ]);
      exitFuture = process.exitCode;
      _windowsProcess = process;
      _windowsExitFuture = exitFuture;
      stdoutSubscription = process.stdout.listen((_) {});
      stderrSubscription = process.stderr.transform(utf8.decoder).listen((
        data,
      ) {
        if (durationMs <= 0) return;
        final timeInMilliseconds = parseFfmpegProgressTimeMs(data);
        if (timeInMilliseconds <= 0) return;
        onProgress((timeInMilliseconds / durationMs).clamp(0.0, 1.0));
      });
      if (_cancelRequestedRunId == runId) {
        process.kill();
      }

      final returnCode = await exitFuture;
      final wasCanceled = _cancelRequestedRunId == runId;

      if (returnCode == 0 && !wasCanceled) {
        return const VideoConversionResult.success();
      }
      if (wasCanceled) {
        return const VideoConversionResult.canceled();
      }
      return VideoConversionResult.failed('exit_code=$returnCode');
    } catch (error) {
      if (_cancelRequestedRunId == runId) {
        return const VideoConversionResult.canceled();
      }
      return VideoConversionResult.failed(error.toString());
    } finally {
      await stdoutSubscription?.cancel();
      await stderrSubscription?.cancel();
      if (identical(_windowsProcess, process)) {
        _windowsProcess = null;
      }
      if (identical(_windowsExitFuture, exitFuture)) {
        _windowsExitFuture = null;
      }
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
