part of 'audio_provider.dart';

extension AudioProviderLibraryCategories on AudioProvider {
  AudioLibraryCategorySnapshot? get audioLibraryCategorySnapshotSync =>
      _audioLibraryCategorySnapshot;

  Future<AudioLibraryCategorySnapshot> audioLibraryCategorySnapshot() {
    final structureRevision = _libraryService.structureRevision;
    final detailRevision = _audioDetailRevision;
    final cached = _audioLibraryCategorySnapshot;
    if (cached != null &&
        cached.structureRevision == structureRevision &&
        cached.detailRevision == detailRevision) {
      return Future.value(cached);
    }

    final inFlight = _audioLibraryCategorySnapshotFuture;
    if (inFlight != null &&
        _audioLibraryCategoryFutureStructureRevision == structureRevision &&
        _audioLibraryCategoryFutureDetailRevision == detailRevision) {
      return inFlight;
    }

    final future = _buildAudioLibraryCategorySnapshot(
      structureRevision: structureRevision,
      detailRevision: detailRevision,
    );
    _audioLibraryCategorySnapshotFuture = future;
    _audioLibraryCategoryFutureStructureRevision = structureRevision;
    _audioLibraryCategoryFutureDetailRevision = detailRevision;
    unawaited(
      future
          .then((snapshot) {
            if (snapshot.structureRevision ==
                    _libraryService.structureRevision &&
                snapshot.detailRevision == _audioDetailRevision) {
              final hadCachedSnapshot = _audioLibraryCategorySnapshot != null;
              _audioLibraryCategorySnapshot = snapshot;
              if (!hadCachedSnapshot) {
                _notifyPresentationListeners();
              }
            }
          })
          .whenComplete(() {
            if (identical(_audioLibraryCategorySnapshotFuture, future)) {
              _audioLibraryCategorySnapshotFuture = null;
            }
          }),
    );
    return future;
  }

  void _markAudioDetailDataChanged() {
    _audioDetailRevision++;
    _audioLibraryCategorySnapshot = null;
    _audioLibraryCategorySnapshotFuture = null;
  }

  Future<AudioLibraryCategorySnapshot> _buildAudioLibraryCategorySnapshot({
    required int structureRevision,
    required int detailRevision,
  }) async {
    final entries = <AudioLibraryCategoryEntry>[];
    final tagFrequencies = <String, int>{};
    final voiceActorFrequencies = <String, int>{};
    final circleFrequencies = <String, int>{};

    for (final node in libraryTree) {
      if (node is FolderNode) {
        final target = AudioDetailTarget.libraryRootFolder(node.path);
        final detail = await _loadCategoryDetail(target);
        final entry = AudioLibraryCategoryEntry(
          target: target,
          title: node.name,
          path: node.path,
          isFolder: true,
          detail: detail,
          tracks: List<MusicTrack>.unmodifiable(node.allTracks),
        );
        entries.add(entry);
        _countCategoryTerms(
          entry,
          tagFrequencies,
          voiceActorFrequencies,
          circleFrequencies,
        );
      } else if (node is TrackNode && node.track.isSingle) {
        final target = AudioDetailTarget.singleAudioFile(node.track.path);
        final detail = await _loadCategoryDetail(target);
        final entry = AudioLibraryCategoryEntry(
          target: target,
          title: node.track.displayName,
          path: node.track.path,
          isFolder: false,
          detail: detail,
          tracks: List<MusicTrack>.unmodifiable([node.track]),
        );
        entries.add(entry);
        _countCategoryTerms(
          entry,
          tagFrequencies,
          voiceActorFrequencies,
          circleFrequencies,
        );
      }
    }

    return AudioLibraryCategorySnapshot(
      entries: List<AudioLibraryCategoryEntry>.unmodifiable(entries),
      tagTerms: AudioLibraryCategorySnapshot.sortTermsByFrequency(
        tagFrequencies,
      ),
      voiceActorTerms: AudioLibraryCategorySnapshot.sortTermsByFrequency(
        voiceActorFrequencies,
      ),
      circleTerms: AudioLibraryCategorySnapshot.sortTermsByFrequency(
        circleFrequencies,
      ),
      structureRevision: structureRevision,
      detailRevision: detailRevision,
    );
  }

  Future<AudioDetail> _loadCategoryDetail(AudioDetailTarget target) async {
    try {
      return (await loadAudioDetail(target)).detail;
    } catch (_) {
      return AudioDetail.empty(target);
    }
  }

  void _countCategoryTerms(
    AudioLibraryCategoryEntry entry,
    Map<String, int> tagFrequencies,
    Map<String, int> voiceActorFrequencies,
    Map<String, int> circleFrequencies,
  ) {
    for (final term in AudioLibraryCategorySnapshot.splitTerms(
      entry.detail.tags,
    )) {
      tagFrequencies[term] = (tagFrequencies[term] ?? 0) + 1;
    }
    for (final term in AudioLibraryCategorySnapshot.splitTerms(
      entry.detail.voiceActors,
    )) {
      voiceActorFrequencies[term] = (voiceActorFrequencies[term] ?? 0) + 1;
    }
    for (final term in AudioLibraryCategorySnapshot.splitTerms([
      entry.detail.circleName,
    ])) {
      circleFrequencies[term] = (circleFrequencies[term] ?? 0) + 1;
    }
  }
}
