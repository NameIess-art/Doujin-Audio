import 'dart:async';

import '../../core/logging/app_log_service.dart';
import '../../core/media/audio_detail.dart';
import '../../features/asmr/application/asmr_library_controller.dart';
import '../../features/asmr/domain/asmr_models.dart';
import '../../features/library/application/audio_detail_cache_service.dart';
import '../../features/library/application/library_facade.dart';
import 'runtime_binding.dart';

/// Bidirectionally reconciles personal work reviews (status, rating, note)
/// between local [AudioDetail] records (`doujin-audio.json` + SQLite) and
/// [AsmrLibraryController] by normalized RJ code.
final class WorkReviewSyncRuntimeBinding implements RuntimeBinding {
  WorkReviewSyncRuntimeBinding({
    required LibraryFacade library,
    required AsmrLibraryController asmrLibrary,
  }) : _library = library,
       _asmrLibrary = asmrLibrary {
    _lastReviewedWorks = _asmrLibrary.reviewedWorks;
    _lastLibraryStructureRevision = _library.structureRevision;
    _asmrLibrary.addListener(_handleAsmrChanged);
    _detailSubscription = _library.detailCacheService.changes.listen(
      _handleLocalDetailChanged,
    );
    _librarySliceSubscription = _library.states.listen((_) {
      final nextStructure = _library.structureRevision;
      if (nextStructure == _lastLibraryStructureRevision) return;
      _lastLibraryStructureRevision = nextStructure;
      _scheduleFullReconcile();
    });
    if (_asmrLibrary.initialized && _library.library.isNotEmpty) {
      _scheduleFullReconcile();
    }
  }

  final LibraryFacade _library;
  final AsmrLibraryController _asmrLibrary;
  late final StreamSubscription<AudioDetailCacheChange> _detailSubscription;
  late final StreamSubscription<Object?> _librarySliceSubscription;

  List<AsmrWork> _lastReviewedWorks = const <AsmrWork>[];
  int _lastLibraryStructureRevision = -1;
  final Set<String> _applyingLocalTargetKeys = <String>{};
  final Set<String> _applyingAsmrRjCodes = <String>{};
  Future<void> _reconcileTail = Future<void>.value();
  bool _reconcileScheduled = false;
  bool _disposed = false;

  void _handleAsmrChanged() {
    if (_disposed || !_asmrLibrary.initialized) return;
    final current = _asmrLibrary.reviewedWorks;
    if (identical(current, _lastReviewedWorks)) return;
    _lastReviewedWorks = current;
    if (_applyingAsmrRjCodes.isNotEmpty) return;
    _scheduleFullReconcile();
  }

  void _handleLocalDetailChanged(AudioDetailCacheChange change) {
    if (_disposed) return;
    final keys = change.targetKeys;
    if (keys == null) {
      _scheduleFullReconcile();
      return;
    }
    final externalKeys = keys
        .where((key) => !_applyingLocalTargetKeys.contains(key))
        .toList(growable: false);
    if (externalKeys.isEmpty) return;
    _enqueue(() => _pushLocalTargetsToAsmr(externalKeys));
  }

  void _scheduleFullReconcile() {
    if (_disposed || _reconcileScheduled) return;
    _reconcileScheduled = true;
    _enqueue(() async {
      _reconcileScheduled = false;
      await _reconcileAll();
    });
  }

