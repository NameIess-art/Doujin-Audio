import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../widgets/app_feedback.dart';
import '../widgets/confirm_action_dialog.dart';
import '../widgets/mobile_overlay_inset.dart';
import '../widgets/swipe_reveal_card.dart';
import '../widgets/top_page_header.dart';
import 'video_converter_tab.dart';

class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab>
    with AutomaticKeepAliveClientMixin {
  static const MethodChannel _fileCacheChannel = MethodChannel(
    'music_player/file_cache',
  );

  @override
  bool get wantKeepAlive => true;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Timer? _searchDebounceTimer;
  List<LibraryNode>? _cachedFilteredTree;
  List<LibraryNode>? _cachedFilterRawTree;
  String _cachedFilterQuery = '';

  final GlobalKey _headerKey = GlobalKey();
  double _headerHeight = 72;
  static const double _searchBarHeight = 46;

  final ScrollController _scrollController = ScrollController();
  double _searchBarOffset =
      0; // 0 is fully visible, -_searchBarHeight is hidden

  Future<void> _openVideoConverterPage() async {
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const VideoConverterTab()));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _refreshWatchedFolders(silent: true);
        _measureHeader();
      }
    });
  }

  void _measureHeader() {
    final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && mounted) {
      final h = box.size.height;
      if (h > 0 && h != _headerHeight) {
        setState(() => _headerHeight = h);
      }
    }
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

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

  Future<String?> _cachePickedFile(PlatformFile file, int index) async {
    final stream = file.readStream;
    final identifier = file.identifier;

    if (stream != null) {
      try {
        final cacheDir = await _persistentImportDirectory();
        if (!await cacheDir.exists()) await cacheDir.create(recursive: true);

        final extension = path.extension(file.name);
        final outPath = path.join(
          cacheDir.path,
          '${DateTime.now().microsecondsSinceEpoch}_$index${extension.isEmpty ? '.bin' : extension}',
        );

        final sink = File(outPath).openWrite();
        await stream.pipe(sink);
        await sink.close();
        return outPath;
      } catch (_) {}
    }

    if (Platform.isAndroid &&
        identifier != null &&
        identifier.startsWith('content://')) {
      try {
        return await _fileCacheChannel.invokeMethod<String>('cacheFromUri', {
          'uri': identifier,
          'name': file.name,
          'index': index,
        });
      } catch (_) {}
    }
    return null;
  }

  Future<Directory> _persistentImportDirectory() async {
    final supportDir = await getApplicationSupportDirectory();
    return Directory(path.join(supportDir.path, 'music_player_imports'));
  }

  Future<List<_ScannedTrack>?> _scanFolderViaNative(String folderPath) async {
    if (!Platform.isAndroid) return null;
    try {
      final data = await _fileCacheChannel.invokeMethod<List<dynamic>>(
        'scanFolder',
        {'folder': folderPath},
      );
      if (data == null) return null;

      final scanned = <_ScannedTrack>[];
      for (final item in data) {
        if (item is! Map) continue;
        final map = item.cast<Object?, Object?>();
        final scannedPath = map['path']?.toString().trim();
        if (scannedPath == null ||
            scannedPath.isEmpty ||
            !_isSupportedAudioFile(scannedPath)) {
          continue;
        }

        final nativeGroupKey = map['groupKey']?.toString().trim();
        final nativeGroupTitle = map['groupTitle']?.toString().trim();
        final nativeGroupSubtitle = map['groupSubtitle']?.toString().trim();

        final groupKey = (nativeGroupKey?.isNotEmpty ?? false)
            ? nativeGroupKey!
            : path.dirname(scannedPath);
        final groupTitle = (nativeGroupTitle?.isNotEmpty ?? false)
            ? nativeGroupTitle!
            : path.basename(groupKey);
        final groupSubtitle = (nativeGroupSubtitle?.isNotEmpty ?? false)
            ? nativeGroupSubtitle!
            : groupKey;
        final displayName = map['title']?.toString().trim();
        final resolvedPath = scannedPath.startsWith('content://')
            ? scannedPath
            : path.normalize(scannedPath);

        scanned.add(
          _ScannedTrack(
            path: resolvedPath,
            groupKey: groupKey,
            groupTitle: groupTitle,
            groupSubtitle: groupSubtitle,
            isSingle: false,
            displayName: displayName?.isEmpty ?? true ? null : displayName,
          ),
        );
      }
      return scanned;
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _listImmediateChildFolders(String folderPath) async {
    if (Platform.isAndroid) {
      try {
        final data = await _fileCacheChannel.invokeMethod<List<dynamic>>(
          'listChildFolders',
          {'folder': folderPath},
        );
        if (data != null) {
          final folders = data
              .map((item) => item?.toString().trim() ?? '')
              .where((item) => item.isNotEmpty)
              .toList(growable: false);
          if (folders.isNotEmpty) {
            return folders;
          }
        }
      } catch (_) {}
    }

    final directory = Directory(folderPath);
    if (!await directory.exists()) return const <String>[];

    final childFolders = <String>[];
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! Directory) continue;
        childFolders.add(path.normalize(entity.path));
      }
    } catch (_) {
      return const <String>[];
    }

    childFolders.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return childFolders;
  }

  Future<int> _importFolderIncrementally(
    String folderPath,
    AudioProvider provider,
  ) async {
    final folder = Directory(folderPath);
    if (!await folder.exists()) return 0;

    final existingPaths = provider.library.map((t) => t.path).toSet();
    final pendingDirs = Queue<Directory>()..add(folder);
    final batch = <MusicTrack>[];
    const batchSize = 350;
    var added = 0;
    var duplicates = 0;
    var failures = 0;
    var dirsProcessed = 0;

    while (pendingDirs.isNotEmpty && mounted && provider.isScanning) {
      final currentDir = pendingDirs.removeFirst();
      late final Stream<FileSystemEntity> stream;
      try {
        stream = currentDir.list(followLinks: false);
      } catch (_) {
        failures++;
        continue;
      }

      dirsProcessed++;
      if (dirsProcessed % 8 == 0) {
        provider.setScanProgress(
          currentFolder: path.basename(currentDir.path),
          foundCount: provider.scanFoundCount + added,
          duplicateCount: provider.scanDuplicateCount + duplicates,
          failureCount: provider.scanFailureCount + failures,
        );
      }

      try {
        await for (final entity in stream.handleError((_) {})) {
          if (!provider.isScanning) break;
          if (entity is Directory) {
            pendingDirs.add(entity);
            continue;
          }
          if (entity is! File) continue;

          final absolutePath = path.normalize(entity.path);
          if (!_isSupportedAudioFile(absolutePath)) continue;
          if (existingPaths.contains(absolutePath)) {
            duplicates++;
            continue;
          }
          existingPaths.add(absolutePath);

          final parentFolder = path.dirname(absolutePath);
          final folderName = path.basename(parentFolder);

          batch.add(
            MusicTrack(
              path: absolutePath,
              displayName: path.basenameWithoutExtension(absolutePath),
              groupKey: parentFolder,
              groupTitle: folderName.isEmpty ? parentFolder : folderName,
              groupSubtitle: parentFolder,
              isSingle: false,
            ),
          );
          added++;

          if (batch.length >= batchSize) {
            provider.addTracks(batch, notify: false);
            batch.clear();
            await Future<void>.delayed(Duration.zero);
          }
        }
      } catch (_) {
        failures++;
      }
    }
    provider.addTracks(batch, notify: false);
    provider.setScanProgress(
      foundCount: provider.scanFoundCount + added,
      duplicateCount: provider.scanDuplicateCount + duplicates,
      failureCount: provider.scanFailureCount + failures,
    );
    return added;
  }

  bool _isSupportedAudioFile(String filePath) {
    if (filePath.toLowerCase().endsWith('.flac') ||
        filePath.toLowerCase().endsWith('.wav')) {
      return true;
    }
    final mimeType = lookupMimeType(filePath);
    if (mimeType == null) return true;
    return mimeType.startsWith('audio/') || mimeType == 'application/ogg';
  }

  Future<bool> _ensureReadPermission() async {
    if (!Platform.isAndroid) return true;
    final manageStatus = await Permission.manageExternalStorage.request();
    if (manageStatus.isGranted) return true;
    final statuses = await [Permission.audio, Permission.storage].request();
    return statuses.values.any(
      (status) => status.isGranted || status.isLimited,
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    showAppSnackBar(context, message);
  }

  List<LibraryNode> _filterTreeCached(List<LibraryNode> tree, String query) {
    if (identical(tree, _cachedFilterRawTree) && query == _cachedFilterQuery) {
      return _cachedFilteredTree!;
    }
    _cachedFilterRawTree = tree;
    _cachedFilterQuery = query;
    _cachedFilteredTree = _filterTree(tree, query);
    return _cachedFilteredTree!;
  }

  List<LibraryNode> _filterTree(List<LibraryNode> tree, String query) {
    if (query.isEmpty) return tree;
    final lowerQuery = query.toLowerCase();
    final result = <LibraryNode>[];

    for (final node in tree) {
      final nameMatch = node.name.toLowerCase().contains(lowerQuery);
      if (node is FolderNode) {
        if (nameMatch) {
          result.add(node);
        } else {
          final filtered = _filterTree(node.children, query);
          if (filtered.isNotEmpty) {
            final copy = FolderNode(node.name, node.path, depth: node.depth);
            copy.children.addAll(filtered);
            result.add(copy);
          }
        }
      } else if (node is TrackNode) {
        if (nameMatch) result.add(node);
      }
    }
    return result;
  }

  int _countTrackNodes(List<LibraryNode> nodes) {
    var count = 0;
    for (final node in nodes) {
      if (node is TrackNode) {
        count++;
      } else if (node is FolderNode) {
        count += _countTrackNodes(node.children);
      }
    }
    return count;
  }

  Widget _buildSearchBar(
    AppLanguageProvider i18n,
    int matchCount,
    int totalCount,
  ) {
    final cs = Theme.of(context).colorScheme;
    final hasText = _searchController.text.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 34,
            child: TextField(
              controller: _searchController,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontSize: 13),
              decoration: InputDecoration(
                filled: true,
                fillColor: cs.surfaceContainerHigh,
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: cs.onSurfaceVariant,
                  size: 18,
                ),
                suffixIcon: hasText
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          _searchDebounceTimer?.cancel();
                          setState(() => _searchQuery = '');
                        },
                        color: cs.onSurfaceVariant,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                      )
                    : null,
                hintText: i18n.tr('search_audio_placeholder'),
                hintStyle: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(17),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(17),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(17),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                isDense: true,
              ),
              onChanged: (value) {
                _searchDebounceTimer?.cancel();
                _searchDebounceTimer = Timer(
                  const Duration(milliseconds: 220),
                  () {
                    if (!mounted) return;
                    setState(() => _searchQuery = value.trim());
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanProgressCard(
    AppLanguageProvider i18n,
    AudioProvider provider,
    String currentFolder,
    int found,
    int dup,
    int fail,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 4,
      shadowColor: cs.shadow,
      color: cs.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: cs.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    i18n.tr('scanning_title'),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => provider.cancelScan(),
                  icon: Icon(Icons.close_rounded, size: 16, color: cs.error),
                  label: Text(
                    i18n.tr('scan_cancel'),
                    style: TextStyle(color: cs.error, fontSize: 12),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            if (currentFolder.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.folder_open_rounded,
                    size: 14,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      currentFolder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                _ScanCountChip(
                  label: i18n.tr('scan_found'),
                  count: found,
                  color: cs.primary,
                ),
                const SizedBox(width: 8),
                _ScanCountChip(
                  label: i18n.tr('scan_duplicate'),
                  count: dup,
                  color: cs.tertiary,
                ),
                const SizedBox(width: 8),
                _ScanCountChip(
                  label: i18n.tr('scan_failure'),
                  count: fail,
                  color: cs.error,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool _onLibraryScrollNotification(ScrollNotification n) {
    if (n is ScrollUpdateNotification) {
      final d = n.scrollDelta ?? 0;
      final pixels = n.metrics.pixels;

      if (pixels <= 0) {
        if (_searchBarOffset != 0) {
          setState(() => _searchBarOffset = 0);
        }
      } else if (d > 0.5) {
        // Scrolling up (content moves up)
        if (_searchBarOffset > -_searchBarHeight) {
          setState(() {
            _searchBarOffset = max(-_searchBarHeight, _searchBarOffset - d);
          });
        }
      } else if (d < -0.5 && pixels < 100) {
        // Scrolling down (content moves down) - only near top
        if (_searchBarOffset < 0) {
          setState(() {
            _searchBarOffset = min(0.0, _searchBarOffset - d);
          });
        }
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final i18n = context.watch<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    final rawTree = context.select<AudioProvider, List<LibraryNode>>(
      (p) => p.libraryTree,
    );
    final audioCount = context.select<AudioProvider, int>(
      (p) => p.libraryTrackCount,
    );
    final isScanning = context.select<AudioProvider, bool>((p) => p.isScanning);
    final scanFolder = context.select<AudioProvider, String>(
      (p) => p.scanCurrentFolder,
    );
    final scanFound = context.select<AudioProvider, int>(
      (p) => p.scanFoundCount,
    );
    final scanDup = context.select<AudioProvider, int>(
      (p) => p.scanDuplicateCount,
    );
    final scanFail = context.select<AudioProvider, int>(
      (p) => p.scanFailureCount,
    );
    final tree = _filterTreeCached(rawTree, _searchQuery);
    final matchCount = _countTrackNodes(tree);
    final bottomInset = MobileOverlayInset.of(context);
    final topTotalHeight = _headerHeight + _searchBarOffset + 4;
    final hasLibrary = rawTree.isNotEmpty;

    return Stack(
      children: [
        // 1. Content Layer (Scrolls behind header)
        Positioned.fill(
          child: tree.isEmpty
              ? (_searchQuery.isNotEmpty
                    ? Center(
                        child: Padding(
                          padding: EdgeInsets.only(top: topTotalHeight),
                          child: Text(
                            hasLibrary
                                ? i18n.tr('no_search_results')
                                : i18n.tr('no_audio_files'),
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      )
                    : Column(
                        children: [
                          SizedBox(height: topTotalHeight),
                          Expanded(
                            child: _LibraryEmptyState(
                              onImportLibrary: _addLibrary,
                              onImportFolder: _addFolder,
                              onImportFile: _addFiles,
                              bottomInset: bottomInset,
                            ),
                          ),
                        ],
                      ))
              : NotificationListener<ScrollNotification>(
                  onNotification: _onLibraryScrollNotification,
                  child: RefreshIndicator(
                    onRefresh: () => _refreshWatchedFolders(),
                    displacement: topTotalHeight + 10,
                    child: ReorderableListView.builder(
                      scrollController: _scrollController,
                      padding: EdgeInsets.fromLTRB(
                        16,
                        topTotalHeight,
                        16,
                        bottomInset,
                      ),
                      cacheExtent: 720,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      onReorder: (oldIndex, newIndex) {
                        if (_searchQuery.isNotEmpty) return;
                        provider.reorderLibraryNodes(oldIndex, newIndex);
                      },
                      itemCount: tree.length,
                      itemBuilder: (context, index) {
                        final node = tree[index];
                        return ReorderableDelayedDragStartListener(
                          key: ValueKey(node.path),
                          index: index,
                          child: _LibraryTreeItem(node: node),
                        );
                      },
                    ),
                  ),
                ),
        ),

        // Scan progress card
        if (isScanning)
          Positioned(
            top: _headerHeight + 6 + _searchBarHeight + _searchBarOffset + 10,
            left: 12,
            right: 12,
            child: _buildScanProgressCard(
              i18n,
              provider,
              scanFolder,
              scanFound,
              scanDup,
              scanFail,
            ),
          ),

        // 2. Header Layer (Frosted Glass via TopPageHeader)
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: TopPageHeader(
            key: _headerKey,
            icon: Icons.library_music_rounded,
            title: i18n.tr('music_library'),
            titleSuffix: Text(
              i18n.tr('audio_count', {'count': audioCount}),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            trailing: SizedBox(
              width: 52,
              height: 44,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  PopupMenuButton<int>(
                    icon: const Icon(Icons.add_circle_outline_rounded),
                    tooltip: i18n.tr('more_actions'),
                    onSelected: (value) {
                      if (value == 0) _addFolder();
                      if (value == 1) _addLibrary();
                      if (value == 2) _addFiles();
                      if (value == 3) _openVideoConverterPage();
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 0,
                        child: Row(
                          children: [
                            const Icon(
                              Icons.create_new_folder_rounded,
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Text(i18n.tr('import_folder')),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 1,
                        child: Row(
                          children: [
                            const Icon(Icons.library_add_rounded, size: 20),
                            const SizedBox(width: 12),
                            Text(i18n.tr('choose_library')),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 2,
                        child: Row(
                          children: [
                            const Icon(Icons.upload_file_rounded, size: 20),
                            const SizedBox(width: 12),
                            Text(i18n.tr('import_file')),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 3,
                        child: Row(
                          children: [
                            const Icon(Icons.video_library_rounded, size: 20),
                            const SizedBox(width: 12),
                            Text(i18n.tr('video_to_audio')),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            bottomSpacing: 4,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            additionalChild: Container(
              height: _searchBarHeight + _searchBarOffset,
              clipBehavior: Clip.hardEdge,
              decoration: const BoxDecoration(),
              child: OverflowBox(
                alignment: Alignment.topCenter,
                maxHeight: _searchBarHeight,
                minHeight: _searchBarHeight,
                child: Opacity(
                  opacity: (1.0 + (_searchBarOffset / _searchBarHeight)).clamp(
                    0.0,
                    1.0,
                  ),
                  child: _buildSearchBar(i18n, matchCount, audioCount),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

void _showSessionCreatedSnack(BuildContext context, String message) {
  showAppSnackBar(
    context,
    message,
    tone: AppFeedbackTone.success,
    icon: Icons.queue_music_rounded,
  );
}

class _ScanCountChip extends StatelessWidget {
  const _ScanCountChip({
    required this.label,
    required this.count,
    required this.color,
  });

  final String label;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$label: $count',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _LibraryEmptyState extends StatelessWidget {
  const _LibraryEmptyState({
    required this.onImportLibrary,
    required this.onImportFolder,
    required this.onImportFile,
    required this.bottomInset,
  });

  final VoidCallback onImportLibrary;
  final VoidCallback onImportFolder;
  final VoidCallback onImportFile;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: EdgeInsets.fromLTRB(24, 16, 24, bottomInset),
      physics: const BouncingScrollPhysics(),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    Icons.audio_file_rounded,
                    size: 30,
                    color: cs.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  i18n.tr('no_audio_files'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  i18n.tr('import_audio_hint'),
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: onImportLibrary,
                      icon: const Icon(Icons.library_add_rounded),
                      label: Text(i18n.tr('import_library')),
                    ),
                    FilledButton.icon(
                      onPressed: onImportFolder,
                      icon: const Icon(Icons.create_new_folder_rounded),
                      label: Text(i18n.tr('import_folder')),
                    ),
                    OutlinedButton.icon(
                      onPressed: onImportFile,
                      icon: const Icon(Icons.upload_file_rounded),
                      label: Text(i18n.tr('import_file')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _LibraryTreeItem extends StatelessWidget {
  const _LibraryTreeItem({super.key, required this.node});

  final LibraryNode node;

  @override
  Widget build(BuildContext context) {
    if (node is FolderNode) {
      return _FolderNodeWidget(folder: node as FolderNode);
    } else if (node is TrackNode) {
      return _TrackNodeWidget(trackNode: node as TrackNode);
    }
    return const SizedBox.shrink();
  }
}

class _FolderNodeWidget extends StatefulWidget {
  const _FolderNodeWidget({required this.folder});

  final FolderNode folder;

  @override
  State<_FolderNodeWidget> createState() => _FolderNodeWidgetState();
}

class _FolderNodeWidgetState extends State<_FolderNodeWidget> {
  final ExpansibleController _expansionController = ExpansibleController();
  bool _expanded = false;

  Future<void> _confirmRemoveFolder(
    BuildContext context,
    AudioProvider provider,
  ) async {
    final i18n = context.read<AppLanguageProvider>();
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('remove_folder'),
      message: i18n.tr('remove_folder_confirm', {'name': widget.folder.name}),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('remove'),
      icon: Icons.delete_outline_rounded,
    );
    if (confirmed == true && context.mounted) {
      await provider.removeFolderFromLibrary(widget.folder.path);
    }
  }

  void _playFolder(BuildContext context, AudioProvider provider) {
    final i18n = context.read<AppLanguageProvider>();
    final firstTrack = widget.folder.firstTrack;
    if (firstTrack == null) return;
    Feedback.forTap(context);
    unawaited(provider.spawnSession(firstTrack));
    _showSessionCreatedSnack(
      context,
      i18n.tr('session_created', {'name': firstTrack.displayName}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    final cs = Theme.of(context).colorScheme;
    final isRootFolder = widget.folder.depth == 0;
    final cardShape = RoundedRectangleBorder(
      side: BorderSide(color: cs.outlineVariant),
      borderRadius: BorderRadius.circular(14),
    );
    final groupLabel = isRootFolder
        ? ''
        : path.basename(path.dirname(widget.folder.path));

    return SwipeRevealCard(
      margin: const EdgeInsets.only(bottom: 6),
      shape: cardShape,
      actionLabel: i18n.tr('remove'),
      removeTooltip: i18n.tr('remove_audio_folder'),
      onRemove: () => _confirmRemoveFolder(context, provider),
      onWillReveal: _expansionController.collapse,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: cardShape,
        color: cs.surface,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            controller: _expansionController,
            onExpansionChanged: (expanded) {
              if (_expanded == expanded) return;
              setState(() {
                _expanded = expanded;
              });
            },
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            collapsedShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            tilePadding: EdgeInsets.fromLTRB(
              isRootFolder ? 12 : 10,
              isRootFolder ? 10 : 6,
              10,
              isRootFolder ? 10 : 6,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            leading: isRootFolder
                ? _LibraryCoverThumbnail(
                    coverPathFuture: provider.coverPathFutureForFolder(
                      widget.folder.path,
                    ),
                    title: widget.folder.name,
                  )
                : null,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (groupLabel.isNotEmpty) ...[
                  Text(
                    groupLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.65),
                      fontWeight: FontWeight.w500,
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(height: 3),
                ],
                Text(
                  widget.folder.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                    height: 1.06,
                  ),
                ),
                if (isRootFolder) ...[
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: _LibraryMetaChip(
                      icon: Icons.library_music_rounded,
                      text: i18n.tr('audio_count', {
                        'count': widget.folder.totalTrackCount,
                      }),
                    ),
                  ),
                ],
              ],
            ),
            trailing: SizedBox(
              width: 78,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton.filledTonal(
                    onPressed: () => _playFolder(context, provider),
                    visualDensity: VisualDensity.compact,
                    tooltip: i18n.tr('play'),
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  ),
                  const SizedBox(width: 4),
                  IgnorePointer(
                    child: AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.expand_more_rounded,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            children: widget.folder.children
                .map(
                  (childNode) => Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: _LibraryTreeItem(
                      key: ValueKey(childNode.path),
                      node: childNode,
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }
}

class _TrackNodeWidget extends StatelessWidget {
  const _TrackNodeWidget({required this.trackNode});

  final TrackNode trackNode;

  Future<void> _confirmRemoveTrack(
    BuildContext context,
    AudioProvider provider,
    MusicTrack track,
  ) async {
    final i18n = context.read<AppLanguageProvider>();
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('remove_audio'),
      message: track.displayName,
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('remove'),
      icon: Icons.delete_outline_rounded,
    );
    if (confirmed == true && context.mounted) {
      await provider.removeTrackFromLibrary(track.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    final cs = Theme.of(context).colorScheme;
    final track = trackNode.track;
    final isAlreadyPlaying = context.select<AudioProvider, bool>(
      (value) => value.isTrackActive(track.path),
    );
    final folderName = track.isSingle
        ? i18n.tr('imported_files')
        : track.groupTitle;
    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
    );

    return SwipeRevealCard(
      margin: const EdgeInsets.only(bottom: 6),
      shape: cardShape,
      actionLabel: i18n.tr('remove'),
      removeTooltip: i18n.tr('remove_audio'),
      onRemove: () => _confirmRemoveTrack(context, provider, track),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: cardShape,
        color: isAlreadyPlaying
            ? Color.alphaBlend(
                cs.primaryContainer.withValues(alpha: 0.40),
                cs.surfaceContainerHighest,
              )
            : cs.surfaceContainerHighest,
        child: SizedBox(
          height: 64,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 10, 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        folderName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant.withValues(alpha: 0.65),
                          fontWeight: FontWeight.w500,
                          fontSize: 10,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        track.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                              height: 1.06,
                            ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                IconButton.filledTonal(
                  onPressed: () {
                    Feedback.forTap(context);
                    unawaited(provider.spawnSession(track));
                    _showSessionCreatedSnack(
                      context,
                      i18n.tr('session_created', {'name': track.displayName}),
                    );
                  },
                  icon: Icon(
                    isAlreadyPlaying
                        ? Icons.playlist_add_rounded
                        : Icons.play_arrow_rounded,
                    size: 20,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryCoverThumbnail extends StatelessWidget {
  const _LibraryCoverThumbnail({
    required this.coverPathFuture,
    required this.title,
  });

  final Future<String?> coverPathFuture;
  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget fallback() {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              cs.primaryContainer,
              cs.secondaryContainer.withValues(alpha: 0.92),
            ],
          ),
        ),
        child: Center(
          child: Icon(
            Icons.photo_album_rounded,
            size: 28,
            color: cs.onPrimaryContainer,
          ),
        ),
      );
    }

    return SizedBox(
      width: 78,
      height: 78,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: FutureBuilder<String?>(
          future: coverPathFuture,
          builder: (context, snapshot) {
            final coverPath = snapshot.data;
            if (coverPath == null || coverPath.isEmpty) {
              return fallback();
            }
            final dpr = MediaQuery.devicePixelRatioOf(context);
            return Image.file(
              File(coverPath),
              fit: BoxFit.cover,
              cacheWidth: (78 * dpr).round(),
              cacheHeight: (78 * dpr).round(),
              errorBuilder: (_, _, _) => fallback(),
            );
          },
        ),
      ),
    );
  }
}

class _LibraryMetaChip extends StatelessWidget {
  const _LibraryMetaChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 12,
            color: cs.onSurfaceVariant.withValues(alpha: 0.65),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant.withValues(alpha: 0.65),
                fontSize: 9,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScannedTrack {
  const _ScannedTrack({
    required this.path,
    required this.groupKey,
    required this.groupTitle,
    required this.groupSubtitle,
    required this.isSingle,
    this.displayName,
  });

  final String path;
  final String groupKey;
  final String groupTitle;
  final String groupSubtitle;
  final bool isSingle;
  final String? displayName;
}
