import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/audio_provider_riverpod.dart';
import '../services/audio_state_services.dart';
import '../services/video_conversion_plan.dart';
import '../services/video_conversion_runner.dart';
import '../widgets/app_feedback.dart';
import '../widgets/top_page_header.dart';
import '../widgets/unified_dropdown.dart';

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
  double _progress = 0.0;
  String _statusMessage = '';
  int _videoDurationMs = 0;
  final VideoConversionRunner _conversionRunner = VideoConversionRunner();

  Future<void> _pickVideoFile() async {
    final i18n = context.read<AppLanguageProvider>();
    final result = await FilePicker.platform.pickFiles(type: FileType.video);
    if (result != null && result.files.single.path != null) {
      final videoPath = result.files.single.path!;
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
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      setState(() {
        _outputDirectoryPath = result;
      });
    }
  }

  Future<void> _getVideoDuration(String videoPath) async {
    final durationMs = await _conversionRunner.readDurationMs(videoPath);

    if (!mounted) return;
    setState(() {
      _videoDurationMs = durationMs;
    });
  }

  Future<void> _startConversion(AudioProvider provider) async {
    final i18n = context.read<AppLanguageProvider>();
    if (_selectedVideoPath == null || _outputDirectoryPath == null) {
      showAppSnackBar(
        context,
        i18n.tr('select_video_and_output'),
        tone: AppFeedbackTone.warning,
        icon: Icons.video_library_rounded,
      );
      return;
    }

    setState(() {
      _isConverting = true;
      _progress = 0.0;
      _statusMessage = i18n.tr('conversion_starting');
    });

    final selectedFormat = provider.converterFormat;
    final selectedBitrate = provider.converterBitrate;
    final plan = await createVideoConversionPlan(
      inputPath: _selectedVideoPath!,
      outputDirectoryPath: _outputDirectoryPath!,
      format: selectedFormat,
      bitrate: selectedBitrate,
    );

    final result = await _conversionRunner.convert(
      plan: plan,
      durationMs: _videoDurationMs,
      onProgress: (progress) {
        if (!mounted) return;
        setState(() {
          _progress = progress;
          _statusMessage = i18n.tr('converting_percent', {
            'percent': (_progress * 100).toStringAsFixed(1),
          });
        });
      },
    );
    if (!mounted) return;

    switch (result.status) {
      case VideoConversionStatus.success:
        _onConversionSuccess(i18n, plan.outputPath);
        break;
      case VideoConversionStatus.canceled:
        setState(() {
          _isConverting = false;
          _statusMessage = i18n.tr('conversion_canceled');
        });
        break;
      case VideoConversionStatus.failed:
        setState(() {
          _isConverting = false;
          _statusMessage = i18n.tr('conversion_failed');
        });
        final errorMessage = result.errorMessage;
        if (errorMessage != null && errorMessage.isNotEmpty) {
          debugPrint('FFMPEG Error: $errorMessage');
        }
        break;
    }
  }

  void _onConversionSuccess(AppLanguageProvider i18n, String outputPath) {
    setState(() {
      _isConverting = false;
      _progress = 1.0;
      _statusMessage = i18n.tr('conversion_done_saved', {'path': outputPath});
    });
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() {
        _selectedVideoPath = null;
        _progress = 0.0;
        _videoDurationMs = 0;
        _statusMessage = '';
      });
    });
  }

  void _cancelConversion() {
    final i18n = context.read<AppLanguageProvider>();
    _conversionRunner.cancel();
    setState(() {
      _isConverting = false;
      _statusMessage = i18n.tr('canceling_conversion');
    });
  }

  @override
  void dispose() {
    if (_isConverting) {
      _conversionRunner.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final provider = ref.read(audioProviderFacadeProvider);
    final settingsState =
        ref.watch(settingsStateProvider).valueOrNull ?? const SettingsState();
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
                      onTap: _isConverting ? null : _pickVideoFile,
                    ),
                    Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.4)),
                    _PathPickerCard(
                      icon: Icons.create_new_folder_rounded,
                      title: i18n.tr('output_directory'),
                      placeholder: i18n.tr('tap_select_output_dir'),
                      value: _outputDirectoryPath,
                      onTap: _isConverting ? null : _pickOutputDirectory,
                    ),
                  ],
                ),
              ),
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
                                ?.copyWith(fontWeight: FontWeight.w700, fontSize: 15),
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
                              items: AudioProvider.converterFormats,
                              displayBuilder: (item) => item.toUpperCase(),
                              onChanged: (value) {
                                if (value != null) {
                                  provider.setConverterSettings(format: value);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _SelectField(
                              label: i18n.tr('bitrate'),
                              value: selectedBitrate,
                              items: AudioProvider.converterBitrates,
                              displayBuilder: (item) => item,
                              enabled: bitrateEnabled,
                              onChanged: (value) {
                                if (value != null) {
                                  provider.setConverterSettings(bitrate: value);
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
                    color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
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
                  onPressed: _cancelConversion,
                  icon: const Icon(Icons.cancel_rounded),
                  label: Text(i18n.tr('cancel_conversion')),
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
                      ? () => _startConversion(provider)
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
