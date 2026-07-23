import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/application/persisted_state_reloader.dart';
import 'package:nameless_audio/features/data_support/application/app_backup_service.dart';
import 'package:nameless_audio/features/data_support/application/backup_restore_coordinator.dart';
import 'package:nameless_audio/features/data_support/application/data_support_file_service.dart';
import 'package:nameless_audio/features/library/application/library_scan_models.dart';

const _labels = LibraryScanLabels(
  chooseMusicFolder: 'folder',
  chooseLibraryFolder: 'library',
  chooseAudioFiles: 'files',
  importedFiles: 'imported',
  manuallySelectedFiles: 'manual',
);

void main() {
  final validManifest = BackupManifest(
    formatVersion: 1,
    dataEpoch: 1,
    appVersion: 'test',
    createdAt: DateTime.utc(2026),
    platform: 'test',
    databaseSchemaVersion: 3,
    entries: <String, BackupEntryManifest>{},
  );

  test('cancelled and invalid restores do not reload state owners', () async {
    final events = <String>[];
    final reloader = _RecordingReloader('app', events);

    final cancelled = await BackupRestoreCoordinator(
      fileService: _FakeDataSupportFileService(null),
      reloaders: <PersistedStateReloader>[reloader],
      readLibrarySources: () => LocalLibraryImportSources(),
      prepareLibrarySources: (sources, labels) async => sources,
      restoreLibrarySources: (sources, labels) async {},
    ).pickAndRestoreBackup(labels: _labels);
    final invalidResult = BackupValidationResult.invalid('invalid');
    final invalid = await BackupRestoreCoordinator(
      fileService: _FakeDataSupportFileService(invalidResult),
      reloaders: <PersistedStateReloader>[reloader],
      readLibrarySources: () => LocalLibraryImportSources(),
      prepareLibrarySources: (sources, labels) async => sources,
      restoreLibrarySources: (sources, labels) async {},
    ).pickAndRestoreBackup(labels: _labels);

    expect(cancelled, isNull);
    expect(invalid, same(invalidResult));
    expect(events, isEmpty);
  });

  test('valid restore reloads every owner sequentially', () async {
    final events = <String>[];
    final result = BackupValidationResult.valid(validManifest);
    final coordinator = BackupRestoreCoordinator(
      fileService: _FakeDataSupportFileService(result),
      reloaders: <PersistedStateReloader>[
        _RecordingReloader('app', events),
        _RecordingReloader('asmr', events),
      ],
      readLibrarySources: () => LocalLibraryImportSources(),
      prepareLibrarySources: (sources, labels) async {
        events.add('library:prepare');
        return sources;
      },
      restoreLibrarySources: (sources, labels) async {
        events.add('library:restore');
      },
    );

    final restored = await coordinator.pickAndRestoreBackup(labels: _labels);

    expect(restored, same(result));
    expect(events, <String>[
      'library:prepare',
      'app:prepare',
      'asmr:prepare',
      'app:start',
      'app:end',
      'asmr:start',
      'asmr:end',
      'library:restore',
    ]);
  });

  test('source picker cancellation does not replace or reload state', () async {
    final events = <String>[];
    final coordinator = BackupRestoreCoordinator(
      fileService: _FakeDataSupportFileService(
        BackupValidationResult.valid(validManifest),
      ),
      reloaders: <PersistedStateReloader>[_RecordingReloader('app', events)],
      readLibrarySources: () => LocalLibraryImportSources(),
      prepareLibrarySources: (sources, labels) async {
        events.add('library:cancel');
        return null;
      },
      restoreLibrarySources: (sources, labels) async {},
    );

    final result = await coordinator.pickAndRestoreBackup(labels: _labels);

    expect(result?.isCancelled, isTrue);
    expect(events, <String>['library:cancel']);
  });

  test(
    'export flushes every state owner before creating the archive',
    () async {
      final events = <String>[];
      final coordinator = BackupRestoreCoordinator(
        fileService: _FakeDataSupportFileService(
          null,
          exportedPath: 'backup.nalbackup',
          events: events,
        ),
        reloaders: <PersistedStateReloader>[
          _RecordingReloader('app', events),
          _RecordingReloader('asmr', events),
        ],
        readLibrarySources: () {
          events.add('library:read');
          return LocalLibraryImportSources(files: <String>['song.mp3']);
        },
        prepareLibrarySources: (sources, labels) async => sources,
        restoreLibrarySources: (sources, labels) async {},
      );

      final path = await coordinator.exportBackup(dialogTitle: 'Export');

      expect(path, 'backup.nalbackup');
      expect(events, <String>[
        'app:export',
        'asmr:export',
        'library:read',
        'archive:export',
      ]);
    },
  );

  test('failed restore reloads owners after preparation', () async {
    final events = <String>[];
    final result = BackupValidationResult.invalid('restore_failed');
    final coordinator = BackupRestoreCoordinator(
      fileService: _FakeDataSupportFileService(
        result,
        prepareBeforeReturning: true,
      ),
      reloaders: <PersistedStateReloader>[_RecordingReloader('app', events)],
      readLibrarySources: () => LocalLibraryImportSources(),
      prepareLibrarySources: (sources, labels) async {
        events.add('library:prepare');
        return sources;
      },
      restoreLibrarySources: (sources, labels) async {},
    );

    final restored = await coordinator.pickAndRestoreBackup(labels: _labels);

    expect(restored, same(result));
    expect(events, <String>[
      'library:prepare',
      'app:prepare',
      'app:start',
      'app:end',
    ]);
  });
}

final class _FakeDataSupportFileService extends DataSupportFileService {
  _FakeDataSupportFileService(
    this.result, {
    this.prepareBeforeReturning = false,
    this.exportedPath,
    this.events,
  }) : super(isAndroid: () => false);

  final BackupValidationResult? result;
  final bool prepareBeforeReturning;
  final String? exportedPath;
  final List<String>? events;

  @override
  Future<String?> exportBackup({
    required String dialogTitle,
    LocalLibraryImportSources? librarySources,
  }) async {
    events?.add('archive:export');
    return exportedPath;
  }

  @override
  Future<BackupValidationResult?> pickAndRestoreBackup({
    Future<LocalLibraryImportSources?> Function(LocalLibraryImportSources)?
    beforeRestore,
  }) async {
    if (result?.isValid == true || prepareBeforeReturning) {
      final sources = await beforeRestore?.call(
        result?.librarySources ?? LocalLibraryImportSources(),
      );
      if (result?.isValid == true && sources == null) {
        return BackupValidationResult.cancelled();
      }
      if (result?.isValid == true && sources != null) {
        if (identical(sources, result!.librarySources)) return result;
        return BackupValidationResult.valid(
          result!.manifest!,
          librarySources: sources,
        );
      }
    }
    return result;
  }
}

final class _RecordingReloader
    implements
        PersistedStateReloader,
        PersistedStateExportPreparer,
        PersistedStateReplacementPreparer {
  _RecordingReloader(this.name, this.events);

  final String name;
  final List<String> events;

  @override
  Future<void> prepareForPersistedStateExport() async {
    events.add('$name:export');
  }

  @override
  Future<void> prepareForPersistedStateReplacement() async {
    events.add('$name:prepare');
  }

  @override
  Future<void> reloadPersistedState() async {
    events.add('$name:start');
    await Future<void>.delayed(Duration.zero);
    events.add('$name:end');
  }
}
