import 'dart:async';
import 'dart:io';

import 'package:doujin_audio/features/video_converter/application/video_conversion_plan.dart';
import 'package:doujin_audio/features/video_converter/application/video_conversion_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'audio_player_conversion_runner_',
    );
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  Future<VideoConversionPlan> plan() => createVideoConversionPlan(
    inputPath: '${directory.path}/clip.mp4',
    outputDirectoryPath: directory.path,
    format: 'mp3',
    bitrate: '192k',
  );

  test(
    'successful conversion atomically publishes the temporary file',
    () async {
      final conversionPlan = await plan();
      final runner = VideoConversionRunner(
        executor:
            ({
              required command,
              required durationMs,
              required onProgress,
            }) async {
              await File(
                conversionPlan.temporaryOutputPath,
              ).writeAsString('audio');
              return const VideoConversionExecutionResult.success();
            },
      );

      final result = await runner.convert(
        plan: conversionPlan,
        durationMs: 1000,
        onProgress: (_) {},
      );

      expect(result.status, VideoConversionStatus.success);
      expect(result.outputPath, conversionPlan.outputPath);
      expect(await File(conversionPlan.outputPath).readAsString(), 'audio');
      expect(await File(conversionPlan.temporaryOutputPath).exists(), isFalse);
    },
  );

  test(
    'failed and canceled conversions remove partial temporary files',
    () async {
      for (final executionResult in <VideoConversionExecutionResult>[
        const VideoConversionExecutionResult.failed('failed'),
        const VideoConversionExecutionResult.canceled(),
      ]) {
        final conversionPlan = await plan();
        final runner = VideoConversionRunner(
          executor:
              ({
                required command,
                required durationMs,
                required onProgress,
              }) async {
                await File(
                  conversionPlan.temporaryOutputPath,
                ).writeAsString('partial');
                return executionResult;
              },
        );

        final result = await runner.convert(
          plan: conversionPlan,
          durationMs: 1000,
          onProgress: (_) {},
        );

        expect(result.status, executionResult.status);
        expect(
          await File(conversionPlan.temporaryOutputPath).exists(),
          isFalse,
        );
        expect(await File(conversionPlan.outputPath).exists(), isFalse);
      }
    },
  );

  test('empty successful output is treated as a failure and removed', () async {
    final conversionPlan = await plan();
    final runner = VideoConversionRunner(
      executor:
          ({required command, required durationMs, required onProgress}) async {
            await File(conversionPlan.temporaryOutputPath).create();
            return const VideoConversionExecutionResult.success();
          },
    );

    final result = await runner.convert(
      plan: conversionPlan,
      durationMs: 1000,
      onProgress: (_) {},
    );

    expect(result.status, VideoConversionStatus.failed);
    expect(await File(conversionPlan.temporaryOutputPath).exists(), isFalse);
    expect(await File(conversionPlan.outputPath).exists(), isFalse);
  });

  test(
    'cancel waits for execution shutdown and removes partial output',
    () async {
      final conversionPlan = await plan();
      final executionStarted = Completer<void>();
      final executionResult = Completer<VideoConversionExecutionResult>();
      final runner = VideoConversionRunner(
        executor:
            ({
              required command,
              required durationMs,
              required onProgress,
            }) async {
              await File(
                conversionPlan.temporaryOutputPath,
              ).writeAsString('partial');
              executionStarted.complete();
              return executionResult.future;
            },
        cancelExecutor: () async {
          executionResult.complete(
            const VideoConversionExecutionResult.canceled(),
          );
        },
      );
      final conversion = runner.convert(
        plan: conversionPlan,
        durationMs: 1000,
        onProgress: (_) {},
      );
      await executionStarted.future;

      await runner.cancel();
      final result = await conversion;

      expect(result.status, VideoConversionStatus.canceled);
      expect(await File(conversionPlan.temporaryOutputPath).exists(), isFalse);
      expect(await File(conversionPlan.outputPath).exists(), isFalse);
    },
  );

  test('commit preserves a final file created while conversion runs', () async {
    final conversionPlan = await plan();
    final runner = VideoConversionRunner(
      executor:
          ({required command, required durationMs, required onProgress}) async {
            await File(
              conversionPlan.temporaryOutputPath,
            ).writeAsString('audio');
            await File(conversionPlan.outputPath).writeAsString('existing');
            return const VideoConversionExecutionResult.success();
          },
    );

    final result = await runner.convert(
      plan: conversionPlan,
      durationMs: 1000,
      onProgress: (_) {},
    );

    expect(await File(conversionPlan.outputPath).readAsString(), 'existing');
    expect(result.outputPath, endsWith('clip (1).mp3'));
    expect(await File(result.outputPath!).readAsString(), 'audio');
  });
}
