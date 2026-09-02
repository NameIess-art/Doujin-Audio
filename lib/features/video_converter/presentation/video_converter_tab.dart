import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_styles.dart';
import '../../settings/application/settings_repository.dart';
import '../../settings/application/settings_state.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/top_page_header.dart';
import '../../../core/widgets/unified_dropdown.dart';

part 'video_converter_tab_widgets.dart';

String formatVideoConverterOutputDirectoryPath(String directoryPath) {
  const primaryStoragePrefix = '/storage/emulated/0/';
  final normalizedPath = directoryPath.replaceAll('\\', '/');
  return normalizedPath.startsWith(primaryStoragePrefix)
      ? normalizedPath.substring(primaryStoragePrefix.length)
      : directoryPath;
}

double _videoConverterHeaderContentTopInset(BuildContext context) {
  return MediaQuery.paddingOf(context).top +
      AppPageHeaderMetrics.padding.vertical +
      AppPageHeaderMetrics.contentHeight +
      AppPageHeaderMetrics.bottomSpacing +
      AppPageHeaderMetrics.firstContentSpacing;
}

class VideoConverterTab extends ConsumerStatefulWidget {
  const VideoConverterTab({super.key});

  @override
  ConsumerState<VideoConverterTab> createState() => _VideoConverterTabState();
}

class _VideoConverterTabState extends ConsumerState<VideoConverterTab> {
  Future<void> _pickVideoFile() async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    await ref.read(videoConversionCoordinatorProvider).pickVideo(i18n);
  }

  Future<void> _pickOutputDirectory() async {
    final settings = ref.read(settingsRepositoryProvider);
    await ref
        .read(videoConversionCoordinatorProvider)
        .pickOutputDirectory(settings);
  }

  Future<void> _startConversion(SettingsRepository settings) async {
    final coordinator = ref.read(videoConversionCoordinatorProvider);
    if (coordinator.isConverting) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final outputDirectoryPath = settings.converterOutputDirectoryPath;
    if (coordinator.selectedVideoPath == null || outputDirectoryPath == null) {
      showAppSnackBar(
        context,
        i18n.tr('select_video_and_output'),
        tone: AppFeedbackTone.warning,
        icon: Icons.video_library_rounded,
      );
      return;
    }
    await coordinator.startConversion(settings: settings, i18n: i18n);
  }

  Future<void> _cancelConversion() async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    await ref
        .read(videoConversionCoordinatorProvider)
        .cancelConversion(i18n: i18n);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final settings = ref.read(settingsRepositoryProvider);
    final settingsState =
        ref.watch(settingsStateProvider).value ?? SettingsState();
    final pickOperation = ref.watch(
      uiOperationForScopeProvider(UiOperationScope.videoConverterPick),
    );
    final coordinator = ref.watch(videoConversionCoordinatorProvider);
    final selectedVideoPath = coordinator.selectedVideoPath;
    final isConverting = coordinator.isConverting;
    final isCanceling = coordinator.isCanceling;
    final progress = coordinator.progress;
    final statusMessage = coordinator.statusMessage;
    final videoDurationMs = coordinator.videoDurationMs;
    final selectedFormat = settingsState.converterFormat;
    final selectedBitrate = settingsState.converterBitrate;
    final outputDirectoryPath = settingsState.converterOutputDirectoryPath;
    final bitrateEnabled = selectedFormat != 'wav' && selectedFormat != 'flac';
    final descStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontSize: 11,
      height: 1.25,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final bottomActionInset = 88.0 + MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              _videoConverterHeaderContentTopInset(context),
              16,
              bottomActionInset,
            ),
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
                      icon: Icons.video_file_rounded,
                      title: i18n.tr('source_video_file'),
                      placeholder: i18n.tr('tap_select_video_file'),
                      value: selectedVideoPath,
                      onTap: isConverting || pickOperation.isBusy
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
                      value: outputDirectoryPath == null
                          ? null
                          : formatVideoConverterOutputDirectoryPath(
                              outputDirectoryPath,
                            ),
                      onTap: isConverting || pickOperation.isBusy
                          ? null
                          : _pickOutputDirectory,
                    ),
                  ],
                ),
              ),
              if (pickOperation.isBusy) ...[
                const SizedBox(height: 12),
                OperationStatusBanner(
                  label: statusMessage.isNotEmpty
                      ? statusMessage
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
              if (isConverting || progress > 0) ...[
                const SizedBox(height: 16),
                TweenAnimationBuilder<double>(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  tween: Tween<double>(
                    begin: 0,
                    end: isConverting && videoDurationMs == 0 ? 0 : progress,
                  ),
                  builder: (context, value, _) => LinearProgressIndicator(
                    value: isConverting && videoDurationMs == 0
                        ? null
                        : value,
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ],
              if (statusMessage.isNotEmpty) ...[
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
                    statusMessage,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: isConverting
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ],
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16 + MediaQuery.paddingOf(context).bottom,
            child: isConverting
                ? FilledButton.icon(
                    onPressed: isCanceling
                        ? null
                        : () => unawaited(_cancelConversion()),
                    icon: Icon(
                      isCanceling
                          ? Icons.hourglass_top_rounded
                          : Icons.cancel_rounded,
                    ),
                    label: Text(
                      i18n.tr(
                        isCanceling
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
                : FilledButton.icon(
                    onPressed:
                        selectedVideoPath != null && outputDirectoryPath != null
                        ? () => _startConversion(settings)
                        : null,
                    icon: const Icon(Icons.transform_rounded),
                    label: Text(i18n.tr('start_conversion')),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      textStyle: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopPageHeader(
              icon: Icons.video_library_rounded,
              title: i18n.tr('video_to_audio'),
              leading: HeaderFloatingButton(
                child: IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: i18n.tr('close'),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
