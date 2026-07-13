import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../logging/app_log_service.dart';
import '../../features/data_support/application/diagnostic_report_exporter.dart';
import '../../app/localization/app_language_en.dart';
import '../../app/localization/app_language_ja.dart';
import '../../app/localization/app_language_zh.dart';
import '../../app/theme/app_styles.dart';
import 'app_buttons.dart';

class AppErrorView extends StatefulWidget {
  const AppErrorView({required this.details, super.key});

  final FlutterErrorDetails details;

  @override
  State<AppErrorView> createState() => _AppErrorViewState();
}

class _AppErrorViewState extends State<AppErrorView> {
  bool _exporting = false;

  Future<void> _exportDiagnostics() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      await DiagnosticReportExporter().export(
        dialogTitle: 'Export diagnostics',
      );
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
    final languageCode = Localizations.maybeLocaleOf(context)?.languageCode;
    final strings = switch (languageCode) {
      'zh' => appLanguageZh,
      'ja' => appLanguageJa,
      _ => appLanguageEn,
    };
    String tr(String key) => strings[key] ?? appLanguageEn[key] ?? key;
    return Material(
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
                    tr('unexpected_error_title'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    tr('unexpected_error_message'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  AppPrimaryButton(
                    onPressed: _exporting ? null : _exportDiagnostics,
                    isLoading: _exporting,
                    icon: Icons.archive_outlined,
                    label: tr('export_diagnostics'),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppSecondaryButton(
                    onPressed: SystemNavigator.pop,
                    icon: Icons.restart_alt_rounded,
                    label: tr('close_and_restart'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
