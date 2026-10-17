import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/cache/app_cache_service.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';
import 'package:doujin_audio/features/data_support/application/data_support_file_service.dart';
import 'package:doujin_audio/features/data_support/application/data_backup_service.dart';
import 'package:doujin_audio/features/data_support/application/diagnostic_report_exporter.dart';
import 'package:doujin_audio/features/data_support/application/diagnostic_report_service.dart';
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
    AppCacheService.resetForTest(
      temporaryDirectories: () async => [temporaryDirectory],
    );
    AppCacheService.scheduledEnforceEnabled = false;
  });

  tearDown(() async {
    AppCacheService.resetForTest();
    FilePickerPlatform.instance = defaultFilePicker;
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    messenger.setMockMethodCallHandler(fileCacheChannel, null);
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  Future<void> verifyProtected(File file) async {
    await AppCacheService.setMaxCacheBytes(1);
    expect(await file.exists(), isTrue);
    expect(await AppCacheService.clearTemporaryCaches(), 0);
    expect(await file.exists(), isTrue);
  }

  for (final backup in [false, true]) {
    test(
      '${backup ? 'backup' : 'diagnostics'} staging stays leased through generation and desktop save',
      () async {
        final writing = Completer<File>();
        final finishWriting = Completer<void>();
        final saving = Completer<void>();
        final finishSaving = Completer<void>();
        Future<File> generate(String outputPath) async {
          final partial = File('$outputPath.part');
          await partial.writeAsBytes([1, 2, 3]);
          writing.complete(partial);
          await finishWriting.future;
          return partial.rename(outputPath);
        }

        filePicker.savePath = path.join(temporaryDirectory.path, 'saved.data');
        filePicker.onSave = () async {
          saving.complete();
          await finishSaving.future;
        };
        final service = DataSupportFileService(
          diagnosticService: _TestDiagnosticReportService(generate: generate),
          backupService: _TestBackupService(generate: generate),
          isAndroid: () => false,
        );
        final task = backup
            ? service.exportBackup(dialogTitle: 'Save')
            : service.exportDiagnostics(dialogTitle: 'Save');
        final partial = await writing.future;
        await verifyProtected(partial);
        finishWriting.complete();
        await saving.future;
        final output = File(partial.path.substring(0, partial.path.length - 5));
        await verifyProtected(output);
        finishSaving.complete();
        expect(await task, filePicker.savePath);
        expect(await File(filePicker.savePath!).readAsBytes(), [1, 2, 3]);
        expect(await output.exists(), isFalse);
        await output.parent.create(recursive: true);
        await output.writeAsBytes([1, 2, 3]);
        await AppCacheService.enforceLimit();
        expect(await output.exists(), isFalse);
      },
    );
  }

  test(
    'Android export keeps source leased until native export finishes',
    () async {
      final exporting = Completer<File>();
      final finishExport = Completer<void>();
      messenger.setMockMethodCallHandler(fileCacheChannel, (call) async {
        final arguments = Map<String, Object?>.from(call.arguments as Map);
        final source = File(arguments['sourcePath']! as String);
        exporting.complete(source);
        await finishExport.future;
        expect(
          await source.readAsBytes(),
          _TestDiagnosticReportService.contents,
        );
        return {'ok': true, 'value': 'content://export/report.zip'};
      });
      final service = DataSupportFileService(
        diagnosticService: _TestDiagnosticReportService(),
        fileCacheGateway: FileCachePlatformGateway(
          channel: fileCacheChannel,
          isAndroid: () => true,
        ),
        isAndroid: () => true,
      );
      final task = service.exportDiagnostics(dialogTitle: 'Save');
      final source = await exporting.future;
      await verifyProtected(source);
      finishExport.complete();
      expect(await task, 'content://export/report.zip');
      expect(await source.exists(), isFalse);
    },
  );

  test(
    'stream backup remains present until asynchronous validation finishes',
    () async {
      final validating = Completer<File>();
      final finishValidation = Completer<void>();
      filePicker.picked = FilePickerResult([
        PlatformFile(
          name: 'backup.dabackup',
          size: 3,
          readStream: Stream.value([1, 2, 3]),
        ),
      ]);
      final service = DataSupportFileService(
        backupService: _TestBackupService(
          inspect: (inputPath) async {
            final input = File(inputPath);
            validating.complete(input);
            await finishValidation.future;
            expect(await input.readAsBytes(), [1, 2, 3]);
            return BackupValidationResult(
              manifest: BackupManifest(
                formatVersion: 1,
                appVersion: '1.0.0',
                databaseSchemaVersion: 13,
                platform: 'test',
                createdAt: DateTime.utc(2026),
                containsSensitiveAccountData: false,
                files: const {},
              ),
            );
          },
        ),
      );
      final task = service.pickAndStageBackup(dialogTitle: 'Open');
      final input = await validating.future;
      await verifyProtected(input);
      finishValidation.complete();
      expect(await task, isA<BackupValidationResult>());
      expect(await input.exists(), isFalse);
    },
  );

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
        matches(r'^DoujinAudio-diagnostic-\d{8}-\d{6}\.zip$'),
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
          path.join(temporaryDirectory.path, 'DoujinAudio-diagnostic.zip'),
        ).existsSync(),
        isFalse,
      );
    },
  );
}

final class _TestDiagnosticReportService extends DiagnosticReportService {
  _TestDiagnosticReportService({this.generate});
  final Future<File> Function(String)? generate;
  static const contents = <int>[0x50, 0x4b, 0x03, 0x04];

  @override
  Future<File> exportReport(String outputPath) async {
    if (generate != null) return generate!(outputPath);
    final output = File(outputPath);
    await output.parent.create(recursive: true);
    await output.writeAsBytes(contents, flush: true);
    return output;
  }
}

final class _TestBackupService extends DataBackupService {
  _TestBackupService({this.generate, this.inspect});
  final Future<File> Function(String)? generate;
  final Future<BackupValidationResult> Function(String)? inspect;

  @override
  Future<File> exportBackup(String outputPath) => generate!(outputPath);

  @override
  Future<BackupValidationResult> inspectAndStageRestore(String archivePath) =>
      inspect!(archivePath);
}

final class _TestFilePicker extends FilePickerPlatform {
  String? savePath;
  String? dialogTitle;
  List<String>? allowedExtensions;
  Uint8List? bytes;
  Future<void> Function()? onSave;
  FilePickerResult? picked;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async => picked;

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
    await onSave?.call();
    return savePath;
  }
}
