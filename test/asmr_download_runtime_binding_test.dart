import 'dart:async';
import 'dart:io';

import 'package:doujin_audio/app/application/asmr_download_runtime_binding.dart';
import 'package:doujin_audio/core/cache/app_cache_service.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_download.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/library/application/library_catalog.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/library_scan_coordinator.dart';
import 'package:doujin_audio/features/library/application/library_scan_data_source.dart';
import 'package:doujin_audio/features/library/application/library_scanner_service.dart';
import 'package:doujin_audio/features/player/domain/time_segment_label.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'support/test_persistence_repository.dart';

const _labels = LibraryScanLabels(
  chooseMusicFolder: 'music',
  chooseLibraryFolder: 'library',
  chooseAudioFiles: 'files',
  importedFiles: 'imported',
  manuallySelectedFiles: 'selected',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LibraryFacade library;
  late _CompletionDownloads downloads;
  late SettingsRepository settings;
  late _ControlledScanner scanner;
  late LibraryScanCoordinator scans;
  late AsmrDownloadRuntimeBinding binding;
  late _DetailPersistence repository;
  var labels = _labels;

  setUp(() {
    AppCacheService.scheduledEnforceEnabled = false;
    repository = _DetailPersistence();
    library = LibraryFacade.create(databaseRepository: repository);
    library.configurePersistence(enabled: false);
    library.syncPresentationState(isInitialized: true);
    downloads = _CompletionDownloads();
    settings = SettingsRepository();
    scanner = _ControlledScanner();
    scans = LibraryScanCoordinator(scanner: scanner);
    labels = _labels;
    binding = AsmrDownloadRuntimeBinding.attach(
      downloads: downloads,
      settings: settings,
      library: library,
      scanLabels: () => labels,
      scanCoordinator: scans,
    );
  });

  tearDown(() async {
    await binding.dispose();
    await downloads.shutdown();
    await library.dispose();
    await settings.dispose();
    AppCacheService.resetForTest();
  });

  test('completion waits for library initialization', () async {
    library.syncPresentationState(isInitialized: false);
    library.addWatchedLibrary(r'C:\音频 库');
    downloads.complete();
    await _settle();
    expect(scanner.labels, isEmpty);

    library.syncPresentationState(isInitialized: true);
    await _settle();
    expect(scanner.labels, hasLength(1));
    expect(library.watchedLibraries, [r'C:\音频 库']);
  });

  test(
    'completion without sources does not register the download folder',
    () async {
      downloads.complete();
      await _settle();
      expect(scanner.labels, isEmpty);
      expect(library.watchedFolders, isEmpty);
      expect(library.watchedLibraries, isEmpty);
    },
  );

  test('completion discovers new audio only inside existing library', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'download_refresh_',
    );
    final watched = await Directory(path.join(temporary.path, '音频 库')).create();
    final outside = await Directory(
      path.join(temporary.path, 'outside'),
    ).create();
    final insideAudio = await File(
      path.join(watched.path, 'new.mp3'),
    ).writeAsBytes([1]);
    final outsideAudio = await File(
      path.join(outside.path, 'outside.mp3'),
    ).writeAsBytes([1]);
    addTearDown(() async {
      await insideAudio.delete();
      await outsideAudio.delete();
      await watched.delete();
      await outside.delete();
      await temporary.delete();
    });
    library.addWatchedLibrary(watched.path);
    await binding.dispose();
    scans = LibraryScanCoordinator(
      scanner: LibraryScannerService(dataSource: _FileSystemSource()),
    );
    binding = AsmrDownloadRuntimeBinding.attach(
      downloads: downloads,
      settings: settings,
      library: library,
      scanLabels: () => labels,
      scanCoordinator: scans,
    );
    final finished = Completer<void>();
    scans.addListener(() {
      if (scans.state.phase == LibraryScanPhase.success ||
          scans.state.phase == LibraryScanPhase.failure) {
        finished.complete();
      }
    });

    downloads.complete();
    await finished.future.timeout(const Duration(seconds: 10));
    expect(
      scans.state.phase,
      LibraryScanPhase.success,
      reason: '${scans.state.failure?.cause} ${scans.state.failure?.details}',
    );
    expect(library.library.map((track) => track.path), [insideAudio.path]);
    expect(library.watchedLibraries, [watched.path]);
    expect(library.watchedFolders, isNot(contains(outside.path)));
    expect(repository.saveCount, 1);
  });

  test(
    'empty sources consume completion while a manual scan holds its lease',
    () async {
      final manual = library.tryBeginScan(source: 'manual');
      downloads.complete();
      await _settle();
      library.addWatchedLibrary(r'C:\音频 库');
      library.finishScan(manual);
      await _settle();
      expect(scanner.labels, isEmpty);
      downloads.complete();
      await _settle();
      expect(scanner.labels, hasLength(1));
    },
  );

  test(
    'busy completions merge and wait for a cancelled scan to release',
    () async {
      library.addWatchedFolder('content://downloads/tree/library');
      final manual = library.tryBeginScan(source: 'manual');
      downloads.complete();
      downloads.complete();
      await _settle();
      expect(scanner.labels, isEmpty);

      library.cancelScan();
      downloads.complete();
      await _settle();
      expect(library.isScanning, isFalse);
      expect(scanner.labels, isEmpty);

      library.finishScan(manual);
      await _settle();
      expect(scanner.labels, hasLength(1));
    },
  );

  test(
    'completion during refresh schedules one more using current labels',
    () async {
      library.addWatchedLibrary(r'C:\音频 库');
      final release = Completer<void>();
      scanner.beforeFinish = () => release.future;
      downloads.complete();
      await _settle();
      expect(scanner.labels, [_labels]);

      labels = const LibraryScanLabels(
        chooseMusicFolder: '音楽',
        chooseLibraryFolder: 'ライブラリ',
        chooseAudioFiles: '音声',
        importedFiles: 'インポート',
        manuallySelectedFiles: '選択',
      );
      downloads.complete();
      downloads.complete();
      await _settle();
      expect(scanner.labels, hasLength(1));
      scanner.beforeFinish = null;
      release.complete();
      await _settle();
      expect(scanner.labels, [_labels, labels]);
    },
  );

  test('refresh failure does not retry or change completed download', () async {
    library.addWatchedLibrary(r'C:\音频 库');
    scanner.error = StateError('unavailable folder');
    final completed = downloads.complete();
    await _settle();
    expect(scanner.labels, hasLength(1));
    expect(scans.state.phase, LibraryScanPhase.failure);
    expect(downloads.tasks.single, same(completed));
    expect(downloads.tasks.single.status, AsmrDownloadTaskStatus.completed);
    expect(library.watchedLibraries, [r'C:\音频 库']);
  });

  test('dispose cancels owned refresh and waits for lease release', () async {
    library.addWatchedLibrary(r'C:\音频 库');
    final release = Completer<void>();
    scanner.beforeFinish = () => release.future;
    downloads.complete();
    await _settle();
    expect(library.isScanning, isTrue);

    var disposed = false;
    final disposal = binding.dispose();
    expect(binding.dispose(), same(disposal));
    final observedDisposal = disposal.then((_) => disposed = true);
    await _settle();
    expect(library.isScanning, isFalse);
    expect(disposed, isFalse);
    downloads.complete();
    release.complete();
    await observedDisposal;
    expect(scanner.labels, hasLength(1));
    expect(library.tryBeginScan(source: 'after disposal'), isNonZero);
    library.finishScan(library.scanRevision);
  });

  test(
    'dispose drops pending refresh without cancelling manual scan',
    () async {
      library.addWatchedLibrary(r'C:\音频 库');
      final manual = library.tryBeginScan(source: 'manual');
      downloads.complete();
      await _settle();
      await binding.dispose();
      expect(library.isScanGenerationActive(manual), isTrue);
      library.finishScan(manual);
      downloads.complete();
      await _settle();
      expect(scanner.labels, isEmpty);
    },
  );

  test(
    'manual scan started during preflight retains one pending refresh',
    () async {
      final watched = await Directory.systemTemp.createTemp(
        'preflight_refresh_',
      );
      addTearDown(watched.delete);
      library.addWatchedLibrary(watched.path);
      await binding.dispose();
      final source = _DelayedPermissionSource();
      scans = LibraryScanCoordinator(
        scanner: LibraryScannerService(dataSource: source),
      );
      binding = AsmrDownloadRuntimeBinding.attach(
        downloads: downloads,
        settings: settings,
        library: library,
        scanLabels: () => labels,
        scanCoordinator: scans,
      );
      downloads.complete();
      await _settle();
      final manual = library.tryBeginScan(source: 'manual during preflight');
      source.permission.complete(true);
      await _settle();
      expect(scans.state.outcome?.code, LibraryScanOutcomeCode.alreadyRunning);
      expect(source.permissionChecks, 1);
      expect(source.scanCalls, 0);
      expect(library.isScanGenerationActive(manual), isTrue);
      final finished = Completer<void>();
      scans.addListener(() {
        if (scans.state.phase == LibraryScanPhase.success) finished.complete();
      });
      library.finishScan(manual);
      await finished.future.timeout(const Duration(seconds: 10));
      expect(source.permissionChecks, 2);
      expect(source.scanCalls, 1);
    },
  );

  test(
    'dispose during permission check prevents scanning after permission arrives',
    () async {
      library.addWatchedLibrary(r'C:\音频 库');
      await binding.dispose();
      final source = _DelayedPermissionSource();
      scans = LibraryScanCoordinator(
        scanner: LibraryScannerService(dataSource: source),
      );
      binding = AsmrDownloadRuntimeBinding.attach(
        downloads: downloads,
        settings: settings,
        library: library,
        scanLabels: () => labels,
        scanCoordinator: scans,
      );
      downloads.complete();
      await _settle();
      expect(library.isScanning, isFalse);
      var disposed = false;
      final disposal = binding.dispose().then((_) => disposed = true);
      await _settle();
      expect(disposed, isFalse);
      source.permission.complete(true);
      await disposal;
      expect(source.scanCalls, 0);
      expect(library.isScanning, isFalse);
      expect(
        library.tryBeginScan(source: 'after preflight disposal'),
        isNonZero,
      );
      library.finishScan(library.scanRevision);
    },
  );

  test(
    'dispose waits for detail import after its scan lease is released',
    () async {
      library.addWatchedLibrary(r'C:\音频 库');
      scanner.outcome = LibraryScanOutcomeCode.refreshAdded;
      final details = Completer<void>();
      repository.beforeSave = () => details.future;
      downloads.complete();
      await _settle();
      expect(repository.saveCount, 1);
      expect(library.isScanning, isFalse);
      final manual = library.tryBeginScan(source: 'manual during details');

      var disposed = false;
      final disposal = binding.dispose().then((_) => disposed = true);
      await _settle();
      expect(disposed, isFalse);
      expect(library.isScanGenerationActive(manual), isTrue);
      details.complete();
      await disposal;
      expect(library.isScanGenerationActive(manual), isTrue);
      library.finishScan(manual);
    },
  );
}

