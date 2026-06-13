import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../services/app_log_service.dart';
import '../services/diagnostic_report_service.dart';

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
      final directory = await getTemporaryDirectory();
      final report = await DiagnosticReportService().exportReport(
        path.join(directory.path, 'NamelessAudio-diagnostic.zip'),
      );
      await FilePicker.platform.saveFile(
        dialogTitle: 'Export diagnostics',
        fileName: path.basename(report.path),
        type: FileType.custom,
        allowedExtensions: const <String>['zip'],
        bytes: await report.readAsBytes(),
        lockParentWindow: true,
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
    return Material(
      color: const Color(0xFF111114),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    size: 56,
                    color: Color(0xFFF08599),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Nameless Audio encountered an unexpected error.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontFamily: 'Outfit',
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Your data remains local. Export diagnostics for support, '
                    'then close and restart the app.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFB8B3BC),
                      fontFamily: 'Raleway',
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _exporting ? null : _exportDiagnostics,
                    icon: _exporting
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.archive_outlined),
                    label: const Text('Export diagnostics'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: SystemNavigator.pop,
                    icon: const Icon(Icons.restart_alt_rounded),
                    label: const Text('Close and restart'),
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
