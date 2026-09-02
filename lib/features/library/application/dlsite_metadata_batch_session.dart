import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/app_language.dart';
import '../../../core/media/dlsite_metadata.dart';
import '../domain/audio_library_category.dart';
import 'dlsite_metadata_query.dart';
import 'dlsite_metadata_service.dart';
import 'library_facade.dart';

enum DlsiteMetadataBatchLookupStatus {
  searching,
  found,
  confirmed,
  notFound,
  failed,
}

final class DlsiteMetadataBatchItem {
  const DlsiteMetadataBatchItem({
    required this.entry,
    required this.query,
    required this.status,
    this.candidates = const <DlsiteMetadata>[],
    this.confirmedMetadata,
    this.saveCover,
    this.error,
    this.isExcluded = false,
  });

  final AudioLibraryCategoryEntry entry;
  final DlsiteMetadataQuery query;
  final DlsiteMetadataBatchLookupStatus status;
  final List<DlsiteMetadata> candidates;
  final DlsiteMetadata? confirmedMetadata;
  final bool? saveCover;
  final Object? error;
  final bool isExcluded;

  bool get isReviewable =>
      !isExcluded &&
      (status == DlsiteMetadataBatchLookupStatus.found ||
          status == DlsiteMetadataBatchLookupStatus.confirmed);

  List<DlsiteMetadata> get reviewCandidates {
    final confirmedMetadata = this.confirmedMetadata;
    if (confirmedMetadata == null) return candidates;
    return List<DlsiteMetadata>.unmodifiable(<DlsiteMetadata>[
      confirmedMetadata,
      ...candidates.where((candidate) => candidate != confirmedMetadata),
    ]);
  }

  DlsiteMetadataBatchItem copyWith({
    DlsiteMetadataBatchLookupStatus? status,
    List<DlsiteMetadata>? candidates,
    Object? confirmedMetadata = _unset,
    Object? saveCover = _unset,
    Object? error,
    bool clearError = false,
    bool? isExcluded,
  }) => DlsiteMetadataBatchItem(
    entry: entry,
    query: query,
    status: status ?? this.status,
    candidates: candidates ?? this.candidates,
    confirmedMetadata: confirmedMetadata == _unset
        ? this.confirmedMetadata
        : confirmedMetadata as DlsiteMetadata?,
    saveCover: saveCover == _unset ? this.saveCover : saveCover as bool?,
    error: clearError ? null : (error ?? this.error),
    isExcluded: isExcluded ?? this.isExcluded,
  );
}

const Object _unset = Object();

typedef DlsiteMetadataBatchLookup =
    Future<List<DlsiteMetadata>> Function(DlsiteMetadataQuery query);
typedef DlsiteMetadataBatchApply =
    Future<void> Function(DlsiteMetadataBatchItem item);

final class DlsiteMetadataBatchApplyResult {
  const DlsiteMetadataBatchApplyResult({
    required this.savedCount,
    required this.skippedCount,
    required this.failedCount,
  });

  final int savedCount;
  final int skippedCount;
  final int failedCount;
}

final class DlsiteMetadataBatchSession extends ChangeNotifier {
  DlsiteMetadataBatchSession({
    required Iterable<AudioLibraryCategoryEntry> entries,
    required DlsiteMetadataBatchLookup lookup,
    DlsiteMetadataBatchApply? apply,
    this.maxConcurrentLookups = 3,
  }) : assert(maxConcurrentLookups > 0),
       _lookup = lookup,
       _apply = apply,
       _items = entries
           .map((entry) {
             final query = DlsiteMetadataQuery.fromDetail(entry.detail);
             return DlsiteMetadataBatchItem(
               entry: entry,
               query: query,
               status: query.hasQuery
                   ? DlsiteMetadataBatchLookupStatus.searching
                   : DlsiteMetadataBatchLookupStatus.notFound,
             );
           })
           .toList(growable: false);

  factory DlsiteMetadataBatchSession.forLibrary({
    required Iterable<AudioLibraryCategoryEntry> entries,
    required LibraryFacade library,
    required AppLanguage language,
  }) => DlsiteMetadataBatchSession(
    entries: entries,
    lookup: (query) {
      final rjCode = query.rjCode;
      return rjCode == null
          ? library.searchPreferredMetadataByTitles(
              query.searchTitles,
              language: language,
            )
          : library
                .fetchPreferredMetadata(rjCode, language: language)
                .then((metadata) => <DlsiteMetadata>[metadata]);
    },
    apply: (item) async {
      final metadata = item.confirmedMetadata;
      if (metadata == null) return;
      await library.applyDlsiteMetadata(
        item.entry.detail,
        metadata,
        saveCover: item.saveCover ?? false,
        language: language,
      );
    },
  );

  final DlsiteMetadataBatchLookup _lookup;
  final DlsiteMetadataBatchApply? _apply;
  final int maxConcurrentLookups;
  final List<DlsiteMetadataBatchItem> _items;
  final Queue<int> _pending = Queue<int>();
  final Set<int> _queued = <int>{};
  final Set<int> _active = <int>{};
  bool _started = false;
  bool _disposed = false;

