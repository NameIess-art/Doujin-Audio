part of 'asmr_remote_catalog_service.dart';

/// One cursor per category/query snapshot. Failed or cancelled requests never
/// advance another source's offset or discard its unconsumed results.
class AsmrCatalogCursor {
  Map<AsmrCatalogSource, int> _pages = {
    for (final source in AsmrCatalogSource.values) source: 1,
  };
  Map<AsmrCatalogSource, bool> _more = {
    for (final source in AsmrCatalogSource.values) source: true,
  };
  Map<AsmrCatalogSource, List<AsmrWork>> _pending = {
    for (final source in AsmrCatalogSource.values) source: [],
  };
  Map<String, AsmrWork> _emitted = {};
  Map<AsmrCatalogSource, int> _totals = {};

  AsmrCatalogCursor _copy() => AsmrCatalogCursor()
    .._pages = Map.of(_pages)
    .._more = Map.of(_more)
    .._totals = Map.of(_totals)
    .._pending = {
      for (final entry in _pending.entries) entry.key: List.of(entry.value),
    }
    .._emitted = Map.of(_emitted);

  void _commit(AsmrCatalogCursor next) {
    _pages = next._pages;
    _more = next._more;
    _totals = next._totals;
    _pending = next._pending;
    _emitted = next._emitted;
  }
}

class AsmrPartialCatalogException implements Exception {
  AsmrPartialCatalogException(Iterable<AsmrCatalogSource> sources)
    : sources = List.unmodifiable(sources);
  final List<AsmrCatalogSource> sources;
}

class AsmrMergedWorkPage extends AsmrWorkPage {
  AsmrMergedWorkPage({
    required super.works,
    required super.currentPage,
    required super.pageSize,
    required bool hasMore,
    this.sourceTotalCount,
    this.partialError,
    List<AsmrWork> resourceUpdates = const [],
  }) : _hasMore = hasMore,
       resourceUpdates = List.unmodifiable(resourceUpdates),
       super(totalCount: sourceTotalCount ?? works.length);

  final bool _hasMore;
  // Source totals include overlapping works; pagination uses source cursors.
  final int? sourceTotalCount;
  final AsmrPartialCatalogException? partialError;
  final List<AsmrWork> resourceUpdates;
  @override
  bool get hasMore => _hasMore;
}

extension on AsmrRemoteCatalogService {
  Future<AsmrWorkPage> _loadMergedPage(
    AsmrCategoryType category, {
    required String searchQuery,
    required int page,
    required AsmrContentLanguage language,
    required String? token,
    AsmrRequestCancellationToken? cancellationToken,
    AsmrCatalogCursor? cursor,
  }) async {
    final next = (cursor ?? AsmrCatalogCursor())._copy();
    // Recommendation exploration can request an arbitrary remote page; visible
    // lists always retain their independent source cursors between requests.
    if (cursor == null && page > 1) {
      for (final source in AsmrCatalogSource.values) {
        next._pages[source] = page;
      }
    }
    final pageSize = AsmrRemoteCatalogService._pageSizes[category] ?? 40;
    final failures = <AsmrCatalogSource, Object>{};
    final updates = <String, AsmrWork>{};
    var successfulSources = 0;
    await Future.wait(
      AsmrCatalogSource.values.map((source) async {
        if (next._pending[source]!.length >= pageSize || !next._more[source]!) {
          successfulSources++;
          return;
        }
        try {
          // A page can contain only works already emitted by the other source.
          // Continue its cursor here so deduplication does not become a manual
          // retry action at every overlapping page.
          var duplicatePages = 0;
          do {
            final sourcePage = next._pages[source]!;
            final loaded = source == AsmrCatalogSource.asmrOne
                ? await _loadOnePage(
                    category,
                    searchQuery: searchQuery,
                    page: sourcePage,
                    language: language,
                    token: token,
                    cancellationToken: cancellationToken,
                  )
                : await _retryTransientLoad(
                    category: category,
                    page: sourcePage,
                    cancellationToken: cancellationToken,
                    load: () => _japaneseApiService!.searchWorks(
                      keyword: searchQuery,
                      page: sourcePage,
                      pageSize: pageSize,
                      cancellationToken: cancellationToken,
                    ),
                  );
            cancellationToken?.throwIfCancelled();
            successfulSources++;
            next._pages[source] = sourcePage + 1;
            next._more[source] = loaded.hasMore;
            next._totals[source] = loaded.totalCount;
            for (final work in loaded.works) {
              final previous = next._emitted[work.workKey];
              if (previous != null) {
                final merged = previous.mergedWith(work);
                next._emitted[work.workKey] = merged;
                updates[work.workKey] = merged;
              } else {
                next._pending[source]!.add(work);
              }
            }
            duplicatePages++;
          } while (next._pending[source]!
                      .map((work) => work.workKey)
                      .toSet()
                      .length <
                  pageSize &&
              next._more[source]! &&
              duplicatePages < 4);
        } on AsmrRequestCancelled {
          rethrow;
        } catch (error, stack) {
          failures[source] = error;
          AppLogService.warning(
            'online_catalog_source_failed source=${source.name}',
            error: error,
            stackTrace: stack,
          );
        }
      }),
    );
    cancellationToken?.throwIfCancelled();
    if (successfulSources == 0) throw failures.values.first;
    final available = <String, AsmrWork>{};
    for (final works in next._pending.values) {
      for (final work in works) {
        available.update(
          work.workKey,
          (old) => old.mergedWith(work),
          ifAbsent: () => work,
        );
      }
    }
    final sorted = available.values.toList()
      ..sort((a, b) {
        final aDate = category == AsmrCategoryType.collected
            ? a.createDate
            : a.releaseDate;
        final bDate = category == AsmrCategoryType.collected
            ? b.createDate
            : b.releaseDate;
        if (aDate == null && bDate != null) return 1;
        if (bDate == null && aDate != null) return -1;
        final order = aDate == null ? 0 : bDate!.compareTo(aDate);
        return order != 0 ? order : a.workKey.compareTo(b.workKey);
      });
    final selected = sorted.take(pageSize).toList(growable: false);
    for (final work in selected) {
      next._emitted[work.workKey] = work;
    }
    for (final pending in next._pending.values) {
      pending.removeWhere((work) => next._emitted.containsKey(work.workKey));
    }
    final hasMore =
        next._more.values.any((value) => value) ||
        next._pending.values.any((works) => works.isNotEmpty);
    cancellationToken?.throwIfCancelled();
    cursor?._commit(next);
    return AsmrMergedWorkPage(
      works: selected,
      currentPage: page,
      pageSize: pageSize,
      hasMore: hasMore,
      sourceTotalCount: next._totals.length == AsmrCatalogSource.values.length
          ? next._totals.values.fold<int>(0, (sum, count) => sum + count)
          : null,
      resourceUpdates: updates.values.toList(growable: false),
      partialError: failures.isEmpty
          ? null
          : AsmrPartialCatalogException(failures.keys),
    );
  }
}
