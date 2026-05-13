part of 'library_tab.dart';

extension _LibraryTabImportActions on _LibraryTabState {
  Future<void> _refreshWatchedFolders({bool silent = false}) async {
    final i18n = context.read<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    final watchedFolders = provider.watchedFolders;
    final watchedLibraries = provider.watchedLibraries;
    if (watchedFolders.isEmpty && watchedLibraries.isEmpty) return;

    final permissionGranted = await _ensureReadPermissionForSources(
      sources: <String>[...watchedFolders, ...watchedLibraries],
    );
    if (!permissionGranted) {
      if (!silent) _showSnack(i18n.tr('need_storage_permission_scan_folder'));
      return;
    }

    if (!mounted) return;
    provider.setScanning(true, background: true);
    provider.beginLibraryBatch();
    var totalAdded = 0;
    try {
      final foldersToRefresh = LinkedHashSet<String>.from(watchedFolders);
      for (final libraryRoot in watchedLibraries) {
        foldersToRefresh.removeWhere(
          (folderPath) => PathMatcher.isWithinOrEqual(folderPath, libraryRoot),
        );
        provider.removeWatchedFolder(libraryRoot, notify: false);
        final childFolders = await _listImmediateChildFolders(libraryRoot);
        totalAdded += await _importLibraryWithSingleScan(
          libraryRoot,
          provider,
          i18n,
        );
        for (final childFolder in childFolders) {
          if (provider.isLibraryPathExcluded(libraryRoot, childFolder)) {
            continue;
          }
          provider.addWatchedFolder(childFolder, notify: false);
          await _prefillRjDetailForFolder(provider, childFolder);
        }
      }

      final totalFolders = foldersToRefresh.length;
      var processedFolders = 0;
      for (final folderPath in foldersToRefresh) {
        if (!provider.isScanning) break;
        processedFolders++;
        provider.setScanProgress(
          currentFolder:
              '[$processedFolders/$totalFolders] ${_displaySourceName(folderPath)}',
        );
        final libraryRoot = watchedLibraries.firstWhere(
          (root) => PathMatcher.isWithinOrEqual(folderPath, root),
          orElse: () => '',
        );
        final effectiveLibraryRoot = libraryRoot.isEmpty ? null : libraryRoot;
        final nativeScan = await _scanFolderViaNative(folderPath);
        if (nativeScan.ok) {
          final toAdd = _filterExcludedScannedTracks(
            provider,
            effectiveLibraryRoot,
            nativeScan.tracks,
          ).map(_trackFromScanned).toList();
          final before = provider.library.length;
          provider.addOrReplaceTracks(toAdd, notify: false);
          final added = provider.library.length - before;
          totalAdded += added;
          provider.setScanProgress(
            foundCount: provider.scanFoundCount + added,
            duplicateCount:
                provider.scanDuplicateCount + (toAdd.length - added),
          );
        } else if (nativeScan.notSupported ||
            !PathMatcher.isContentUri(folderPath)) {
          totalAdded += await _importFolderIncrementally(
            folderPath,
            provider,
            effectiveLibraryRoot,
          );
        } else {
          provider.setScanProgress(failureCount: provider.scanFailureCount + 1);
          debugPrint(
            '[library-import] native scan failed for content uri: $folderPath '
            'code=${nativeScan.errorCode} message=${nativeScan.errorMessage}',
          );
        }
      }
    } finally {
      await provider.endLibraryBatch();
      provider.setScanning(false);
      if (mounted) {
        if (!silent || totalAdded > 0) {
          _showSnack(
            totalAdded > 0
                ? i18n.tr('refresh_done_added', {'count': totalAdded})
                : i18n.tr('refresh_done_no_new'),
          );
        }
      }
    }
  }

