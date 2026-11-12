part of 'asmr_remote_catalog_service.dart';

typedef _CatalogStream = (AsmrCatalogSource, String);

/// One cursor per category/query snapshot. Failed or cancelled requests never
/// advance another source's offset or discard its unconsumed results.
class AsmrCatalogCursor {
  // Recommendation categories keep separate offsets, but share identical source
  // requests only within their refresh; cancellation cannot affect later loads.
  Map<(String, int, int), Future<AsmrWorkPage>>? _japanesePages;
  Map<_CatalogStream, int> _pages = {};
  Map<_CatalogStream, bool> _more = {};
  Map<_CatalogStream, List<AsmrWork>> _pending = {};
  Map<String, AsmrWork> _emitted = {};
  Map<_CatalogStream, int> _totals = {};

  // The category publishes this snapshot together with the prepared rows.
  AsmrCatalogCursor copy() => _copyProgress().._emitted = Map.of(_emitted);

  AsmrCatalogCursor _copyProgress() => AsmrCatalogCursor()
    .._japanesePages = _japanesePages
    .._pages = Map.of(_pages)
    .._more = Map.of(_more)
    .._totals = Map.of(_totals)
    .._pending = {
      for (final entry in _pending.entries) entry.key: List.of(entry.value),
    };

  void _commit(AsmrCatalogCursor next, Iterable<AsmrWork> emitted) {
    _pages = next._pages;
    _more = next._more;
    _totals = next._totals;
    _pending = next._pending;
    for (final work in emitted) {
      _emitted[work.workKey] = work;
    }
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
    required List<String> queries,
    required int page,
    required AsmrContentLanguage language,
    required String? token,
    AsmrRequestCancellationToken? cancellationToken,
    AsmrCatalogCursor? cursor,
  }) async {
    final next = cursor?._copyProgress() ?? AsmrCatalogCursor();
    final emitted = cursor?._emitted ?? const <String, AsmrWork>{};
    final streams = [
      for (final query in queries) ...[
        (AsmrCatalogSource.asmrOne, query),
        if (_usesJapaneseCatalog(category))
          (AsmrCatalogSource.japaneseAsmr, query),
      ],
    ];
    for (final stream in streams) {
      next._pages.putIfAbsent(stream, () => cursor == null ? page : 1);
      next._more.putIfAbsent(stream, () => true);
      next._pending.putIfAbsent(stream, () => []);
    }
    final pageSize = AsmrRemoteCatalogService._pageSizes[category] ?? 40;
    final failures = <AsmrCatalogSource, Object>{};
    final updates = <String, AsmrWork>{};
    var successfulSources = 0;
    Future<void> loadStream(_CatalogStream stream) async {
      final (source, searchQuery) = stream;
      if (next._pending[stream]!.length >= pageSize || !next._more[stream]!) {
        successfulSources++;
        return;
      }
      try {
        // A page can contain only works already emitted by the other source.
        // Continue its cursor here so deduplication does not become a manual
        // retry action at every overlapping page.
        var duplicatePages = 0;
        do {
          final sourcePage = next._pages[stream]!;
          final query = searchElementKeyword(searchQuery);
          Future<AsmrWorkPage> loadJapanese() => _retryTransientLoad(
            category: category,
            page: sourcePage,
            cancellationToken: cancellationToken,
            load: () => _japaneseApiService!.searchWorks(
              keyword: query,
              page: sourcePage,
              pageSize: pageSize,
              cancellationToken: cancellationToken,
            ),
          );
          final loaded = source == AsmrCatalogSource.asmrOne
              ? await _loadOnePage(
                  category,
                  searchQuery: searchQuery,
                  page: sourcePage,
                  language: language,
                  token: token,
                  cancellationToken: cancellationToken,
                )
              : await (next._japanesePages?.putIfAbsent((
                      query,
                      sourcePage,
                      pageSize,
                    ), loadJapanese) ??
                    loadJapanese());
          cancellationToken?.throwIfCancelled();
          successfulSources++;
          next._pages[stream] = sourcePage + 1;
          next._more[stream] = loaded.hasMore;
          next._totals[stream] = loaded.totalCount;
          for (final work in loaded.works) {
            final previous = updates[work.workKey] ?? emitted[work.workKey];
            if (previous != null) {
              final merged = previous.mergedWith(work);
              updates[work.workKey] = merged;
            } else {
              next._pending[stream]!.add(work);
            }
          }
          duplicatePages++;
        } while (next._pending[stream]!
                    .map((work) => work.workKey)
                    .toSet()
                    .length <
                pageSize &&
            next._more[stream]! &&
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
    }

    for (var start = 0; start < streams.length; start += 4) {
      cancellationToken?.throwIfCancelled();
      await Future.wait(streams.skip(start).take(4).map(loadStream));
    }
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
        final numericOrder = switch (category) {
          AsmrCategoryType.sales => b.dlCount.compareTo(a.dlCount),
          AsmrCategoryType.rating => b.rating.compareTo(a.rating),
          AsmrCategoryType.reviews => b.reviewCount.compareTo(a.reviewCount),
          _ => null,
        };
        if (numericOrder != null) {
          return numericOrder != 0
              ? numericOrder
              : a.workKey.compareTo(b.workKey);
        }
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
    final selectedIds = {for (final work in selected) work.workKey};
    for (final pending in next._pending.values) {
      pending.removeWhere(
        (work) =>
            emitted.containsKey(work.workKey) ||
            selectedIds.contains(work.workKey),
      );
    }
    final hasMore =
        next._more.values.any((value) => value) ||
        next._pending.values.any((works) => works.isNotEmpty);
    cancellationToken?.throwIfCancelled();
    cursor?._commit(next, updates.values.followedBy(selected));
    return AsmrMergedWorkPage(
      works: selected,
      currentPage: page,
      pageSize: pageSize,
      hasMore: hasMore,
      sourceTotalCount:
          queries.length == 1 && next._totals.length == streams.length
          ? next._totals.values.fold<int>(0, (sum, count) => sum + count)
          : null,
      resourceUpdates: updates.values.toList(growable: false),
      partialError: failures.isEmpty
          ? null
          : AsmrPartialCatalogException(failures.keys),
    );
  }
}
