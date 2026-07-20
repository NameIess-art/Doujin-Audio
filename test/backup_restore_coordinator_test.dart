import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/application/persisted_state_reloader.dart';
import 'package:nameless_audio/features/data_support/application/app_backup_service.dart';
import 'package:nameless_audio/features/data_support/application/backup_restore_coordinator.dart';
import 'package:nameless_audio/features/data_support/application/data_support_file_service.dart';

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
    ).pickAndRestoreBackup();
    const invalidResult = BackupValidationResult.invalid('invalid');
    final invalid = await BackupRestoreCoordinator(
      fileService: _FakeDataSupportFileService(invalidResult),
      reloaders: <PersistedStateReloader>[reloader],
    ).pickAndRestoreBackup();

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
    );

    final restored = await coordinator.pickAndRestoreBackup();

    expect(restored, same(result));
    expect(events, <String>[
      'app:prepare',
      'asmr:prepare',
      'app:start',
      'app:end',
      'asmr:start',
      'asmr:end',
    ]);
  });

  test('failed restore reloads owners after preparation', () async {
    final events = <String>[];
    const result = BackupValidationResult.invalid('restore_failed');
    final coordinator = BackupRestoreCoordinator(
      fileService: _FakeDataSupportFileService(
        result,
        prepareBeforeReturning: true,
      ),
      reloaders: <PersistedStateReloader>[_RecordingReloader('app', events)],
    );

    final restored = await coordinator.pickAndRestoreBackup();

    expect(restored, same(result));
    expect(events, <String>['app:prepare', 'app:start', 'app:end']);
  });
}

final class _FakeDataSupportFileService extends DataSupportFileService {
  _FakeDataSupportFileService(
    this.result, {
    this.prepareBeforeReturning = false,
  }) : super(isAndroid: () => false);

  final BackupValidationResult? result;
  final bool prepareBeforeReturning;

  @override
  Future<BackupValidationResult?> pickAndRestoreBackup({
    Future<void> Function()? beforeRestore,
  }) async {
    if (result?.isValid == true || prepareBeforeReturning) {
      await beforeRestore?.call();
    }
    return result;
  }
}

final class _RecordingReloader
    implements PersistedStateReloader, PersistedStateReplacementPreparer {
  _RecordingReloader(this.name, this.events);

  final String name;
  final List<String> events;

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
