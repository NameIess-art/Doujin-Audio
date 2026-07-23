import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/logging/app_log_service.dart';
import '../../core/widgets/app_buttons.dart';
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

  Future<void> _exportDiagnostics() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final export = widget.exportDiagnostics;
      if (export != null) {
        await export();
      } else {
        await DiagnosticReportExporter().export(
          dialogTitle:
              _localizedStrings()['export_diagnostics'] ??
              appLanguageEn['export_diagnostics']!,
        );
      }
    } catch (error, stackTrace) {
      AppLogService.error(
        'global_error_diagnostic_export_failed',
        error: error,
        stackTrace: stackTrace,
      );
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
            child: Padding(
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
                          icon: Icons.archive_outlined,
                          label: tr('export_diagnostics'),
                        )
                      : AppPrimaryButton(
                          key: const ValueKey<String>(
                            'error_export_diagnostics_button',
                          ),
                          onPressed: _exporting ? null : _exportDiagnostics,
                          isLoading: _exporting,
                          icon: Icons.archive_outlined,
                          label: tr('export_diagnostics'),
                        ),
                  if (!canRetry) ...[
                    const SizedBox(height: AppSpacing.sm),
                    AppSecondaryButton(
                      onPressed: SystemNavigator.pop,
                      icon: Icons.restart_alt_rounded,
                      label: tr('close_and_restart'),
                    ),
                  ],
                ],
              ),
            ),
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
