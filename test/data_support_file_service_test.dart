import 'dart:io';

import 'package:file_picker/file_picker.dart';
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:nameless_audio/features/data_support/application/data_support_file_service.dart';
import 'package:nameless_audio/features/data_support/application/diagnostic_report_exporter.dart';
import 'package:nameless_audio/features/data_support/application/diagnostic_report_service.dart';
import 'package:path/path.dart' as path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const fileCacheChannel = MethodChannel('test/data_support_file_service');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final defaultFilePicker = FilePickerPlatform.instance;
  late Directory temporaryDirectory;
  late _TestFilePicker filePicker;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'data_support_file_service_test_',
    );
    filePicker = _TestFilePicker();
    FilePickerPlatform.instance = filePicker;
    messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
      return call.method == 'getTemporaryDirectory'
          ? temporaryDirectory.path
          : null;
    });
  });

  tearDown(() async {
    FilePickerPlatform.instance = defaultFilePicker;
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    messenger.setMockMethodCallHandler(fileCacheChannel, null);
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'Android diagnostics export uses the native gateway before cleanup',
    () async {
      MethodCall? exportedCall;
      List<int>? exportedBytes;
      messenger.setMockMethodCallHandler(fileCacheChannel, (call) async {
        exportedCall = call;
        final arguments = Map<String, Object?>.from(call.arguments as Map);
        exportedBytes = await File(
          arguments['sourcePath']! as String,
        ).readAsBytes();
        return <String, Object?>{
          'ok': true,
          'value': 'content://diagnostics/exported.zip',
        };
      });
      final service = DataSupportFileService(
        diagnosticService: _TestDiagnosticReportService(),
        fileCacheGateway: FileCachePlatformGateway(
          channel: fileCacheChannel,
          isAndroid: () => true,
        ),
        isAndroid: () => true,
      );

      final result = await service.exportDiagnostics(dialogTitle: 'Export');

      expect(result, 'content://diagnostics/exported.zip');
      expect(exportedCall?.method, FileCacheMethod.exportFile);
      expect(exportedBytes, _TestDiagnosticReportService.contents);
      final arguments = Map<String, Object?>.from(
        exportedCall?.arguments as Map,
      );
      expect(
        arguments['fileName'],
        matches(r'^NamelessAudio-diagnostic-\d{8}-\d{6}\.zip$'),
      );
      expect(arguments['mimeType'], 'application/zip');
      expect(
        Directory(path.join(temporaryDirectory.path, 'exports')).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'desktop diagnostics export copies the report and removes staging',
    () async {
      final destination = File(
        path.join(temporaryDirectory.path, 'saved', 'diagnostic.zip'),
      );
      await destination.parent.create(recursive: true);
      filePicker.savePath = destination.path;
      final service = DataSupportFileService(
        diagnosticService: _TestDiagnosticReportService(),
        isAndroid: () => false,
      );

      final result = await service.exportDiagnostics(dialogTitle: 'Export');

      expect(result, destination.path);
      expect(
        await destination.readAsBytes(),
        _TestDiagnosticReportService.contents,
      );
      expect(filePicker.dialogTitle, 'Export');
      expect(filePicker.allowedExtensions, const <String>['zip']);
      expect(filePicker.bytes, isNull);
      expect(
        Directory(path.join(temporaryDirectory.path, 'exports')).existsSync(),
        isFalse,
      );
    },
  );

  test('cancelled desktop export still removes the generated report', () async {
    final service = DataSupportFileService(
      diagnosticService: _TestDiagnosticReportService(),
      isAndroid: () => false,
    );

    expect(await service.exportDiagnostics(dialogTitle: 'Export'), isNull);
    expect(
      Directory(path.join(temporaryDirectory.path, 'exports')).existsSync(),
      isFalse,
    );
  });

  test(
    'global error exporter passes bytes to the picker and cleans up',
    () async {
      filePicker.savePath = path.join(temporaryDirectory.path, 'exported.zip');
      final exporter = DiagnosticReportExporter(
        reportService: _TestDiagnosticReportService(),
      );

      final result = await exporter.export(dialogTitle: 'Export diagnostics');

      expect(result, filePicker.savePath);
      expect(filePicker.dialogTitle, 'Export diagnostics');
      expect(filePicker.allowedExtensions, const <String>['zip']);
      expect(filePicker.bytes, _TestDiagnosticReportService.contents);
      expect(
        File(
          path.join(temporaryDirectory.path, 'NamelessAudio-diagnostic.zip'),
        ).existsSync(),
        isFalse,
      );
    },
  );
}

final class _TestDiagnosticReportService extends DiagnosticReportService {
  static const contents = <int>[0x50, 0x4b, 0x03, 0x04];

  @override
  Future<File> exportReport(String outputPath) async {
    final output = File(outputPath);
    await output.parent.create(recursive: true);
    await output.writeAsBytes(contents, flush: true);
    return output;
  }
}

final class _TestFilePicker extends FilePickerPlatform {
  String? savePath;
  String? dialogTitle;
  List<String>? allowedExtensions;
  Uint8List? bytes;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    this.dialogTitle = dialogTitle;
    this.allowedExtensions = allowedExtensions;
    this.bytes = bytes;
    return savePath;
  }
}
