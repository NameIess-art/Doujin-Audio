import 'package:flutter/foundation.dart';

import '../../../core/immutable_collections.dart';
import '../../../core/app_language.dart';
import '../domain/asmr_models.dart';

class AsmrLibraryGlobalViewState {
  AsmrLibraryGlobalViewState({
    required this.initialized,
    required List<AsmrCategoryType> visibleCategories,
    required this.contentLanguage,
    required this.contentLanguagePreference,
    required this.revision,
  }) : visibleCategories = immutableList(visibleCategories);

  final bool initialized;
  final List<AsmrCategoryType> visibleCategories;
  final AsmrContentLanguage contentLanguage;
  final ContentLanguagePreference contentLanguagePreference;
  final int revision;

  @override
  bool operator ==(Object other) {
    return other is AsmrLibraryGlobalViewState &&
        initialized == other.initialized &&
        listEquals(visibleCategories, other.visibleCategories) &&
        contentLanguage == other.contentLanguage &&
        contentLanguagePreference == other.contentLanguagePreference &&
        revision == other.revision;
  }

  @override
  int get hashCode => Object.hash(
    initialized,
    Object.hashAll(visibleCategories),
    contentLanguage,
    contentLanguagePreference,
    revision,
  );
}

class AsmrCategoryViewState {
  AsmrCategoryViewState({
    required this.category,
    required List<AsmrWork> works,
    required this.isLoading,
    required this.isLoadingMore,
    required this.isRefreshing,
    required this.isStale,
    required this.hasAttemptedLoad,
    required this.hasMore,
    required this.needsLoadMoreRetry,
    required this.totalCount,
    required this.activeQuery,
    required this.lastError,
    required this.operationError,
    required this.revision,
    this.hasUpdates = false,
  }) : works = immutableList(works);

  final AsmrCategoryType category;
  final List<AsmrWork> works;
  final bool isLoading;
  final bool isLoadingMore;
  final bool isRefreshing;
  final bool isStale;
  final bool hasAttemptedLoad;
  final bool hasMore;
  final bool needsLoadMoreRetry;
  final int totalCount;
  final String activeQuery;
  final Object? lastError;
  final Object? operationError;
  final int revision;
  final bool hasUpdates;

  @override
  bool operator ==(Object other) {
    return other is AsmrCategoryViewState &&
        category == other.category &&
        identical(works, other.works) &&
        isLoading == other.isLoading &&
        isLoadingMore == other.isLoadingMore &&
        isRefreshing == other.isRefreshing &&
        isStale == other.isStale &&
        hasAttemptedLoad == other.hasAttemptedLoad &&
        hasMore == other.hasMore &&
        needsLoadMoreRetry == other.needsLoadMoreRetry &&
        totalCount == other.totalCount &&
        activeQuery == other.activeQuery &&
        lastError == other.lastError &&
        operationError == other.operationError &&
        revision == other.revision &&
        hasUpdates == other.hasUpdates;
  }

  @override
  int get hashCode => Object.hash(
    category,
    identityHashCode(works),
    isLoading,
    isLoadingMore,
    isRefreshing,
    isStale,
    hasAttemptedLoad,
    hasMore,
    needsLoadMoreRetry,
    totalCount,
    activeQuery,
    lastError,
    operationError,
    revision,
    hasUpdates,
  );
}

class AsmrTrackTreeViewState {
  AsmrTrackTreeViewState({
    required this.workId,
    required List<AsmrTrackFile>? tree,
    required List<AsmrTrackFile>? visibleTree,
    required this.isLoading,
    required this.isRefreshing,
    required this.isStale,
    required this.operationError,
    required this.revision,
  }) : tree = tree == null ? null : immutableList(tree),
       visibleTree = visibleTree == null ? null : immutableList(visibleTree);

  final int workId;
  final List<AsmrTrackFile>? tree;
  final List<AsmrTrackFile>? visibleTree;
  final bool isLoading;
  final bool isRefreshing;
  final bool isStale;
  final Object? operationError;
  final int revision;

  @override
  bool operator ==(Object other) {
    return other is AsmrTrackTreeViewState &&
        workId == other.workId &&
        identical(tree, other.tree) &&
        identical(visibleTree, other.visibleTree) &&
        isLoading == other.isLoading &&
        isRefreshing == other.isRefreshing &&
        isStale == other.isStale &&
        operationError == other.operationError &&
        revision == other.revision;
  }

  @override
  int get hashCode => Object.hash(
    workId,
    identityHashCode(tree),
    identityHashCode(visibleTree),
    isLoading,
    isRefreshing,
    isStale,
    operationError,
    revision,
  );
}

class AsmrAuthViewState {
  const AsmrAuthViewState({
    required this.isLoggedIn,
    required this.isRestoring,
    required this.userName,
    required this.revision,
  });

  final bool isLoggedIn;
  final bool isRestoring;
  final String userName;
  final int revision;
}

class AsmrSyncViewState {
  const AsmrSyncViewState({
    required this.phase,
    required this.lastSyncAt,
    required this.pendingCount,
    required this.lastError,
    required this.revision,
  });

  final AsmrSyncPhase phase;
  final DateTime? lastSyncAt;
  final int pendingCount;
  final Object? lastError;
  final int revision;
}
