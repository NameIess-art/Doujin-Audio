import 'dart:async';

import 'package:flutter/foundation.dart';

@immutable
class UiOperationScope {
  const UiOperationScope(this.value);

  final String value;

  static const settingsUpdate = UiOperationScope('settings:update');
  static const settingsCache = UiOperationScope('settings:cache');
  static const settingsAsmrDownloadPath = UiOperationScope(
    'settings:asmr-download-path',
  );
  static const settingsPermissionStatus = UiOperationScope(
    'settings:permission-status',
  );
  static const dataSupportBackupExport = UiOperationScope(
    'data-support:backup-export',
  );
  static const dataSupportBackupRestore = UiOperationScope(
    'data-support:backup-restore',
  );
  static const dataSupportDiagnosticsExport = UiOperationScope(
    'data-support:diagnostics-export',
  );
  static const libraryRefresh = UiOperationScope('library:refresh');
  static const libraryImportFolder = UiOperationScope('library:import-folder');
  static const libraryImportFiles = UiOperationScope('library:import-files');
  static const libraryImportLibrary = UiOperationScope(
    'library:import-library',
  );
  static const metadataBatch = UiOperationScope('metadata:batch');
  static const asmrDownloadInit = UiOperationScope('asmr-download:init');
  static const asmrDownloadStart = UiOperationScope('asmr-download:start');
  static const timerReliability = UiOperationScope('timer:reliability');
  static const videoConverterPick = UiOperationScope('video-converter:pick');
  static const videoConverterConvert = UiOperationScope(
    'video-converter:convert',
  );

  static UiOperationScope audioDetail(String targetKey) {
    return UiOperationScope('audio-detail:$targetKey');
  }

  static UiOperationScope metadataReview(String targetKey) {
    return UiOperationScope('metadata:review:$targetKey');
  }

  static UiOperationScope pageOpen(String pageKey) {
    return UiOperationScope('page-open:$pageKey');
  }

  static UiOperationScope asmrCategory(AsmrOperationKind kind, String name) {
    return UiOperationScope('asmr:${kind.name}:$name');
  }

  static UiOperationScope asmrWork(AsmrOperationKind kind, int workId) {
    return UiOperationScope('asmr:${kind.name}:$workId');
  }

