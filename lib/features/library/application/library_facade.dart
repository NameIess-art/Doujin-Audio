import 'dart:collection';

import '../../../core/media/audio_detail.dart';
import '../../../core/media/music_track.dart';
import '../../../core/persistence/audio_database_repository.dart';
import '../../asmr/application/asmr_metadata_service.dart';
import '../../player/application/audio_state_services.dart';
import 'audio_detail_cache_service.dart';
import 'audio_detail_repository.dart';
import 'cover_artwork_cache_service.dart';
import 'dlsite_metadata_service.dart';
import 'library_snapshot_cache_service.dart';
import 'library_catalog.dart';
import '../domain/audio_library_category.dart';
import '../domain/library_node.dart';
import '../domain/library_entry.dart';

/// Owns the library-side services used by the compatibility audio facade.
///
/// Mutable library state remains owned exclusively by [LibraryService].
final class LibraryFacade {
  LibraryFacade({
    required this.databaseRepository,
    required this.detailCacheService,
    required this.metadataService,
    required this.asmrMetadataService,
    required this.service,
    required this.snapshotCacheService,
    CoverArtworkCacheService? coverArtworkCacheService,
  }) : _coverArtworkCacheService = coverArtworkCacheService;

  factory LibraryFacade.create({
    AudioDatabaseRepository? databaseRepository,
    AudioDetailRepository? detailRepository,
    AudioDetailCacheService? detailCacheService,
    DlsiteMetadataService? metadataService,
    AsmrMetadataService? asmrMetadataService,
    LibraryService? service,
    LibrarySnapshotCacheService? snapshotCacheService,
    CoverArtworkCacheService? coverArtworkCacheService,
  }) {
    final resolvedDatabase = databaseRepository ?? AudioDatabaseRepository();
    final resolvedDetailCache =
        detailCacheService ??
        AudioDetailCacheService(
          repository:
              detailRepository ??
              AudioDetailRepository(databaseRepository: resolvedDatabase),
        );
    final resolvedService = service ?? LibraryService();
    return LibraryFacade(
      databaseRepository: resolvedDatabase,
      detailCacheService: resolvedDetailCache,
      metadataService: metadataService ?? DlsiteMetadataService(),
      asmrMetadataService: asmrMetadataService ?? AsmrMetadataService(),
      service: resolvedService,
      snapshotCacheService:
          snapshotCacheService ??
          LibrarySnapshotCacheService(
            libraryService: resolvedService,
            detailCacheService: resolvedDetailCache,
          ),
      coverArtworkCacheService: coverArtworkCacheService,
    );
  }

  final AudioDatabaseRepository databaseRepository;
  final AudioDetailCacheService detailCacheService;
  final DlsiteMetadataService metadataService;
  final AsmrMetadataService asmrMetadataService;
  final LibraryService service;
  final LibrarySnapshotCacheService snapshotCacheService;
  CoverArtworkCacheService? _coverArtworkCacheService;
  LibraryCatalog? _catalog;

  LibraryState get state => service.slice.state;
  Stream<LibraryState> get states => service.slice.stream;
  List<LibraryNode> get libraryCards => snapshotCacheService.cards;
  List<MusicTrack> get library =>
      UnmodifiableListView<MusicTrack>(service.library);
  List<String> get watchedFolders =>
      UnmodifiableListView<String>(service.watchedFolders);
  List<String> get watchedLibraries =>
      UnmodifiableListView<String>(service.watchedLibraries);
  AudioLibraryCategorySnapshot? get categorySnapshot =>
      snapshotCacheService.categorySnapshotSync;

  AudioDetail? resolvedAudioDetail(AudioDetailTarget target) =>
      detailCacheService.resolvedDetail(target);
  MusicTrack? trackByPath(String trackPath) => service.trackByPath(trackPath);
  String? libraryEntryDisplayNameForPath(
    String libraryPath,
    String entryPath,
  ) => service.libraryEntryDisplayNameForPath(libraryPath, entryPath);
  List<String> excludedTracksForLibrary(String libraryPath) =>
      service.excludedTracksForLibrary(libraryPath);
  List<String> excludedFoldersForLibrary(String libraryPath) =>
      service.excludedFoldersForLibrary(libraryPath);
  List<String> childFoldersForLibrary(String libraryPath) =>
      service.childFoldersForLibrary(libraryPath);
  List<LibraryEntry> libraryEntriesForLibrary(String libraryPath) =>
      service.libraryEntriesForLibrary(libraryPath);
  bool isLibraryTrackExplicitlyExcluded(String libraryPath, String trackPath) =>
      service.isLibraryTrackExplicitlyExcluded(libraryPath, trackPath);
  bool isLibraryFolderExplicitlyExcluded(
    String libraryPath,
    String folderPath,
  ) => service.isLibraryFolderExplicitlyExcluded(libraryPath, folderPath);
  bool isLibraryPathExcluded(String libraryPath, String entityPath) =>
      service.isLibraryPathExcluded(libraryPath, entityPath);
  bool isLibraryPathInheritedExcluded(String libraryPath, String entityPath) =>
      service.isLibraryPathInheritedExcluded(libraryPath, entityPath);

  LibraryCatalog get catalog {
    final catalog = _catalog;
    if (catalog == null) {
      throw StateError(
        'LibraryFacade catalog commands have not been attached.',
      );
    }
    return catalog;
  }

  void attachCatalog(LibraryCatalog catalog) {
    _catalog ??= catalog;
  }

  CoverArtworkCacheService get coverArtworkCacheService {
    final service = _coverArtworkCacheService;
    if (service == null) {
      throw StateError('LibraryFacade cover service has not been attached.');
    }
    return service;
  }

  void attachCoverArtworkCacheService(
    CoverArtworkCacheService Function() create,
  ) {
    _coverArtworkCacheService ??= create();
  }

  Future<void> dispose() async {
    _coverArtworkCacheService?.dispose();
    await service.dispose();
  }
}