  void _enqueue(Future<void> Function() action) {
    _reconcileTail = _reconcileTail.then((_) async {
      if (_disposed) return;
      try {
        await action();
      } catch (error, stackTrace) {
        AppLogService.warning(
          'work_review_sync_binding_failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    });
  }

  Future<void> _pushLocalTargetsToAsmr(List<String> targetKeys) async {
    await _asmrLibrary.initializeForVisiblePage();
    if (_disposed) return;
    for (final key in targetKeys) {
      if (_disposed) return;
      final detail = _library.detailCacheService.resolvedDetailByKey(key);
      if (detail == null) continue;
      final rjCode = _extractRjCode(detail.rjCode);
      if (rjCode == null) continue;
      await _syncSinglePair(
        rjCode: rjCode,
        localTarget: detail.target,
        localDetail: detail,
        preferExplicitLocalClear: true,
      );
    }
  }

  Future<void> _reconcileAll() async {
    if (!_asmrLibrary.initialized || _library.library.isEmpty) return;
    final snapshot = await _library.audioLibraryCategorySnapshot(
      isActive: () => !_disposed,
    );
    if (_disposed) return;
    for (final entry in snapshot.entries) {
      if (_disposed) return;
      final rjCode =
          _extractRjCode(entry.detail.rjCode) ?? _extractRjCode(entry.title);
      if (rjCode == null) continue;
      await _syncSinglePair(
        rjCode: rjCode,
        localTarget: entry.target,
        localDetail: entry.detail,
        fallbackTitle: entry.title,
        preferExplicitLocalClear: false,
      );
    }
  }

  Future<void> _syncSinglePair({
    required String rjCode,
    required AudioDetailTarget localTarget,
    required AudioDetail localDetail,
    String fallbackTitle = '',
    required bool preferExplicitLocalClear,
  }) async {
    final asmrWork = _asmrLibrary.reviewForRjCode(rjCode);
    final clearedAt = _asmrLibrary.clearedReviewUpdatedAtForRjCode(rjCode);
    final localHasReview = localDetail.hasUserReview;
    final localTime = localDetail.reviewUpdatedAt;

    if (asmrWork == null) {
      if (!localHasReview) return;
      if (clearedAt != null &&
          (localTime == null || !localTime.isAfter(clearedAt))) {
        await _applyReviewToLocal(
          localTarget,
          listenStatus: null,
          userRating: null,
          reviewText: '',
          updatedAt: clearedAt,
        );
        return;
      }
      await _applyReviewToAsmr(
        _buildAsmrWorkFromLocal(rjCode, localDetail, fallbackTitle),
        listenStatus: localDetail.listenStatus,
        userRating: localDetail.userRating,
        reviewText: localDetail.reviewText,
        updatedAt: localTime,
      );
      return;
    }

    if (_sameReview(localDetail, asmrWork)) return;

    final asmrTime = asmrWork.reviewUpdatedAt;
    if (!localHasReview) {
      if (preferExplicitLocalClear &&
          localTime != null &&
          (asmrTime == null || !localTime.isBefore(asmrTime))) {
        await _applyReviewToAsmr(
          asmrWork,
          listenStatus: null,
          userRating: null,
          reviewText: '',
          updatedAt: localTime,
        );
        return;
      }
      if (localTime == null ||
          (asmrTime != null && !asmrTime.isBefore(localTime))) {
        await _applyReviewToLocal(
          localTarget,
          listenStatus: asmrWork.listenStatus,
          userRating: asmrWork.userRating,
          reviewText: asmrWork.reviewText,
          updatedAt: asmrTime,
        );
      }
      return;
    }

    final localIsNewer =
        localTime != null && (asmrTime == null || localTime.isAfter(asmrTime));
    if (localIsNewer) {
      await _applyReviewToAsmr(
        asmrWork,
        listenStatus: localDetail.listenStatus,
        userRating: localDetail.userRating,
        reviewText: localDetail.reviewText,
        updatedAt: localTime,
      );
    } else {
      await _applyReviewToLocal(
        localTarget,
        listenStatus: asmrWork.listenStatus,
        userRating: asmrWork.userRating,
        reviewText: asmrWork.reviewText,
        updatedAt: asmrTime,
      );
    }
  }

  Future<void> _applyReviewToLocal(
    AudioDetailTarget target, {
    required WorkListenStatus? listenStatus,
    required int? userRating,
    required String reviewText,
    required DateTime? updatedAt,
  }) async {
    final key = AudioLibraryDetailKey.forTarget(target);
    _applyingLocalTargetKeys.add(key);
    try {
      await _library.saveAudioUserReview(
        target,
        listenStatus: listenStatus,
        userRating: userRating,
        reviewText: reviewText,
        updatedAt: updatedAt,
      );
    } catch (error, stackTrace) {
      AppLogService.warning(
        'work_review_apply_local_failed',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _applyingLocalTargetKeys.remove(key);
    }
  }

  Future<void> _applyReviewToAsmr(
    AsmrWork work, {
    required WorkListenStatus? listenStatus,
    required int? userRating,
    required String reviewText,
    required DateTime? updatedAt,
  }) async {
    final rjCode = work.rjCode;
    if (rjCode.isNotEmpty) _applyingAsmrRjCodes.add(rjCode);
    try {
      await _asmrLibrary.saveWorkReview(
        work,
        listenStatus: listenStatus,
        userRating: userRating,
        reviewText: reviewText,
        updatedAt: updatedAt,
      );
      _lastReviewedWorks = _asmrLibrary.reviewedWorks;
    } finally {
      if (rjCode.isNotEmpty) _applyingAsmrRjCodes.remove(rjCode);
    }
  }

  static bool _sameReview(AudioDetail local, AsmrWork remote) {
    return local.listenStatus == remote.listenStatus &&
        local.userRating == remote.userRating &&
        AudioDetail.normalizeReviewText(local.reviewText) ==
            AudioDetail.normalizeReviewText(remote.reviewText);
  }

  static String? _extractRjCode(String value) {
    final found = AudioDetail.findRjCodeInText(value);
    if (found == null || found.isEmpty) return null;
    final normalized = normalizeAsmrWorkCode(found);
    return normalized.startsWith('RJ') ? normalized : null;
  }

  static AsmrWork _buildAsmrWorkFromLocal(
    String rjCode,
    AudioDetail detail,
    String fallbackTitle,
  ) {
    final digits = int.tryParse(rjCode.substring(2)) ?? 0;
    final title = detail.workTitle.trim().isNotEmpty
        ? detail.workTitle.trim()
        : (fallbackTitle.trim().isNotEmpty ? fallbackTitle.trim() : rjCode);
    return AsmrWork(
      id: digits,
      title: title,
      circleName: detail.circleName,
      sourceId: rjCode,
      sourceType: 'DLSITE',
      sourceUrl: '',
      coverUrl: '',
      thumbnailUrl: '',
      mainCoverUrl: '',
      releaseDate: detail.releaseDate,
      createDate: null,
      duration: detail.duration ?? Duration.zero,
      dlCount: detail.salesCount ?? 0,
      reviewCount: 0,
      rating: detail.rating ?? 0,
      voiceActors: detail.voiceActors,
      tags: detail.tags,
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _asmrLibrary.removeListener(_handleAsmrChanged);
    await _detailSubscription.cancel();
    await _librarySliceSubscription.cancel();
  }
}
