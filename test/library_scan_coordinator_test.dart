import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/errors/app_failure.dart';
import 'package:nameless_audio/features/library/application/library_catalog.dart';
import 'package:nameless_audio/features/library/application/library_scan_coordinator.dart';
import 'package:nameless_audio/features/library/application/library_scanner_service.dart';
import 'package:nameless_audio/features/library/application/audio_detail_repository.dart';

void main() {
  const labels = LibraryScanLabels(
    chooseMusicFolder: 'music',
    chooseLibraryFolder: 'library',
    chooseAudioFiles: 'files',
    importedFiles: 'imported',
    manuallySelectedFiles: 'selected',
  );

  test('refresh stores and returns the typed scan outcome', () async {
    LibraryScanLabels? receivedLabels;
    final scanner = _FakeScanner((_, actualLabels) async {
      receivedLabels = actualLabels;
      return LibraryScanOutcome(
        code: LibraryScanOutcomeCode.refreshAdded,
        source: 'refresh',
        details: <String, Object?>{'count': 2},
      );
    });
    final coordinator = LibraryScanCoordinator(scanner: scanner);
    addTearDown(coordinator.dispose);

    final outcome = await coordinator.refresh(
      catalog: _FakeCatalog(),
      labels: labels,
    );

    expect(receivedLabels, same(labels));
    expect(outcome?.code, LibraryScanOutcomeCode.refreshAdded);
    expect(outcome?.addedCount, 2);
    expect(coordinator.state.phase, LibraryScanPhase.success);
    expect(coordinator.state.outcome, same(outcome));
    expect(coordinator.state.failure, isNull);
  });

  test(
    'failure outcome is typed and does not contain localized UI text',
    () async {
      final coordinator = LibraryScanCoordinator(
        scanner: _FakeScanner(
          (_, _) async => LibraryScanOutcome(
            code: LibraryScanOutcomeCode.permissionDenied,
            source: 'refresh',
          ),
        ),
      );
      addTearDown(coordinator.dispose);

      final outcome = await coordinator.refresh(
        catalog: _FakeCatalog(),
        labels: labels,
      );

      expect(outcome?.code, LibraryScanOutcomeCode.permissionDenied);
      expect(coordinator.state.phase, LibraryScanPhase.failure);
      expect(coordinator.state.failure?.code, 'permissionDenied');
      expect(
        coordinator.state.failure?.message,
        'Library scan did not complete.',
      );
    },
  );

  test('startup refresh can skip JSON detail import', () async {
    final catalog = _FakeCatalog();
    final coordinator = LibraryScanCoordinator(
      scanner: _FakeScanner(
        (_, _) async => LibraryScanOutcome(
          code: LibraryScanOutcomeCode.refreshNoChanges,
          source: 'refresh',
        ),
      ),
    );
    addTearDown(coordinator.dispose);

    await coordinator.refresh(
      catalog: catalog,
      labels: labels,
      importAudioDetails: false,
    );

    expect(catalog.detailImportCount, 0);
  });

  test('manual refresh reports explicit detail import failures', () async {
    final catalog = _FakeCatalog(
      importResult: const AudioDetailBackupImportResult(failureCount: 2),
    );
    final coordinator = LibraryScanCoordinator(
      scanner: _FakeScanner(
        (_, _) async => LibraryScanOutcome(
          code: LibraryScanOutcomeCode.refreshNoChanges,
          source: 'refresh',
        ),
      ),
    );
    addTearDown(coordinator.dispose);

    final outcome = await coordinator.refresh(catalog: catalog, labels: labels);

    expect(catalog.detailImportCount, 1);
    expect(outcome?.details['detailImportFailureCount'], 2);
  });

  test(
    'technical exception is retained as cause behind a stable failure',
    () async {
      final cause = StateError('private scanner detail');
      final coordinator = LibraryScanCoordinator(
        scanner: _FakeScanner(
          (_, _) => Future<LibraryScanOutcome>.error(cause),
        ),
      );
      addTearDown(coordinator.dispose);

      await expectLater(
        coordinator.refresh(catalog: _FakeCatalog(), labels: labels),
        throwsA(
          isA<AppFailure>()
              .having((failure) => failure.code, 'code', 'scan_failed')
              .having(
                (failure) => failure.message,
                'message',
                'Library scan failed.',
              )
              .having((failure) => failure.cause, 'cause', same(cause)),
        ),
      );
      expect(coordinator.state.phase, LibraryScanPhase.failure);
      expect(coordinator.state.failure?.cause, same(cause));
    },
  );
}

typedef _RefreshHandler =
    Future<LibraryScanOutcome> Function(
      LibraryCatalog catalog,
      LibraryScanLabels labels,
    );

class _FakeScanner extends LibraryScannerService {
  _FakeScanner(this._refresh);

  final _RefreshHandler _refresh;

  @override
  Future<LibraryScanOutcome> refreshWatchedFolders({
    required LibraryCatalog provider,
    required LibraryScanLabels labels,
  }) {
    return _refresh(provider, labels);
  }
}

class _FakeCatalog implements LibraryCatalog {
  _FakeCatalog({this.importResult = const AudioDetailBackupImportResult()});

  final AudioDetailBackupImportResult importResult;
  int detailImportCount = 0;

  @override
  Future<AudioDetailBackupImportResult> importAudioDetailBackups() async {
    detailImportCount++;
    return importResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
