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
          (folderPath) => PathMatcher.equalsNormalized(folderPath, libraryRoot),
        );
        provider.removeWatchedFolder(libraryRoot, notify: false);
        totalAdded += await _importLibraryRootAudioFiles(
          libraryRoot,
          provider,
          i18n,
        );
        final childFolders = await _listImmediateChildFolders(libraryRoot);
        for (final childFolder in childFolders) {
          if (provider.isLibraryPathExcluded(libraryRoot, childFolder)) {
            continue;
          }
          foldersToRefresh.add(childFolder);
          provider.addWatchedFolder(childFolder, notify: false);
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
        final nativeTracks = await _scanFolderViaNative(folderPath);
        if (nativeTracks != null) {
          final toAdd = _filterExcludedScannedTracks(
            provider,
            effectiveLibraryRoot,
            nativeTracks,
          ).map(_trackFromScanned).toList();
          final before = provider.library.length;
          provider.addTracks(toAdd, notify: false);
          final added = provider.library.length - before;
          totalAdded += added;
          provider.setScanProgress(
            foundCount: provider.scanFoundCount + added,
            duplicateCount:
                provider.scanDuplicateCount + (toAdd.length - added),
          );
        } else {
          totalAdded += await _importFolderIncrementally(
            folderPath,
            provider,
            effectiveLibraryRoot,
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

    if (mounted) {
      context.read<AudioProvider>().addWatchedLibrary(
        folderPath,
        notify: false,
      );
    }
    await _addFoldersFromPaths(
      importTargets,
      beforeFolderImport: (provider) =>
          _importLibraryRootAudioFiles(folderPath, provider, i18n),
      completionMessageBuilder: (trackCount, folderCount) {
        return i18n.tr('import_library_done', {
          'count': trackCount,
          'folderCount': folderCount,
        });
      },
    );
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
      final nativeTracks = await _scanFolderViaNative(folderPath);
      if (nativeTracks != null) {
        final toAdd = nativeTracks.map(_trackFromScanned).toList();

        final beforeCount = provider.library.length;
        provider.addTracks(toAdd, notify: false);
        added = provider.library.length - beforeCount;
        provider.setScanProgress(
          foundCount: added,
          duplicateCount: toAdd.length - added,
        );
      } else {
        added = await _importFolderIncrementally(folderPath, provider, null);
      }
    } finally {
      await provider.endLibraryBatch();
      provider.addWatchedFolder(folderPath, notify: false);
      provider.setScanning(false);
      if (mounted) {
        _showSnack(i18n.tr('import_done_added', {'count': added}));
      }
    }
  }

  Future<void> _addFoldersFromPaths(
    List<String> folderPaths, {
    Future<int> Function(AudioProvider provider)? beforeFolderImport,
    String Function(int trackCount, int folderCount)? completionMessageBuilder,
  }) async {
    final i18n = context.read<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    final uniqueFolderPaths = LinkedHashSet<String>.from(
      folderPaths
          .map((folderPath) => folderPath.trim())
          .where((folderPath) => folderPath.isNotEmpty),
    ).toList(growable: false);
    if (uniqueFolderPaths.isEmpty && beforeFolderImport == null) return;
    if (!mounted) return;

    provider.setScanning(true);
    provider.beginLibraryBatch();
    var added = 0;
    final totalFolders = uniqueFolderPaths.length;
    var processedFolders = 0;

    try {
      if (beforeFolderImport != null) {
        added += await beforeFolderImport(provider);
      }
      for (final folderPath in uniqueFolderPaths) {
        if (!provider.isScanning) break;
        processedFolders++;
        provider.setScanProgress(
          currentFolder:
              '[$processedFolders/$totalFolders] ${_displaySourceName(folderPath)}',
        );
        final nativeTracks = await _scanFolderViaNative(folderPath);
        if (nativeTracks != null) {
          final toAdd = _filterExcludedScannedTracks(
            provider,
            null,
            nativeTracks,
          ).map(_trackFromScanned).toList();

          final beforeCount = provider.library.length;
          provider.addTracks(toAdd, notify: false);
          final folderAdded = provider.library.length - beforeCount;
          added += folderAdded;
          provider.setScanProgress(
            foundCount: provider.scanFoundCount + folderAdded,
            duplicateCount:
                provider.scanDuplicateCount + (toAdd.length - folderAdded),
          );
        } else {
          added += await _importFolderIncrementally(folderPath, provider, null);
        }

        if (!mounted) return;
        provider.addWatchedFolder(folderPath, notify: false);
      }
    } finally {
      await provider.endLibraryBatch();
      provider.setScanning(false);
      if (mounted) {
        _showSnack(
          completionMessageBuilder?.call(added, uniqueFolderPaths.length) ??
              i18n.tr('import_done_added', {'count': added}),
        );
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
      for (final p in resolvedPaths.where(_isSupportedAudioFile)) {
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
}
