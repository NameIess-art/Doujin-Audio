import 'dart:io';

import 'package:file_picker/file_picker.dart';
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/persistence/app_database.dart';
import 'package:nameless_audio/features/data_support/application/app_backup_service.dart';
import 'package:nameless_audio/features/data_support/application/data_support_file_service.dart';
import 'package:nameless_audio/features/settings/application/app_update_service.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory temporaryDirectory;
  late File databaseFile;
  late Map<String, Object> preferences;
  final defaultFilePicker = FilePickerPlatform.instance;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'data_support_file_service_test_',
    );
    databaseFile = File(path.join(temporaryDirectory.path, 'audio_player.db'));
    await _createDatabase(databaseFile, marker: 'original database');
    preferences = <String, Object>{'language': 'zh', 'themeMode': 'dark'};
    FilePickerPlatform.instance = _TestFilePicker();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getTemporaryDirectory') {
            return temporaryDirectory.path;
          }
          return null;
        });
  });

  tearDown(() async {
    FilePickerPlatform.instance = defaultFilePicker;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  AppBackupService createBackupService() {
    return AppBackupService(
      databasePathProvider: () async => databaseFile.path,
      closeDatabase: () async {},
      reopenDatabase: () async {},
      exportPreferences: () async => Map<String, Object>.from(preferences),
      restorePreferences: (values) async {
        preferences = values.cast<String, Object>();
      },
      appVersionProvider: () async =>
          const AppVersionInfo(versionName: '1.2.3', buildNumber: 4),
      platformName: 'test',
    );
  }

  test(
    'export keeps the generated backup alive until desktop save finishes',
    () async {
      final destination = File(
        path.join(temporaryDirectory.path, 'saved', 'exported.nalbackup'),
      );
      await destination.parent.create(recursive: true);
      final picker = _TestFilePicker(
        savePath: destination.path,
        saveDelay: const Duration(milliseconds: 20),
      );
      FilePickerPlatform.instance = picker;
      final backupService = createBackupService();
      final service = DataSupportFileService(
        backupService: backupService,
        isAndroid: () => false,
      );

      final savedPath = await service.exportBackup(
        dialogTitle: 'Export backup',
      );

      expect(savedPath, destination.path);
      expect(await destination.exists(), isTrue);
      expect(
        (await backupService.validateBackup(destination.path)).isValid,
        isTrue,
      );
      expect(
        Directory(path.join(temporaryDirectory.path, 'exports')).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'Android restore reads the selected backup before picker cache cleanup',
    () async {
      final backupService = createBackupService();
      final selectedBackup = await backupService.exportBackup(
        path.join(temporaryDirectory.path, 'picked.nalbackup'),
      );
      await _createDatabase(databaseFile, marker: 'changed database');
      preferences = <String, Object>{'language': 'en'};
      final picker = _TestFilePicker(selectedFile: selectedBackup);
      FilePickerPlatform.instance = picker;
      final service = DataSupportFileService(
        backupService: backupService,
        isAndroid: () => true,
      );

      final result = await service.pickAndRestoreBackup();

      expect(result?.isValid, isTrue);
      expect(await _readMarker(databaseFile), 'original database');
      expect(preferences, containsPair('language', 'zh'));
      expect(preferences, containsPair('themeMode', 'dark'));
      expect(picker.clearTemporaryFilesCalled, isTrue);
      expect(await selectedBackup.exists(), isFalse);
    },
  );
}

Future<void> _createDatabase(File file, {required String marker}) async {
  if (await file.exists()) await file.delete();
  final db = await databaseFactoryFfi.openDatabase(file.path);
  try {
    await AppDatabase.createSchemaForTest(db);
    await db.setVersion(AppDatabase.schemaVersion);
    await db.insert('app_kv_settings', <String, Object?>{
      'key': 'test_marker',
      'value': marker,
    });
  } finally {
    await db.close();
  }
}

Future<String?> _readMarker(File file) async {
  final db = await databaseFactoryFfi.openDatabase(
    file.path,
    options: OpenDatabaseOptions(readOnly: true),
  );
  try {
    final rows = await db.query(
      'app_kv_settings',
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object?>['test_marker'],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['value'] as String?;
  } finally {
    await db.close();
  }
}

final class _TestFilePicker extends FilePickerPlatform {
  _TestFilePicker({
    this.savePath,
    this.saveDelay = Duration.zero,
    this.selectedFile,
  });

  final String? savePath;
  final Duration saveDelay;
  final File? selectedFile;
  bool clearTemporaryFilesCalled = false;

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
    await Future<void>.delayed(saveDelay);
    return savePath;
  }

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
  }) async {
    final file = selectedFile;
    if (file == null) return null;
    return FilePickerResult(<PlatformFile>[
      PlatformFile(
        name: path.basename(file.path),
        size: await file.length(),
        path: file.path,
      ),
    ]);
  }

  @override
  Future<bool?> clearTemporaryFiles() async {
    clearTemporaryFilesCalled = true;
    final file = selectedFile;
    if (file != null && await file.exists()) await file.delete();
    return true;
  }
}
