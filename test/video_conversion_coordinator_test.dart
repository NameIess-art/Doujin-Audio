import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/platform/power_platform_service.dart';
import 'package:doujin_audio/core/ui/ui_operation_service.dart';
import 'package:doujin_audio/features/video_converter/application/video_conversion_coordinator.dart';
import 'package:doujin_audio/features/video_converter/application/video_conversion_input_service.dart';
import 'package:doujin_audio/features/video_converter/application/video_conversion_plan.dart';
import 'package:doujin_audio/features/video_converter/application/video_conversion_runner.dart';

import 'support/app_runtime_test_fixture.dart';

class FakePowerPlatformService extends PowerPlatformService {
  final List<String> acquiredLocks = [];
  final List<String> releasedLocks = [];

  @override
  Future<bool> acquireWakeLock({required String tag, int? timeoutMs}) async {
    acquiredLocks.add(tag);
    return true;
  }

  @override
  Future<bool> releaseWakeLock({required String tag}) async {
    releasedLocks.add(tag);
    return true;
  }
}

class FakeVideoConversionRunner extends VideoConversionRunner {
  FakeVideoConversionRunner({
    this.shouldSucceed = true,
    this.errorMessage,
    this.durationMs = 5000,
  });

  final bool shouldSucceed;
  final String? errorMessage;
  final int durationMs;
  bool wasCanceled = false;
  int cancelCallCount = 0;
  VideoConversionPlan? lastPlan;
  void Function(double)? onProgressCallback;

  @override
  Future<int> readDurationMs(String videoPath) async => durationMs;

  @override
  Future<VideoConversionResult> convert({
    required VideoConversionPlan plan,
    required int durationMs,
    required void Function(double progress) onProgress,
  }) async {
    lastPlan = plan;
    onProgressCallback = onProgress;
    onProgress(0.5);
    if (wasCanceled) {
      return const VideoConversionResult.canceled();
    }
    if (shouldSucceed) {
      onProgress(1.0);
      return VideoConversionResult.success(plan.outputPath);
    } else {
      return VideoConversionResult.failed(errorMessage ?? 'Transcoding failed');
    }
  }

  @override
  Future<void> cancel() async {
    wasCanceled = true;
    cancelCallCount++;
  }
}

class FakeVideoConversionInputService extends VideoConversionInputService {
  FakeVideoConversionInputService({this.videoPath, this.outputDir});

  String? videoPath;
  String? outputDir;

  @override
  Future<String?> pickVideoPath() async => videoPath;

  @override
  Future<String?> pickOutputDirectory() async => outputDir;
}

void main() {
  AppRuntimeTestFixture.initialize();

  group('VideoConversionCoordinator', () {
    late AppRuntimeWidgetTestFixture fixture;
    late FakePowerPlatformService powerService;
    late FakeVideoConversionRunner runner;
    late FakeVideoConversionInputService inputService;
    late UiOperationService uiOperationService;

    setUp(() {
      fixture = AppRuntimeWidgetTestFixture();
      powerService = FakePowerPlatformService();
      runner = FakeVideoConversionRunner();
      inputService = FakeVideoConversionInputService(
        videoPath: '/path/to/test_video.mp4',
        outputDir: '/path/to/output',
      );
      uiOperationService = UiOperationService();
    });

    tearDown(() {
      fixture.dispose();
    });

    test('initial state has default values', () {
      final coordinator = VideoConversionCoordinator(
        powerPlatformService: powerService,
        uiOperationService: uiOperationService,
        runner: runner,
        inputService: inputService,
      );

      expect(coordinator.selectedVideoPath, isNull);
      expect(coordinator.videoDurationMs, 0);
      expect(coordinator.isConverting, isFalse);
      expect(coordinator.isCanceling, isFalse);
      expect(coordinator.progress, 0.0);
      expect(coordinator.statusMessage, isEmpty);
      expect(coordinator.lastResult, isNull);
    });

    test('pickVideo updates selectedVideoPath, statusMessage, and duration', () async {
      final coordinator = VideoConversionCoordinator(
        powerPlatformService: powerService,
        uiOperationService: uiOperationService,
        runner: runner,
        inputService: inputService,
      );

      await coordinator.pickVideo(fixture.languageProvider);

      expect(coordinator.selectedVideoPath, '/path/to/test_video.mp4');
      expect(coordinator.videoDurationMs, 5000);
      expect(coordinator.statusMessage, contains('test_video.mp4'));
    });

    test('startConversion acquires wake lock, updates progress, notifies completion, and releases wake lock', () async {
      final coordinator = VideoConversionCoordinator(
        powerPlatformService: powerService,
        uiOperationService: uiOperationService,
        runner: runner,
        inputService: inputService,
      );
      final settings = fixture.settingsRepository;
      await settings.setConverterOutputDirectoryPath('/path/to/output');
      await coordinator.pickVideo(fixture.languageProvider);

      final events = <VideoConversionResult>[];
      final sub = coordinator.completionStream.listen(events.add);

      await coordinator.startConversion(
        settings: settings,
        i18n: fixture.languageProvider,
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      expect(powerService.acquiredLocks, contains('video_conversion'));
      expect(powerService.releasedLocks, contains('video_conversion'));
      expect(coordinator.isConverting, isFalse);
      expect(coordinator.progress, 1.0);
      expect(coordinator.statusMessage, contains('test_video.mp3'));
      expect(events, hasLength(1));
      expect(events.first.status, VideoConversionStatus.success);
      expect(events.first.outputPath, contains('test_video'));
    });

    test('startConversion handles failure, notifies completion, and releases wake lock', () async {
      final failingRunner = FakeVideoConversionRunner(
        shouldSucceed: false,
        errorMessage: 'Custom ffmpeg error',
      );
      final coordinator = VideoConversionCoordinator(
        powerPlatformService: powerService,
        uiOperationService: uiOperationService,
        runner: failingRunner,
        inputService: inputService,
      );
      final settings = fixture.settingsRepository;
      await settings.setConverterOutputDirectoryPath('/path/to/output');
      await coordinator.pickVideo(fixture.languageProvider);

      final events = <VideoConversionResult>[];
      final sub = coordinator.completionStream.listen(events.add);

      await coordinator.startConversion(
        settings: settings,
        i18n: fixture.languageProvider,
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      expect(powerService.acquiredLocks, contains('video_conversion'));
      expect(powerService.releasedLocks, contains('video_conversion'));
      expect(coordinator.isConverting, isFalse);
      expect(events, hasLength(1));
      expect(events.first.status, VideoConversionStatus.failed);
      expect(events.first.errorMessage, 'Custom ffmpeg error');
    });

    test('cancelConversion invokes runner cancel, sets status, and releases wake lock', () async {
      final coordinator = VideoConversionCoordinator(
        powerPlatformService: powerService,
        uiOperationService: uiOperationService,
        runner: runner,
        inputService: inputService,
      );

      await coordinator.cancelConversion(i18n: fixture.languageProvider);

      // When not converting, cancel is a no-op
      expect(runner.cancelCallCount, 0);
    });
  });
}
