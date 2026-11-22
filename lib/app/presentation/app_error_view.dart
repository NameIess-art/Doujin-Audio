import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/logging/app_log_service.dart';
import '../../core/widgets/app_buttons.dart';
import '../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../features/data_support/application/diagnostic_report_exporter.dart';
import '../localization/app_language_en.dart';
import '../localization/app_language_ja.dart';
import '../localization/app_language_zh.dart';
import '../theme/app_styles.dart';

class AppErrorView extends StatefulWidget {
  const AppErrorView({
    required this.error,
    this.stackTrace,
    this.onRetry,
    this.exportDiagnostics,
    super.key,
  });

  factory AppErrorView.fromFlutterError(FlutterErrorDetails details) {
    return AppErrorView(error: details.exception, stackTrace: details.stack);
  }

  final Object error;
  final StackTrace? stackTrace;
  final VoidCallback? onRetry;
  final Future<void> Function()? exportDiagnostics;

  @override
  State<AppErrorView> createState() => _AppErrorViewState();
}

class _AppErrorViewState extends State<AppErrorView> {
  bool _exporting = false;
  String? _exportStatusMessage;
  bool _exportStatusFailed = false;

  Future<void> _exportDiagnostics() async {
    if (_exporting) return;
    final strings = _localizedStrings();
    String tr(String key) => strings[key] ?? appLanguageEn[key] ?? key;
    setState(() {
      _exporting = true;
      _exportStatusMessage = null;
      _exportStatusFailed = false;
    });
    try {
      final export = widget.exportDiagnostics;
      String? exportedPath;
      if (export != null) {
        await export();
      } else {
        exportedPath = await DiagnosticReportExporter().export(
          dialogTitle: tr('export_diagnostics'),
        );
      }
      if (!mounted) return;
      if (export == null && exportedPath == null) {
        return;
      }
      final message = exportedPath != null && exportedPath.isNotEmpty
          ? tr('diagnostics_exported').replaceAll('{path}', exportedPath)
          : tr('diagnostics_exported_done');
      setState(() {
        _exportStatusMessage = message;
        _exportStatusFailed = false;
      });
    } catch (error, stackTrace) {
      AppLogService.error(
        'global_error_diagnostic_export_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _exportStatusMessage = tr('diagnostics_export_failed');
          _exportStatusFailed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final strings = _localizedStrings();
    String tr(String key) => strings[key] ?? appLanguageEn[key] ?? key;
    final canRetry = widget.onRetry != null;
    return Material(
      key: const ValueKey<String>('app_error_view'),
      color: cs.surface,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              padding: AppSpacing.edgeInsetsAllMd,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline_rounded, size: 56, color: cs.error),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    tr(
                      canRetry
                          ? 'startup_error_title'
                          : 'unexpected_error_title',
                    ),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    tr(
                      canRetry
                          ? 'startup_error_message'
                          : 'unexpected_error_message',
                    ),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  if (canRetry) ...[
                    AppPrimaryButton(
                      key: const ValueKey<String>('startup_retry_button'),
                      onPressed: widget.onRetry,
                      icon: Icons.refresh_rounded,
                      label: tr('retry'),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  canRetry
                      ? AppSecondaryButton(
                          key: const ValueKey<String>(
                            'error_export_diagnostics_button',
                          ),
                          onPressed: _exporting ? null : _exportDiagnostics,
                          isLoading: _exporting,
                          icon: Icons.bug_report_outlined,
                          label: tr('export_diagnostics'),
                        )
                      : AppPrimaryButton(
                          key: const ValueKey<String>(
                            'error_export_diagnostics_button',
                          ),
                          onPressed: _exporting ? null : _exportDiagnostics,
                          isLoading: _exporting,
                          icon: Icons.bug_report_outlined,
                          label: tr('export_diagnostics'),
                        ),
                  if (_exportStatusMessage != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Semantics(
                      liveRegion: true,
                      child: Row(
                        key: const ValueKey<String>(
                          'error_export_diagnostics_status',
                        ),
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _exportStatusFailed
                                ? Icons.error_outline_rounded
                                : Icons.check_circle_outline_rounded,
                            size: 16,
                            color: _exportStatusFailed
                                ? cs.error
                                : cs.primary,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              _exportStatusMessage!,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: _exportStatusFailed
                                    ? cs.error
                                    : cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (!canRetry &&
                      defaultTargetPlatform != TargetPlatform.windows) ...[
                    const SizedBox(height: AppSpacing.sm),
                    AppSecondaryButton(
                      onPressed: SystemNavigator.pop,
                      icon: Icons.close_rounded,
                      label: tr('close_app'),
                    ),
                  ],
                ],
              ),
            ).withWindowsSmoothScroll(),
          ),
        ),
      ),
    );
  }

  Map<String, String> _localizedStrings() {
    final languageCode = Localizations.maybeLocaleOf(context)?.languageCode;
    return switch (languageCode) {
      'zh' => appLanguageZh,
      'ja' => appLanguageJa,
      _ => appLanguageEn,
    };
  }
}