  List<DlsiteMetadataBatchItem> get items =>
      List<DlsiteMetadataBatchItem>.unmodifiable(_items);

  int get confirmedCount => _items
      .where(
        (item) =>
            !item.isExcluded &&
            item.status == DlsiteMetadataBatchLookupStatus.confirmed,
      )
      .length;

  bool get hasPendingLookups => _items.any(
    (item) =>
        !item.isExcluded &&
        item.status == DlsiteMetadataBatchLookupStatus.searching,
  );

  void start() {
    if (_started) return;
    _started = true;
    for (var index = 0; index < _items.length; index += 1) {
      if (!_items[index].isExcluded &&
          _items[index].status == DlsiteMetadataBatchLookupStatus.searching) {
        _enqueue(index);
      }
    }
    _pump();
  }

  void toggleExcluded(int index) {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    final nextExcluded = !item.isExcluded;
    _items[index] = item.copyWith(isExcluded: nextExcluded);
    if (nextExcluded) {
      _pending.remove(index);
      _queued.remove(index);
    } else if (item.status == DlsiteMetadataBatchLookupStatus.searching &&
        !_active.contains(index)) {
      _enqueue(index);
      _pump();
    }
    _notify();
  }

  void retry(int index) {
    if (index < 0 ||
        index >= _items.length ||
        _active.contains(index) ||
        _items[index].isExcluded) {
      return;
    }
    final item = _items[index];
    if (!item.query.hasQuery) return;
    _items[index] = item.copyWith(
      status: DlsiteMetadataBatchLookupStatus.searching,
      candidates: const <DlsiteMetadata>[],
      clearError: true,
    );
    _enqueue(index);
    _notify();
    _pump();
  }

  void confirm(
    int index, {
    required DlsiteMetadata metadata,
    required bool saveCover,
  }) {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    if (item.isExcluded || !item.isReviewable) return;
    _items[index] = item.copyWith(
      status: DlsiteMetadataBatchLookupStatus.confirmed,
      confirmedMetadata: metadata,
      saveCover: saveCover,
    );
    _notify();
  }

  int? reviewableIndexFrom(int currentIndex, int direction) {
    for (
      var index = currentIndex + direction;
      index >= 0 && index < _items.length;
      index += direction
    ) {
      if (!_items[index].isExcluded && _items[index].isReviewable) {
        return index;
      }
    }
    return null;
  }

  Future<DlsiteMetadataBatchApplyResult> applyConfirmed() async {
    final apply = _apply;
    if (apply == null) {
      throw StateError('This batch session cannot save metadata.');
    }
    if (hasPendingLookups) {
      throw StateError('Cannot save metadata while lookups are pending.');
    }
    var savedCount = 0;
    final skippedCount = _items
        .where(
          (item) =>
              item.isExcluded ||
              item.status == DlsiteMetadataBatchLookupStatus.notFound ||
              item.status == DlsiteMetadataBatchLookupStatus.found,
        )
        .length;
    var failedCount = _items
        .where(
          (item) =>
              !item.isExcluded &&
              item.status == DlsiteMetadataBatchLookupStatus.failed,
        )
        .length;
    for (final item in _items.where(
      (item) =>
          !item.isExcluded &&
          item.status == DlsiteMetadataBatchLookupStatus.confirmed,
    )) {
      try {
        await apply(item);
        savedCount += 1;
      } catch (_) {
        failedCount += 1;
      }
    }
    return DlsiteMetadataBatchApplyResult(
      savedCount: savedCount,
      skippedCount: skippedCount,
      failedCount: failedCount,
    );
  }

  void _enqueue(int index) {
    if (_queued.add(index)) _pending.add(index);
  }

  void _pump() {
    while (!_disposed &&
        _active.length < maxConcurrentLookups &&
        _pending.isNotEmpty) {
      final index = _pending.removeFirst();
      _queued.remove(index);
      _active.add(index);
      unawaited(_runLookup(index));
    }
  }

  Future<void> _runLookup(int index) async {
    final item = _items[index];
    if (item.isExcluded) {
      _active.remove(index);
      _notify();
      _pump();
      return;
    }
    try {
      final candidates = await _lookup(item.query);
      if (_disposed) return;
      final currentItem = _items[index];
      _items[index] = currentItem.copyWith(
        status: candidates.isEmpty
            ? DlsiteMetadataBatchLookupStatus.notFound
            : DlsiteMetadataBatchLookupStatus.found,
        candidates: List<DlsiteMetadata>.unmodifiable(candidates),
        clearError: true,
      );
    } on DlsiteMetadataException catch (error) {
      if (_disposed) return;
      final currentItem = _items[index];
      _items[index] = currentItem.copyWith(
        status: error.isNotFound
            ? DlsiteMetadataBatchLookupStatus.notFound
            : DlsiteMetadataBatchLookupStatus.failed,
        candidates: const <DlsiteMetadata>[],
        error: error,
      );
    } catch (error) {
      if (_disposed) return;
      final currentItem = _items[index];
      _items[index] = currentItem.copyWith(
        status: DlsiteMetadataBatchLookupStatus.failed,
        candidates: const <DlsiteMetadata>[],
        error: error,
      );
    } finally {
      _active.remove(index);
      _notify();
      _pump();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
