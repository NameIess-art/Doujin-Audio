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
  UiOperationService({this.maxRetainedCompletedOperations = 64})
    : assert(maxRetainedCompletedOperations >= 0);

  static final UiOperationService instance = UiOperationService();

  final int maxRetainedCompletedOperations;
  final StreamController<UiOperationScope> _controller =
      StreamController<UiOperationScope>.broadcast();
  final Map<UiOperationScope, UiOperationState> _operations =
      <UiOperationScope, UiOperationState>{};
  int _nextOperationId = 0;

  Stream<UiOperationScope> get changes => _controller.stream;

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
    _emit(scope);

    try {
      final value = await task(UiOperationProgress._(this, scope, operationId));
      if (_isCurrent(scope, operationId)) {
        _operations[scope] = operationFor(scope).copyWith(
          phase: UiOperationPhase.succeeded,
          progress: 1,
          clearError: true,
          completedAt: DateTime.now(),
        );
        final evictedScopes = _trimCompletedOperations();
        _emit(scope);
        _emitAll(evictedScopes);
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
        final evictedScopes = _trimCompletedOperations();
        _emit(scope);
        _emitAll(evictedScopes);
        await onError?.call(error, stackTrace);
      }
      rethrow;
    }
  }

  void clear(UiOperationScope scope) {
    if (_operations.remove(scope) != null) _emit(scope);
  }

  void clearCompleted({
    Duration olderThan = const Duration(seconds: 2),
    DateTime? now,
  }) {
    final cutoff = (now ?? DateTime.now()).subtract(olderThan);
    final removedScopes = <UiOperationScope>[];
    _operations.removeWhere((_, operation) {
      final completedAt = operation.completedAt;
      final remove =
          completedAt != null &&
          completedAt.isBefore(cutoff) &&
          !operation.isBusy;
      if (remove) removedScopes.add(operation.scope);
      return remove;
    });
    _emitAll(removedScopes);
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
    _emit(scope);
  }

  List<UiOperationScope> _trimCompletedOperations() {
    final completed = _operations.values
        .where((operation) => !operation.isBusy)
        .toList(growable: false);
    final overflow = completed.length - maxRetainedCompletedOperations;
    if (overflow <= 0) return const <UiOperationScope>[];
    completed.sort((a, b) {
      final completedComparison = (a.completedAt ?? a.startedAt).compareTo(
        b.completedAt ?? b.startedAt,
      );
      if (completedComparison != 0) return completedComparison;
      return a.operationId.compareTo(b.operationId);
    });
    final removedScopes = <UiOperationScope>[];
    for (final operation in completed.take(overflow)) {
      if (_operations.remove(operation.scope) != null) {
        removedScopes.add(operation.scope);
      }
    }
    return removedScopes;
  }

  void _emit(UiOperationScope scope) {
    if (!_controller.isClosed) _controller.add(scope);
  }

  void _emitAll(Iterable<UiOperationScope> scopes) {
    for (final scope in scopes) {
      _emit(scope);
    }
  }

  Future<void> dispose() => _controller.close();
}
