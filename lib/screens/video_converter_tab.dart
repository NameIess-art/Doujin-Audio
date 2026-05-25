import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_audio/statistics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/audio_provider_riverpod.dart';
import '../services/audio_state_services.dart';
import '../services/video_conversion_plan.dart';
import '../services/windows_ffmpeg_service.dart';
import '../widgets/app_feedback.dart';
import '../widgets/top_page_header.dart';

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
  Process? _windowsConversionProcess;

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
    int durationMs = 0;
    if (Platform.isWindows) {
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
          durationMs = parseVideoDurationMs(result.stdout.toString().trim());
        }
      } catch (e) {
        debugPrint('Windows ffprobe error: $e');
      }
    } else {
      final mediaInformation = await FFprobeKit.getMediaInformation(videoPath);
      final information = mediaInformation.getMediaInformation();
      durationMs = parseVideoDurationMs(information?.getDuration());
    }

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

    if (Platform.isWindows) {
      try {
        if (!WindowsFfmpegService.isAvailable) {
          setState(() {
            _isConverting = false;
            _statusMessage = i18n.tr('conversion_failed');
          });
          return;
        }
        _windowsConversionProcess = await Process.start(
          WindowsFfmpegService.ffmpegPath,
          ['-y', ...plan.commandArgs],
        );
        _windowsConversionProcess!.stderr.transform(utf8.decoder).listen((
          data,
        ) {
          if (!mounted || _videoDurationMs <= 0) return;
          final timeInMilliseconds = parseFfmpegProgressTimeMs(data);
          if (timeInMilliseconds <= 0) return;
          setState(() {
            _progress = (timeInMilliseconds / _videoDurationMs).clamp(0.0, 1.0);
            _statusMessage = i18n.tr('converting_percent', {
              'percent': (_progress * 100).toStringAsFixed(1),
            });
          });
        });

        final process = _windowsConversionProcess;
        final returnCode = await process!.exitCode;
        if (!mounted) return;

        final wasCanceled = _windowsConversionProcess == null;
        _windowsConversionProcess = null;
        if (returnCode == 0 && !wasCanceled) {
          _onConversionSuccess(i18n, plan.outputPath);
        } else if (wasCanceled) {
          setState(() {
            _isConverting = false;
            _statusMessage = i18n.tr('conversion_canceled');
          });
        } else {
          setState(() {
            _isConverting = false;
            _statusMessage = i18n.tr('conversion_failed');
          });
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _isConverting = false;
          _statusMessage = i18n.tr('conversion_failed');
        });
        debugPrint('Windows FFMPEG Error: $e');
      }
    } else {
      FFmpegKitConfig.enableStatisticsCallback((Statistics statistics) {
        if (!mounted) return;
        if (_videoDurationMs > 0) {
          final timeInMilliseconds = statistics.getTime();
          setState(() {
            _progress = (timeInMilliseconds / _videoDurationMs).clamp(0.0, 1.0);
            _statusMessage = i18n.tr('converting_percent', {
              'percent': (_progress * 100).toStringAsFixed(1),
            });
          });
        }
      });

      await FFmpegKit.executeAsync(plan.command, (session) async {
        final returnCode = await session.getReturnCode();
        if (!mounted) return;

        if (ReturnCode.isSuccess(returnCode)) {
          _onConversionSuccess(i18n, plan.outputPath);
        } else if (ReturnCode.isCancel(returnCode)) {
          setState(() {
            _isConverting = false;
            _statusMessage = i18n.tr('conversion_canceled');
          });
        } else {
          final logs = await session.getLogsAsString();
          setState(() {
            _isConverting = false;
            _statusMessage = i18n.tr('conversion_failed');
          });
          debugPrint('FFMPEG Error: $logs');
        }
      });
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
    if (Platform.isWindows) {
      _windowsConversionProcess?.kill();
      _windowsConversionProcess = null;
    } else {
      FFmpegKit.cancel();
    }
    setState(() {
      _isConverting = false;
      _statusMessage = i18n.tr('canceling_conversion');
    });
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
              _PathPickerCard(
                icon: Icons.video_library_rounded,
                title: i18n.tr('source_video_file'),
                placeholder: i18n.tr('tap_select_video_file'),
                value: _selectedVideoPath,
                onTap: _isConverting ? null : _pickVideoFile,
              ),
              const SizedBox(height: 12),
              _PathPickerCard(
                icon: Icons.create_new_folder_rounded,
                title: i18n.tr('output_directory'),
                placeholder: i18n.tr('tap_select_output_dir'),
                value: _outputDirectoryPath,
                onTap: _isConverting ? null : _pickOutputDirectory,
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 4, 2, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.tune_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          i18n.tr('transcode_defaults'),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
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
                    const SizedBox(height: 10),
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
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (_statusMessage.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
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
              const SizedBox(height: 16),
              if (_isConverting)
                FilledButton.icon(
                  onPressed: _cancelConversion,
                  icon: const Icon(Icons.cancel_rounded),
                  label: Text(i18n.tr('cancel_conversion')),
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
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
