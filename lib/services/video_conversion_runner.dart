import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_audio/statistics.dart';
import 'package:flutter/foundation.dart';

import '../platform/app_platform.dart';
import 'video_conversion_plan.dart';
import 'windows_ffmpeg_service.dart';

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
  Process? _windowsProcess;

  Future<int> readDurationMs(String videoPath) async {
    if (AppPlatform.isWindows) {
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
    if (AppPlatform.isWindows) {
      return _convertWithWindowsFfmpeg(
        plan: plan,
        durationMs: durationMs,
        onProgress: onProgress,
      );
    }
    return _convertWithFfmpegKit(
      plan: plan,
      durationMs: durationMs,
      onProgress: onProgress,
    );
  }

  void cancel() {
    if (AppPlatform.isWindows) {
      _windowsProcess?.kill();
      _windowsProcess = null;
      return;
    }
    FFmpegKit.cancel();
  }

  Future<VideoConversionResult> _convertWithWindowsFfmpeg({
    required VideoConversionPlan plan,
    required int durationMs,
    required VideoConversionProgress onProgress,
  }) async {
    if (!WindowsFfmpegService.isAvailable) {
      return const VideoConversionResult.failed('ffmpeg_not_available');
    }

    try {
      _windowsProcess = await Process.start(WindowsFfmpegService.ffmpegPath, [
        '-y',
        ...plan.commandArgs,
      ]);
      _windowsProcess!.stderr.transform(utf8.decoder).listen((data) {
        if (durationMs <= 0) return;
        final timeInMilliseconds = parseFfmpegProgressTimeMs(data);
        if (timeInMilliseconds <= 0) return;
        onProgress((timeInMilliseconds / durationMs).clamp(0.0, 1.0));
      });

      final process = _windowsProcess;
      final returnCode = await process!.exitCode;
      final wasCanceled = _windowsProcess == null;
      _windowsProcess = null;

      if (returnCode == 0 && !wasCanceled) {
        return const VideoConversionResult.success();
      }
      if (wasCanceled) {
        return const VideoConversionResult.canceled();
      }
      return VideoConversionResult.failed('exit_code=$returnCode');
    } catch (error) {
      _windowsProcess = null;
      return VideoConversionResult.failed(error.toString());
    }
  }

  Future<VideoConversionResult> _convertWithFfmpegKit({
    required VideoConversionPlan plan,
    required int durationMs,
    required VideoConversionProgress onProgress,
  }) async {
    final completer = Completer<VideoConversionResult>();

    FFmpegKitConfig.enableStatisticsCallback((Statistics statistics) {
      if (durationMs <= 0) return;
      final timeInMilliseconds = statistics.getTime();
      onProgress((timeInMilliseconds / durationMs).clamp(0.0, 1.0));
    });

    await FFmpegKit.executeAsync(plan.command, (session) async {
      final returnCode = await session.getReturnCode();
      if (ReturnCode.isSuccess(returnCode)) {
        completer.complete(const VideoConversionResult.success());
      } else if (ReturnCode.isCancel(returnCode)) {
        completer.complete(const VideoConversionResult.canceled());
      } else {
        final logs = await session.getLogsAsString();
        completer.complete(VideoConversionResult.failed(logs));
      }
    });

    return completer.future;
  }
}