  @override
  bool operator ==(Object other) {
    return other is UiOperationScope && other.value == value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

enum AsmrOperationKind { refresh, loadMore, detail, trackTree, play, favorite }

enum UiOperationPhase { idle, running, succeeded, failed, canceled }

@immutable
class UiOperationState {
  const UiOperationState({
    required this.operationId,
    required this.scope,
    required this.labelKey,
    required this.phase,
    required this.startedAt,
    this.progress,
    this.error,
    this.completedAt,
  });

  static UiOperationState idle(UiOperationScope scope) {
    return UiOperationState(
      operationId: 0,
      scope: scope,
      labelKey: '',
      phase: UiOperationPhase.idle,
      startedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  final int operationId;
  final UiOperationScope scope;
  final String labelKey;
  final UiOperationPhase phase;
  final double? progress;
  final Object? error;
  final DateTime startedAt;
  final DateTime? completedAt;

  bool get isBusy => phase == UiOperationPhase.running;
  bool get hasError => phase == UiOperationPhase.failed;
  bool get hasResult =>
      phase == UiOperationPhase.succeeded || phase == UiOperationPhase.failed;

  UiOperationState copyWith({
    int? operationId,
    UiOperationScope? scope,
    String? labelKey,
    UiOperationPhase? phase,
    double? progress,
    Object? error,
    DateTime? startedAt,
    DateTime? completedAt,
    bool clearProgress = false,
    bool clearError = false,
    bool clearCompletedAt = false,
  }) {
    return UiOperationState(
      operationId: operationId ?? this.operationId,
      scope: scope ?? this.scope,
      labelKey: labelKey ?? this.labelKey,
      phase: phase ?? this.phase,
      progress: clearProgress ? null : progress ?? this.progress,
      error: clearError ? null : error ?? this.error,
      startedAt: startedAt ?? this.startedAt,
      completedAt: clearCompletedAt ? null : completedAt ?? this.completedAt,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is UiOperationState &&
        other.operationId == operationId &&
        other.scope == scope &&
        other.labelKey == labelKey &&
        other.phase == phase &&
        other.progress == progress &&
        other.error == error &&
        other.startedAt == startedAt &&
        other.completedAt == completedAt;
  }

  @override
  int get hashCode => Object.hash(
    operationId,
    scope,
    labelKey,
    phase,
    progress,
    error,
    startedAt,
    completedAt,
  );
}

@immutable
class UiOperationRegistryState {
  const UiOperationRegistryState(this.operations);

  final Map<UiOperationScope, UiOperationState> operations;

  static const empty = UiOperationRegistryState(
    <UiOperationScope, UiOperationState>{},
  );

  UiOperationState forScope(UiOperationScope scope) {
    return operations[scope] ?? UiOperationState.idle(scope);
  }

  @override
  bool operator ==(Object other) {
    return other is UiOperationRegistryState &&
        mapEquals(other.operations, operations);
  }

  @override
  int get hashCode => Object.hashAllUnordered(operations.entries);
}

class UiOperationProgress {
  const UiOperationProgress._(this._service, this._scope, this._operationId);

  final UiOperationService _service;
  final UiOperationScope _scope;
  final int _operationId;

  void report(double progress) {
    _service._updateProgress(_scope, _operationId, progress);
  }
}

typedef UiOperationTask<T> = Future<T> Function(UiOperationProgress progress);

class UiOperationService {
  UiOperationService();

  static final UiOperationService instance = UiOperationService();

  final StreamController<UiOperationRegistryState> _controller =
      StreamController<UiOperationRegistryState>.broadcast();
  final Map<UiOperationScope, UiOperationState> _operations =
      <UiOperationScope, UiOperationState>{};
  int _nextOperationId = 0;

  UiOperationRegistryState get state => UiOperationRegistryState(
    Map<UiOperationScope, UiOperationState>.unmodifiable(_operations),
  );

  Stream<UiOperationRegistryState> get stream async* {
    yield state;
    yield* _controller.stream;
  }

  UiOperationState operationFor(UiOperationScope scope) {
    return _operations[scope] ?? UiOperationState.idle(scope);
  }

  bool isBusy(UiOperationScope scope) => operationFor(scope).isBusy;

  double? progressFor(UiOperationScope scope) => operationFor(scope).progress;

  Future<T> run<T>({
    required UiOperationScope scope,
    required String labelKey,
    required UiOperationTask<T> task,
    FutureOr<void> Function(T value)? onSuccess,
    FutureOr<void> Function(Object error, StackTrace stackTrace)? onError,
    bool cancelPrevious = true,
  }) async {
    final existing = _operations[scope];
    if (!cancelPrevious && existing?.isBusy == true) {
      throw StateError('Operation already running for $scope');
    }

    if (cancelPrevious && existing?.isBusy == true) {
      _operations[scope] = existing!.copyWith(
        phase: UiOperationPhase.canceled,
        completedAt: DateTime.now(),
      );
    }

    final operationId = ++_nextOperationId;
    _operations[scope] = UiOperationState(
      operationId: operationId,
      scope: scope,
      labelKey: labelKey,
      phase: UiOperationPhase.running,
      startedAt: DateTime.now(),
    );
    _emit();

    try {
      final value = await task(UiOperationProgress._(this, scope, operationId));
      if (_isCurrent(scope, operationId)) {
        _operations[scope] = operationFor(scope).copyWith(
          phase: UiOperationPhase.succeeded,
          progress: 1,
          clearError: true,
          completedAt: DateTime.now(),
        );
        _emit();
        await onSuccess?.call(value);
      }
      return value;
    } catch (error, stackTrace) {
      if (_isCurrent(scope, operationId)) {
        _operations[scope] = operationFor(scope).copyWith(
          phase: UiOperationPhase.failed,
          error: error,
          completedAt: DateTime.now(),
        );
        _emit();
        await onError?.call(error, stackTrace);
      }
      rethrow;
    }
  }

  void clear(UiOperationScope scope) {
    if (_operations.remove(scope) != null) _emit();
  }

  void clearCompleted({
    Duration olderThan = const Duration(seconds: 2),
    DateTime? now,
  }) {
    final cutoff = (now ?? DateTime.now()).subtract(olderThan);
    var changed = false;
    _operations.removeWhere((_, operation) {
      final completedAt = operation.completedAt;
      final remove =
          completedAt != null &&
          completedAt.isBefore(cutoff) &&
          !operation.isBusy;
      changed = changed || remove;
      return remove;
    });
    if (changed) _emit();
  }

  bool _isCurrent(UiOperationScope scope, int operationId) {
    return _operations[scope]?.operationId == operationId;
  }

  void _updateProgress(
    UiOperationScope scope,
    int operationId,
    double progress,
  ) {
    if (!_isCurrent(scope, operationId)) return;
    _operations[scope] = operationFor(
      scope,
    ).copyWith(progress: progress.clamp(0, 1).toDouble());
    _emit();
  }

  void _emit() {
    if (!_controller.isClosed) _controller.add(state);
  }

  Future<void> dispose() => _controller.close();
}
