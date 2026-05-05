import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_audio/statistics.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../widgets/app_feedback.dart';
import '../widgets/top_page_header.dart';

class VideoConverterTab extends StatefulWidget {
  const VideoConverterTab({super.key});

  @override
  State<VideoConverterTab> createState() => _VideoConverterTabState();
}

class _VideoConverterTabState extends State<VideoConverterTab> {
  String? _selectedVideoPath;
  String? _outputDirectoryPath;
  bool _isConverting = false;
  double _progress = 0.0;
  String _statusMessage = '';
  int _videoDurationMs = 0;

  int _parseDurationMs(String? durationStr) {
    if (durationStr == null || durationStr.isEmpty) return 0;
    final seconds = double.tryParse(durationStr);
    if (seconds == null || !seconds.isFinite || seconds <= 0) {
      return 0;
    }
    return (seconds * 1000).round();
  }

  Future<String> _resolveOutputPath(
    String outputDirectoryPath,
    String fileNameNoExt,
    String selectedFormat,
  ) async {
    var suffix = 0;
    while (true) {
      final candidateName = suffix == 0
          ? '$fileNameNoExt.$selectedFormat'
          : '$fileNameNoExt ($suffix).$selectedFormat';
      final candidatePath = path.join(outputDirectoryPath, candidateName);
      if (!await File(candidatePath).exists()) {
        return candidatePath;
      }
      suffix++;
    }
  }

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
    final mediaInformation = await FFprobeKit.getMediaInformation(videoPath);
    final information = mediaInformation.getMediaInformation();
    final durationMs = _parseDurationMs(information?.getDuration());

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
    final fileNameNoExt = path.basenameWithoutExtension(_selectedVideoPath!);
    final outputPath = await _resolveOutputPath(
      _outputDirectoryPath!,
      fileNameNoExt,
      selectedFormat,
    );

    var command = '-i "$_selectedVideoPath" ';

    if (selectedFormat == 'mp3') {
      command += '-vn -ar 44100 -ac 2 -b:a $selectedBitrate ';
    } else if (selectedFormat == 'flac') {
      command += '-vn -c:a flac ';
    } else if (selectedFormat == 'wav') {
      command += '-vn -c:a pcm_s16le -ar 44100 -ac 2 ';
    } else if (selectedFormat == 'aac') {
      command += '-vn -c:a aac -b:a $selectedBitrate ';
    } else if (selectedFormat == 'ogg') {
      command += '-vn -c:a libvorbis -b:a $selectedBitrate ';
    }

    command += '"$outputPath"';

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

    await FFmpegKit.executeAsync(command, (session) async {
      final returnCode = await session.getReturnCode();
      if (!mounted) return;

      if (ReturnCode.isSuccess(returnCode)) {
        setState(() {
          _isConverting = false;
          _progress = 1.0;
          _statusMessage = i18n.tr('conversion_done_saved', {
            'path': outputPath,
          });
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

  void _cancelConversion() {
    final i18n = context.read<AppLanguageProvider>();
    FFmpegKit.cancel();
    setState(() {
      _isConverting = false;
      _statusMessage = i18n.tr('canceling_conversion');
    });
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    final selectedFormat = context.select<AudioProvider, String>(
      (p) => p.converterFormat,
    );
    final selectedBitrate = context.select<AudioProvider, String>(
      (p) => p.converterBitrate,
    );
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
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
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
              ),
              const SizedBox(height: 12),
              Card(
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

class _PathPickerCard extends StatelessWidget {
  const _PathPickerCard({
    required this.icon,
    required this.title,
    required this.placeholder,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String placeholder;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final selected = value != null && value!.isNotEmpty;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: cs.primary),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selected
                        ? cs.primary.withValues(alpha: 0.4)
                        : cs.outlineVariant,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        value ?? placeholder,
                        style: TextStyle(
                          color: selected ? cs.onSurface : cs.onSurfaceVariant,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.folder_open_rounded, color: cs.primary),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectField extends StatelessWidget {
  const _SelectField({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    required this.displayBuilder,
    this.enabled = true,
  });

  final String label;
  final String value;
  final List<String> items;
  final ValueChanged<String?> onChanged;
  final String Function(String) displayBuilder;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        enabled: enabled,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: value,
          borderRadius: BorderRadius.circular(14),
          menuMaxHeight: 320,
          onChanged: enabled ? onChanged : null,
          items: items
              .map(
                (item) => DropdownMenuItem<String>(
                  value: item,
                  child: Text(
                    displayBuilder(item),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}