  Future<void> _addFolder() async {
    final i18n = context.read<AppLanguageProvider>();
    if (Platform.isAndroid) {
      try {
        final folderPath = await _pickAudioFolderViaNative();
        if (folderPath == null || folderPath.isEmpty) return;
        await _addFolderFromPath(folderPath);
        return;
      } on PlatformException {
        // Fall back to FilePicker below on ROMs without a compatible document UI.
      }
    }

    final folderPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: i18n.tr('choose_music_folder'),
    );
    if (folderPath == null || folderPath.isEmpty) return;
    await _addFolderFromPath(folderPath);
  }

  Future<void> _addLibrary() async {
    final i18n = context.read<AppLanguageProvider>();
    if (Platform.isAndroid) {
      try {
        final folderPath = await _pickAudioFolderViaNative();
        if (folderPath == null || folderPath.isEmpty) return;
        await _addLibraryFromPath(folderPath, i18n);
        return;
      } on PlatformException {
        // Fall back to FilePicker below on ROMs without a compatible document UI.
      }
    }

    final folderPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: i18n.tr('choose_library_folder'),
    );
    if (folderPath == null || folderPath.isEmpty) return;
    await _addLibraryFromPath(folderPath, i18n);
  }

  Future<void> _addLibraryFromPath(
    String folderPath,
    AppLanguageProvider i18n,
  ) async {
    final childFolders = await _listImmediateChildFolders(folderPath);
    final importTargets = childFolders;
    if (!mounted) return;
    final provider = context.read<AudioProvider>();

    provider.addWatchedLibrary(folderPath, notify: false);
    provider.setScanning(true);
    provider.beginLibraryBatch();
    var added = 0;
    try {
      added = await _importLibraryWithSingleScan(folderPath, provider, i18n);
      for (final childFolder in importTargets) {
        if (provider.isLibraryPathExcluded(folderPath, childFolder)) continue;
        provider.addWatchedFolder(childFolder, notify: false);
        await _prefillRjDetailForFolder(provider, childFolder);
      }
    } finally {
      await provider.endLibraryBatch();
      provider.setScanning(false);
      if (mounted) {
        _showSnack(
          i18n.tr('import_library_done', {
            'count': added,
            'folderCount': importTargets.length,
          }),
        );
      }
    }
  }

  Future<void> _addFolderFromPath(String folderPath) async {
    final i18n = context.read<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    if (!mounted) return;
    provider.setScanning(true);
    provider.beginLibraryBatch();

    var added = 0;

    try {
      provider.setScanProgress(currentFolder: _displaySourceName(folderPath));
      final nativeScan = await _scanFolderViaNative(folderPath);
      if (nativeScan.ok) {
        final toAdd = nativeScan.tracks.map(_trackFromScanned).toList();

        final beforeCount = provider.library.length;
        provider.addOrReplaceTracks(toAdd, notify: false);
        added = provider.library.length - beforeCount;
        provider.setScanProgress(
          foundCount: added,
          duplicateCount: toAdd.length - added,
        );
      } else if (nativeScan.notSupported ||
          !PathMatcher.isContentUri(folderPath)) {
        added = await _importFolderIncrementally(folderPath, provider, null);
      } else {
        provider.setScanProgress(failureCount: provider.scanFailureCount + 1);
        debugPrint(
          '[library-import] native scan failed for content uri: $folderPath '
          'code=${nativeScan.errorCode} message=${nativeScan.errorMessage}',
        );
      }
    } finally {
      await provider.endLibraryBatch();
      provider.addWatchedFolder(folderPath, notify: false);
      await _prefillRjDetailForFolder(provider, folderPath);
      provider.setScanning(false);
      if (mounted) {
        _showSnack(i18n.tr('import_done_added', {'count': added}));
      }
    }
  }

  Future<void> _addFiles() async {
    final i18n = context.read<AppLanguageProvider>();
    if (Platform.isAndroid) {
      try {
        final pickedFiles = await _pickAudioFilesViaNative();
        if (pickedFiles == null || pickedFiles.isEmpty || !mounted) return;
        final provider = context.read<AudioProvider>();
        provider.setScanning(true);
        provider.beginLibraryBatch();

        try {
          final candidates = _tracksFromPickedAudioFiles(pickedFiles, i18n);
          final beforeCount = provider.library.length;
          provider.addTracks(candidates, notify: false);
          final added = provider.library.length - beforeCount;
          _showSnack(i18n.tr('import_done_added', {'count': added}));
        } finally {
          await provider.endLibraryBatch();
          provider.setScanning(false);
        }
        return;
      } on PlatformException {
        // Fall back to FilePicker below on ROMs without a compatible document UI.
      }
    }

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withReadStream: true,
      dialogTitle: i18n.tr('choose_audio_files'),
    );
    if (result == null) return;

    if (!mounted) return;
    final provider = context.read<AudioProvider>();
    provider.setScanning(true);
    provider.beginLibraryBatch();

    try {
      final resolvedPaths = <String>[];
      for (var i = 0; i < result.files.length; i++) {
        final file = result.files[i];
        final rawPath = file.path;
        final needsCopy =
            rawPath == null ||
            rawPath.isEmpty ||
            rawPath.startsWith('content://');

        if (!needsCopy) {
          resolvedPaths.add(path.normalize(rawPath));
          continue;
        }

        final cachedPath = await _cachePickedFile(file, i);
        if (cachedPath != null) {
          resolvedPaths.add(path.normalize(cachedPath));
        }
      }

      final candidates = <MusicTrack>[];
      for (final p in resolvedPaths.where(isSupportedMediaFile)) {
        final file = File(p);
        FileStat? fileStat;
        try {
          fileStat = await file.stat();
        } catch (_) {}
        candidates.add(
          MusicTrack(
            path: p,
            displayName: _displayTrackName(p),
            groupKey: '__single_files__',
            groupTitle: i18n.tr('imported_files'),
            groupSubtitle: i18n.tr('manually_selected_files'),
            isSingle: true,
            isVideo: isVideoMediaFile(p),
            scannedAt: DateTime.now(),
            fileSizeBytes: fileStat?.size,
            modifiedAt: fileStat?.modified,
          ),
        );
      }

      if (mounted) {
        final beforeCount = provider.library.length;
        provider.addTracks(candidates, notify: false);
        final added = provider.library.length - beforeCount;
        _showSnack(i18n.tr('import_done_added', {'count': added}));
      }
    } finally {
      await provider.endLibraryBatch();
      provider.setScanning(false);
    }
  }

  Future<void> _prefillRjDetailForFolder(
    AudioProvider provider,
    String folderPath,
  ) async {
    try {
      await provider.prefillAudioDetailRjCodeFromText(
        AudioDetailTarget.libraryRootFolder(folderPath),
        _displaySourceName(folderPath),
      );
    } catch (_) {}
  }
}