Future<void> _settle() async {
  for (var index = 0; index < 4; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _DetailPersistence extends TestPersistenceRepository {
  Future<void> Function()? beforeSave;
  int saveCount = 0;

  @override
  Future<List<AudioDetail>> loadMany(
    Iterable<AudioDetailTarget> targets,
  ) async => [];

  @override
  Future<void> importDetails(
    Iterable<AudioDetail> details,
    Iterable<TimeSegmentLabel> labels,
  ) async {}

  @override
  Future<void> saveAppSetting(String key, String? value) async {
    saveCount++;
    await beforeSave?.call();
  }
}

class _FileSystemSource extends PlatformLibraryScanDataSource {
  _FileSystemSource() : super(isAndroid: () => false);

  int scanCalls = 0;

  @override
  Future<NativeScanResult> scanFolderChunked(
    String folderPath,
    FutureOr<bool> Function(FolderScanChunk chunk) onChunk, {
    FutureOr<void> Function(FolderScanSessionEvent event)? onProgress,
  }) {
    scanCalls++;
    return scanFileSystemFolderChunked(folderPath, onChunk);
  }
}

class _DelayedPermissionSource extends _FileSystemSource {
  final permission = Completer<bool>();
  int permissionChecks = 0;

  @override
  Future<bool> ensureReadPermissionForSources(Iterable<String> sources) {
    permissionChecks++;
    return permission.future;
  }
}

class _ControlledScanner extends LibraryScannerService {
  final labels = <LibraryScanLabels>[];
  Future<void> Function()? beforeFinish;
  Object? error;
  LibraryScanOutcomeCode outcome = LibraryScanOutcomeCode.refreshNoChanges;

  @override
  Future<LibraryScanOutcome> refreshWatchedFolders({
    required LibraryCatalog provider,
    required LibraryScanLabels labels,
    void Function(int generation)? onScanStarted,
  }) async {
    this.labels.add(labels);
    final generation = provider.tryBeginScan(source: 'automatic');
    expect(generation, isNonZero);
    onScanStarted?.call(generation);
    try {
      await beforeFinish?.call();
      if (error != null) throw error!;
      return LibraryScanOutcome(code: outcome, source: 'refresh');
    } finally {
      provider.finishScan(generation);
    }
  }
}

class _CompletionDownloads extends AsmrDownloadManager {
  _CompletionDownloads() : super(persistTasks: false);

  final _completions = StreamController<AsmrDownloadTaskSnapshot>.broadcast();
  final _tasks = <AsmrDownloadTaskSnapshot>[];

  @override
  Stream<AsmrDownloadTaskSnapshot> get completedTasks => _completions.stream;

  @override
  List<AsmrDownloadTaskSnapshot> get tasks => _tasks;

  AsmrDownloadTaskSnapshot complete() {
    final task = AsmrDownloadTaskSnapshot(
      work: AsmrWork.fromJson({'id': _tasks.length + 1, 'title': 'Downloaded'}),
      destinationRoot: r'C:\Downloads outside library',
      workFolderName: 'work',
      conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
      status: AsmrDownloadTaskStatus.completed,
      totalFiles: 1,
      completedFiles: 1,
      skippedFiles: 0,
      failedFiles: 0,
      totalBytes: 1,
      downloadedBytes: 1,
      startedAt: DateTime(2026),
    );
    _tasks.add(task);
    _completions.add(task);
    return task;
  }

  @override
  Future<void> shutdown() async {
    await _completions.close();
    await super.shutdown();
  }
}
