part of 'library_tab.dart';

extension _LibraryTabImportActions on _LibraryTabState {
  Future<void> _refreshWatchedFolders({bool silent = false}) async {
    final i18n = context.read<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    final watchedFolders = provider.watchedFolders;
    final watchedLibraries = provider.watchedLibraries;
    if (watchedFolders.isEmpty && watchedLibraries.isEmpty) return;

    final permissionGranted = await _ensureReadPermission();
    if (!permissionGranted) {
      if (!silent) _showSnack(i18n.tr('need_storage_permission_scan_folder'));
      return;
    }

    if (!mounted) return;
    provider.setScanning(true);
    var totalAdded = 0;
    try {
      final foldersToRefresh = LinkedHashSet<String>.from(watchedFolders);
      for (final libraryRoot in watchedLibraries) {
        final childFolders = await _listImmediateChildFolders(libraryRoot);
        for (final childFolder in childFolders) {
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
              '[$processedFolders/$totalFolders] ${path.basename(folderPath)}',
        );
        final nativeTracks = await _scanFolderViaNative(folderPath);
        if (nativeTracks != null) {
          final toAdd = nativeTracks
              .map(
                (t) => MusicTrack(
                  path: t.path,
                  displayName:
                      t.displayName ?? path.basenameWithoutExtension(t.path),
                  groupKey: t.groupKey,
                  groupTitle: t.groupTitle,
                  groupSubtitle: t.groupSubtitle,
                  isSingle: t.isSingle,
                ),
              )
              .toList();
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
          totalAdded += await _importFolderIncrementally(folderPath, provider);
        }
      }
    } finally {
      if (mounted) {
        provider.setScanning(false);
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
    final permissionGranted = await _ensureReadPermission();
    if (!permissionGranted) {
      _showSnack(i18n.tr('need_storage_permission_import_audio'));
      return;
    }

    final folderPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: i18n.tr('choose_music_folder'),
    );
    if (folderPath == null || folderPath.isEmpty) return;
    await _addFolderFromPath(folderPath);
  }

  Future<void> _addLibrary() async {
    final i18n = context.read<AppLanguageProvider>();
    final permissionGranted = await _ensureReadPermission();
    if (!permissionGranted) {
      _showSnack(i18n.tr('need_storage_permission_import_audio'));
      return;
    }

    final folderPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: i18n.tr('choose_library_folder'),
    );
    if (folderPath == null || folderPath.isEmpty) return;

    final childFolders = await _listImmediateChildFolders(folderPath);
    if (childFolders.isEmpty) {
      _showSnack(i18n.tr('no_child_folder_found'));
      return;
    }

    if (mounted) {
      context.read<AudioProvider>().addWatchedLibrary(
        folderPath,
        notify: false,
      );
    }
    await _addFoldersFromPaths(
      childFolders,
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

    var added = 0;

    try {
      provider.setScanProgress(currentFolder: path.basename(folderPath));
      final nativeTracks = await _scanFolderViaNative(folderPath);
      if (nativeTracks != null) {
        final toAdd = nativeTracks
            .map(
              (t) => MusicTrack(
                path: t.path,
                displayName:
                    t.displayName ?? path.basenameWithoutExtension(t.path),
                groupKey: t.groupKey,
                groupTitle: t.groupTitle,
                groupSubtitle: t.groupSubtitle,
                isSingle: t.isSingle,
              ),
            )
            .toList();

        final beforeCount = provider.library.length;
        provider.addTracks(toAdd, notify: false);
        added = provider.library.length - beforeCount;
        provider.setScanProgress(
          foundCount: added,
          duplicateCount: toAdd.length - added,
        );
      } else {
        added = await _importFolderIncrementally(folderPath, provider);
      }
    } finally {
      if (mounted) {
        provider.addWatchedFolder(folderPath, notify: false);
        provider.setScanning(false);
        _showSnack(i18n.tr('import_done_added', {'count': added}));
      }
    }
  }

  Future<void> _addFoldersFromPaths(
    List<String> folderPaths, {
    String Function(int trackCount, int folderCount)? completionMessageBuilder,
  }) async {
    final i18n = context.read<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    final uniqueFolderPaths = LinkedHashSet<String>.from(
      folderPaths
          .map((folderPath) => folderPath.trim())
          .where((folderPath) => folderPath.isNotEmpty),
    ).toList(growable: false);
    if (uniqueFolderPaths.isEmpty || !mounted) return;

    provider.setScanning(true);
    var added = 0;
    final totalFolders = uniqueFolderPaths.length;
    var processedFolders = 0;

    try {
      for (final folderPath in uniqueFolderPaths) {
        if (!provider.isScanning) break;
        processedFolders++;
        provider.setScanProgress(
          currentFolder:
              '[$processedFolders/$totalFolders] ${path.basename(folderPath)}',
        );
        final nativeTracks = await _scanFolderViaNative(folderPath);
        if (nativeTracks != null) {
          final toAdd = nativeTracks
              .map(
                (t) => MusicTrack(
                  path: t.path,
                  displayName:
                      t.displayName ?? path.basenameWithoutExtension(t.path),
                  groupKey: t.groupKey,
                  groupTitle: t.groupTitle,
                  groupSubtitle: t.groupSubtitle,
                  isSingle: t.isSingle,
                ),
              )
              .toList();

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
          added += await _importFolderIncrementally(folderPath, provider);
        }

        if (!mounted) return;
        provider.addWatchedFolder(folderPath, notify: false);
      }
    } finally {
      if (mounted) {
        provider.setScanning(false);
        _showSnack(
          completionMessageBuilder?.call(added, uniqueFolderPaths.length) ??
              i18n.tr('import_done_added', {'count': added}),
        );
      }
    }
  }

  Future<void> _addFiles() async {
    final i18n = context.read<AppLanguageProvider>();
    final permissionGranted = await _ensureReadPermission();
    if (!permissionGranted) {
      _showSnack(i18n.tr('need_storage_permission_import_audio'));
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withReadStream: true,
      dialogTitle: i18n.tr('choose_audio_files'),
    );
    if (result == null) return;

    if (!mounted) return;
    context.read<AudioProvider>().setScanning(true);

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

      final candidates = resolvedPaths
          .where(_isSupportedAudioFile)
          .map(
            (p) => MusicTrack(
              path: p,
              displayName: path.basenameWithoutExtension(p),
              groupKey: '__single_files__',
              groupTitle: i18n.tr('imported_files'),
              groupSubtitle: i18n.tr('manually_selected_files'),
              isSingle: true,
            ),
          )
          .toList();

      if (mounted) {
        final provider = context.read<AudioProvider>();
        final beforeCount = provider.library.length;
        provider.addTracks(candidates, notify: false);
        final added = provider.library.length - beforeCount;
        _showSnack(i18n.tr('import_done_added', {'count': added}));
      }
    } finally {
      if (mounted) {
        context.read<AudioProvider>().setScanning(false);
      }
    }
  }
}
