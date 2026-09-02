import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../../app/localization/app_language_provider.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/platform/power_platform_service.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../settings/application/settings_repository.dart';
import 'video_conversion_input_service.dart';
import 'video_conversion_plan.dart';
import 'video_conversion_runner.dart';

class VideoConversionCoordinator extends ChangeNotifier {
  VideoConversionCoordinator({
    VideoConversionRunner? runner,
    VideoConversionInputService? inputService,
    PowerPlatformService? powerPlatformService,
    UiOperationService? uiOperationService,
  }) : _runner = runner ?? VideoConversionRunner(),
       _inputService = inputService ?? VideoConversionInputService(),
       _power = powerPlatformService ?? PowerPlatformService(),
       _uiOps = uiOperationService;

  final VideoConversionRunner _runner;
  final VideoConversionInputService _inputService;
  final PowerPlatformService _power;
  final UiOperationService? _uiOps;

  final StreamController<VideoConversionResult> _completionController =
      StreamController<VideoConversionResult>.broadcast();
  Stream<VideoConversionResult> get completionStream =>
      _completionController.stream;

  String? _selectedVideoPath;
  int _videoDurationMs = 0;
  bool _isConverting = false;
  bool _isCanceling = false;
  double _progress = 0.0;
  String _statusMessage = '';
  VideoConversionResult? _lastResult;
  int _conversionGeneration = 0;

  String? get selectedVideoPath => _selectedVideoPath;
  int get videoDurationMs => _videoDurationMs;
  bool get isConverting => _isConverting;
  bool get isCanceling => _isCanceling;
  double get progress => _progress;
  String get statusMessage => _statusMessage;
  VideoConversionResult? get lastResult => _lastResult;

  void selectVideo(String videoPath, int durationMs, {String? statusMessage}) {
    _selectedVideoPath = videoPath;
    _videoDurationMs = durationMs;
    _progress = 0.0;
    _lastResult = null;
    _statusMessage = statusMessage ?? '';
    notifyListeners();
  }

  void clearSelectedVideo() {
    if (_isConverting) return;
    _selectedVideoPath = null;
    _videoDurationMs = 0;
    _progress = 0.0;
    _statusMessage = '';
    _lastResult = null;
    notifyListeners();
  }

  void updateStatusMessage(String message) {
    _statusMessage = message;
    notifyListeners();
  }

  Future<void> pickVideo(AppLanguageProvider i18n) async {
    if (_isConverting) return;
    final uiOps = _uiOps;
    final selectedPath = uiOps != null
        ? await uiOps.run<String?>(
            scope: UiOperationScope.videoConverterPick,
            labelKey: 'source_video_file',
            task: (_) => _inputService.pickVideoPath(),
          )
        : await _inputService.pickVideoPath();

    if (selectedPath != null && selectedPath.isNotEmpty) {
      final durationMs = uiOps != null
          ? await uiOps.run<int>(
              scope: UiOperationScope.videoConverterPick,
              labelKey: 'source_video_file',
              task: (_) => _runner.readDurationMs(selectedPath),
            )
          : await _runner.readDurationMs(selectedPath);

      selectVideo(
        selectedPath,
        durationMs,
        statusMessage: i18n.tr('selected_file', {
          'name': path.basename(selectedPath),
        }),
      );
    }
  }

  Future<void> pickOutputDirectory(SettingsRepository settings) async {
    if (_isConverting) return;
    final uiOps = _uiOps;
    final result = uiOps != null
        ? await uiOps.run<String?>(
            scope: UiOperationScope.videoConverterPick,
            labelKey: 'output_directory',
            task: (_) => _inputService.pickOutputDirectory(),
          )
        : await _inputService.pickOutputDirectory();

    if (result != null && result.isNotEmpty) {
      await settings.setConverterOutputDirectoryPath(result);
      notifyListeners();
    }
  }

  Future<VideoConversionResult?> startConversion({
    required SettingsRepository settings,
    required AppLanguageProvider i18n,
  }) async {
    if (_isConverting) return null;
    final inputPath = _selectedVideoPath;
    final outputDirectoryPath = settings.converterOutputDirectoryPath;
    if (inputPath == null || outputDirectoryPath == null) {
      return null;
    }

    final generation = ++_conversionGeneration;
    final durationMs = _videoDurationMs;
    _isConverting = true;
    _isCanceling = false;
    _progress = 0.0;
    _statusMessage = i18n.tr('conversion_starting');
    _lastResult = null;
    notifyListeners();

    // Acquire partial wake lock to keep CPU running during conversion even if screen is turned off.
    await _power.acquireWakeLock(tag: 'video_conversion');

    VideoConversionResult result;
    try {
      final uiOps = _uiOps;
      Future<VideoConversionResult> executeTask(dynamic progressReporter) async {
        final plan = await createVideoConversionPlan(
          inputPath: inputPath,
          outputDirectoryPath: outputDirectoryPath,
          format: settings.converterFormat,
          bitrate: settings.converterBitrate,
        );
        return await _runner.convert(
          plan: plan,
          durationMs: durationMs,
          onProgress: (p) {
            try {
              progressReporter?.report(p);
            } catch (_) {}
            if (generation != _conversionGeneration) return;
            _progress = p;
            _statusMessage = i18n.tr('converting_percent', {
              'percent': (_progress * 100).toStringAsFixed(1),
            });
            notifyListeners();
          },
        );
      }

      if (uiOps != null) {
        result = await uiOps.run<VideoConversionResult>(
          scope: UiOperationScope.videoConverterConvert,
          labelKey: 'conversion_starting',
          cancelPrevious: false,
          task: (opProgress) => executeTask(opProgress),
        );
      } else {
        result = await executeTask(null);
      }
    } catch (error, stackTrace) {
      AppLogService.error(
        'video_conversion_failed',
        error: error,
        stackTrace: stackTrace,
      );
      result = VideoConversionResult.failed(error.toString());
    } finally {
      await _power.releaseWakeLock(tag: 'video_conversion');
    }

    if (generation == _conversionGeneration) {
      _isConverting = false;
      _isCanceling = false;
      _lastResult = result;

      switch (result.status) {
        case VideoConversionStatus.success:
          _progress = 1.0;
          _statusMessage = i18n.tr('conversion_done_saved', {
            'path': result.outputPath ?? '',
          });
          _completionController.add(result);
          break;
        case VideoConversionStatus.canceled:
          _statusMessage = i18n.tr('conversion_canceled');
          break;
        case VideoConversionStatus.failed:
          _statusMessage = i18n.tr('conversion_failed');
          final errorMessage = result.errorMessage;
          if (errorMessage != null && errorMessage.isNotEmpty) {
            AppLogService.error(
              'video_conversion_ffmpeg_failed',
              error: errorMessage,
            );
          }
          _completionController.add(result);
          break;
      }
      notifyListeners();
    }
    return result;
  }

  Future<void> cancelConversion({required AppLanguageProvider i18n}) async {
    if (!_isConverting || _isCanceling) return;
    _isCanceling = true;
    _statusMessage = i18n.tr('canceling_conversion');
    notifyListeners();
    try {
      await _runner.cancel();
    } catch (error, stackTrace) {
      AppLogService.error(
        'video_conversion_cancel_failed',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      await _power.releaseWakeLock(tag: 'video_conversion');
    }
  }

  @override
  void dispose() {
    _completionController.close();
    super.dispose();
  }
}
