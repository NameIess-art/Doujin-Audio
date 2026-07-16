import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../core/logging/app_log_service.dart';
import '../../settings/application/settings_repository.dart';
import '../../settings/application/settings_state.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../application/video_conversion_plan.dart';
import '../application/video_conversion_input_service.dart';
import '../application/video_conversion_runner.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/top_page_header.dart';
import '../../../core/widgets/unified_dropdown.dart';

part 'video_converter_tab_widgets.dart';

class VideoConverterTab extends ConsumerStatefulWidget {
  const VideoConverterTab({super.key});

  @override
  ConsumerState<VideoConverterTab> createState() => _VideoConverterTabState();
}

class _VideoConverterTabState extends ConsumerState<VideoConverterTab> {
  String? _selectedVideoPath;
  String? _outputDirectoryPath;
  bool _isConverting = false;
  bool _isCanceling = false;
  double _progress = 0.0;
  String _statusMessage = '';
  int _videoDurationMs = 0;
  int _conversionGeneration = 0;
  Timer? _successResetTimer;
  final VideoConversionRunner _conversionRunner = VideoConversionRunner();
  final VideoConversionInputService _inputService =
      VideoConversionInputService();

  Future<void> _pickVideoFile() async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final selectedPath = await UiOperationService.instance.run<String?>(
      scope: UiOperationScope.videoConverterPick,
      labelKey: 'source_video_file',
      task: (_) => _inputService.pickVideoPath(),
    );
    if (!mounted) return;
    if (selectedPath != null && selectedPath.isNotEmpty) {
      final videoPath = selectedPath;
      _successResetTimer?.cancel();
      _successResetTimer = null;
      _conversionGeneration++;
      setState(() {
        _selectedVideoPath = videoPath;
        _statusMessage = i18n.tr('selected_file', {
          'name': path.basename(videoPath),
        });
      });
      await _getVideoDuration(videoPath);
    }
  }

  Future<void> _pickOutputDirectory() async {
    final result = await UiOperationService.instance.run<String?>(
      scope: UiOperationScope.videoConverterPick,
      labelKey: 'output_directory',
      task: (_) => _inputService.pickOutputDirectory(),
    );
    if (!mounted) return;
    if (result != null && result.isNotEmpty) {
      _successResetTimer?.cancel();
      _successResetTimer = null;
      _conversionGeneration++;
      setState(() {
        _outputDirectoryPath = result;
      });
    }
  }

  Future<void> _getVideoDuration(String videoPath) async {
    final durationMs = await UiOperationService.instance.run<int>(
      scope: UiOperationScope.videoConverterPick,
      labelKey: 'source_video_file',
      task: (_) => _conversionRunner.readDurationMs(videoPath),
    );

    if (!mounted) return;
    if (_selectedVideoPath != videoPath) return;
    setState(() {
      _videoDurationMs = durationMs;
    });
  }

  Future<void> _startConversion(SettingsRepository settings) async {
    if (_isConverting) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    if (_selectedVideoPath == null || _outputDirectoryPath == null) {
      showAppSnackBar(
        context,
        i18n.tr('select_video_and_output'),
        tone: AppFeedbackTone.warning,
        icon: Icons.video_library_rounded,
      );
      return;
    }

    _successResetTimer?.cancel();
    _successResetTimer = null;
    final generation = ++_conversionGeneration;
    final inputPath = _selectedVideoPath!;
    final outputDirectoryPath = _outputDirectoryPath!;
    final durationMs = _videoDurationMs;
    setState(() {
      _isConverting = true;
      _isCanceling = false;
      _progress = 0.0;
      _statusMessage = i18n.tr('conversion_starting');
    });

    try {
      final conversion = await UiOperationService.instance
          .run<({VideoConversionResult result, String outputPath})>(
            scope: UiOperationScope.videoConverterConvert,
            labelKey: 'conversion_starting',
            cancelPrevious: false,
            task: (operationProgress) async {
              final selectedFormat = settings.converterFormat;
              final selectedBitrate = settings.converterBitrate;
              final plan = await createVideoConversionPlan(
                inputPath: inputPath,
                outputDirectoryPath: outputDirectoryPath,
                format: selectedFormat,
                bitrate: selectedBitrate,
              );
              final result = await _conversionRunner.convert(
                plan: plan,
                durationMs: durationMs,
                onProgress: (progress) {
                  operationProgress.report(progress);
                  if (!mounted || generation != _conversionGeneration) return;
                  setState(() {
                    _progress = progress;
                    _statusMessage = i18n.tr('converting_percent', {
                      'percent': (_progress * 100).toStringAsFixed(1),
                    });
                  });
                },
              );
              return (result: result, outputPath: plan.outputPath);
            },
          );
      if (!mounted || generation != _conversionGeneration) return;
      final result = conversion.result;
      final outputPath = conversion.outputPath;
      switch (result.status) {
        case VideoConversionStatus.success:
          _onConversionSuccess(i18n, outputPath, generation);
          break;
        case VideoConversionStatus.canceled:
          setState(() {
            _statusMessage = i18n.tr('conversion_canceled');
          });
          break;
        case VideoConversionStatus.failed:
          setState(() {
            _statusMessage = i18n.tr('conversion_failed');
          });
          final errorMessage = result.errorMessage;
          if (errorMessage != null && errorMessage.isNotEmpty) {
            AppLogService.error(
              'video_conversion_ffmpeg_failed',
              error: errorMessage,
            );
          }
          break;
      }
    } catch (error, stackTrace) {
      if (!mounted || generation != _conversionGeneration) return;
      AppLogService.error(
        'video_conversion_failed',
        error: error,
        stackTrace: stackTrace,
      );
      setState(() {
        _statusMessage = i18n.tr('conversion_failed');
      });
    } finally {
      if (mounted && generation == _conversionGeneration) {
        setState(() {
          _isConverting = false;
          _isCanceling = false;
        });
      }
    }
  }

  void _onConversionSuccess(
    AppLanguageProvider i18n,
    String outputPath,
    int generation,
  ) {
    setState(() {
      _progress = 1.0;
      _statusMessage = i18n.tr('conversion_done_saved', {'path': outputPath});
    });
    _successResetTimer?.cancel();
    _successResetTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || generation != _conversionGeneration) return;
      _successResetTimer = null;
      setState(() {
        _selectedVideoPath = null;
        _progress = 0.0;
        _videoDurationMs = 0;
        _statusMessage = '';
      });
    });
  }

  Future<void> _cancelConversion() async {
    if (!_isConverting || _isCanceling) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final generation = _conversionGeneration;
    setState(() {
      _isCanceling = true;
      _statusMessage = i18n.tr('canceling_conversion');
    });
    try {
      await _conversionRunner.cancel();
    } catch (error, stackTrace) {
      AppLogService.error(
        'video_conversion_cancel_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted && generation == _conversionGeneration && _isConverting) {
        setState(() {
          _statusMessage = i18n.tr('conversion_failed');
        });
      }
    }
  }

  @override
  void dispose() {
    _conversionGeneration++;
    _successResetTimer?.cancel();
    _successResetTimer = null;
    unawaited(_conversionRunner.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final settings = ref.read(settingsRepositoryProvider);
    final settingsState =
        ref.watch(settingsStateProvider).valueOrNull ?? const SettingsState();
    final pickOperation = ref.watch(
      uiOperationForScopeProvider(UiOperationScope.videoConverterPick),
    );
    final selectedFormat = settingsState.converterFormat;
    final selectedBitrate = settingsState.converterBitrate;
    final bitrateEnabled = selectedFormat != 'wav' && selectedFormat != 'flac';
    final descStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontSize: 11,
      height: 1.25,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );

    final topPadding = MediaQuery.paddingOf(context).top;
    final topTotalHeight = 82 + topPadding; // 82 is roughly the header height

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(16, topTotalHeight + 4, 16, 24),
            children: [
              Card(
                margin: EdgeInsets.zero,
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    _PathPickerCard(
                      icon: Icons.video_library_rounded,
                      title: i18n.tr('source_video_file'),
                      placeholder: i18n.tr('tap_select_video_file'),
                      value: _selectedVideoPath,
                      onTap: _isConverting || pickOperation.isBusy
                          ? null
                          : _pickVideoFile,
                    ),
                    Divider(
                      height: 1,
                      color: Theme.of(
                        context,
                      ).colorScheme.outlineVariant.withValues(alpha: 0.4),
                    ),
                    _PathPickerCard(
                      icon: Icons.create_new_folder_rounded,
                      title: i18n.tr('output_directory'),
                      placeholder: i18n.tr('tap_select_output_dir'),
                      value: _outputDirectoryPath,
                      onTap: _isConverting || pickOperation.isBusy
                          ? null
                          : _pickOutputDirectory,
                    ),
                  ],
                ),
              ),
              if (pickOperation.isBusy) ...[
                const SizedBox(height: 12),
                OperationStatusBanner(
                  label: _statusMessage.isNotEmpty
                      ? _statusMessage
                      : i18n.tr(pickOperation.labelKey),
                  progress: pickOperation.progress,
                  icon: Icons.folder_open_rounded,
                ),
              ],
              const SizedBox(height: 16),
              Card(
                margin: EdgeInsets.zero,
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.tune_rounded,
                            color: Theme.of(context).colorScheme.primary,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            i18n.tr('transcode_defaults'),
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: _SelectField(
                              label: i18n.tr('format'),
                              value: selectedFormat,
                              items: SettingsRepository.converterFormats,
                              displayBuilder: (item) => item.toUpperCase(),
                              onChanged: (value) {
                                if (value != null) {
                                  settings.setConverterSettings(format: value);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _SelectField(
                              label: i18n.tr('bitrate'),
                              value: selectedBitrate,
                              items: SettingsRepository.converterBitrates,
                              displayBuilder: (item) => item,
                              enabled: bitrateEnabled,
                              onChanged: (value) {
                                if (value != null) {
                                  settings.setConverterSettings(bitrate: value);
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        bitrateEnabled
                            ? i18n.tr('bitrate_used')
                            : i18n.tr('bitrate_not_used', {
                                'format': selectedFormat.toUpperCase(),
                              }),
                        style: descStyle,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox.shrink(),
              Visibility(
                visible: false,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Icon(
                          Icons.tune_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            i18n.tr('current_params', {
                              'value':
                                  '${selectedFormat.toUpperCase()} · ${selectedFormat == 'wav' || selectedFormat == 'flac' ? i18n.tr('format_auto_encode') : selectedBitrate}',
                            }),
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (_isConverting || _progress > 0) ...[
                const SizedBox(height: 16),
                TweenAnimationBuilder<double>(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  tween: Tween<double>(
                    begin: 0,
                    end: _isConverting && _videoDurationMs == 0 ? 0 : _progress,
                  ),
                  builder: (context, value, _) => LinearProgressIndicator(
                    value: _isConverting && _videoDurationMs == 0
                        ? null
                        : value,
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ],
              if (_statusMessage.isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    _statusMessage,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _isConverting
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              if (_isConverting)
                FilledButton.icon(
                  onPressed: _isCanceling
                      ? null
                      : () => unawaited(_cancelConversion()),
                  icon: Icon(
                    _isCanceling
                        ? Icons.hourglass_top_rounded
                        : Icons.cancel_rounded,
                  ),
                  label: Text(
                    i18n.tr(
                      _isCanceling
                          ? 'canceling_conversion'
                          : 'cancel_conversion',
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    textStyle: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                )
              else
                FilledButton.icon(
                  onPressed:
                      _selectedVideoPath != null && _outputDirectoryPath != null
                      ? () => _startConversion(settings)
                      : null,
                  icon: const Icon(Icons.transform_rounded),
                  label: Text(i18n.tr('start_conversion')),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    textStyle: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopPageHeader(
              icon: Icons.sync_rounded,
              title: i18n.tr('video_to_audio'),
              trailing: Semantics(
                button: true,
                label: i18n.tr('close'),
                child: IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: i18n.tr('close'),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              bottomSpacing: 16,
            ),
          ),
        ],
      ),
    );
  }
}
