import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/app_log_service.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/subtitle_parser.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/persistence/app_preferences.dart';
import '../../library/application/work_text_service.dart';
import 'subtitle_ai_engine.dart';
import 'subtitle_generation.dart';
import 'subtitle_model_store.dart';

typedef PlaybackTrackResolver = MusicTrack? Function(String trackPath);
typedef PlaybackSubtitleLoader =
    Future<SubtitleTrack?> Function(String trackPath, MusicTrack? track);

enum SubtitleGenerationStatus { running, completed, noMatch, cancelled, failed }

class SubtitleGenerationJob {
  SubtitleGenerationJob({required this.trackPath, required this.kind});

  final String trackPath;
  final SubtitleDraftKind kind;
  SubtitleGenerationStatus _status = SubtitleGenerationStatus.running;
  SubtitleTaskProgress? _progress;
  String? _errorMessage;
  bool _cancelRequested = false;
  final Completer<void> _cancellation = Completer<void>();

  SubtitleGenerationStatus get status => _status;
  SubtitleTaskProgress? get progress => _progress;
  String? get errorMessage => _errorMessage;
  bool get cancellationRequested => _cancelRequested;
}

class PlaybackSubtitleService extends ChangeNotifier {
  PlaybackSubtitleService({
    required PlaybackTrackResolver trackResolver,
    FileCachePlatformGateway? fileCacheGateway,
    void Function(String trackPath, SubtitleTrack? track)? onTrackLoaded,
    PlaybackSubtitleLoader? subtitleLoader,
    Future<Directory> Function()? subtitlesDirectoryResolver,
    Map<String, Duration>? initialOffsets,
    Map<String, String>? initialCustomPaths,
    SubtitleAiEngine? aiEngine,
  }) : _trackResolver = trackResolver,
       _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _onTrackLoaded = onTrackLoaded,
       _subtitleLoader = subtitleLoader,
       _subtitlesDirectoryResolver =
           subtitlesDirectoryResolver ?? _defaultSubtitlesDirectory,
       _aiEngine = aiEngine ?? SubtitleAiEngine() {
    if (initialOffsets != null) _offsets.addAll(initialOffsets);
    if (initialCustomPaths != null) _customPaths.addAll(initialCustomPaths);
    _settingsReady = _loadPersistedSettings();
  }

  final PlaybackTrackResolver _trackResolver;
  final FileCachePlatformGateway _fileCacheGateway;
  final void Function(String trackPath, SubtitleTrack? track)? _onTrackLoaded;
  final PlaybackSubtitleLoader? _subtitleLoader;
  final Future<Directory> Function() _subtitlesDirectoryResolver;
  final SubtitleAiEngine _aiEngine;
  late final Future<void> _settingsReady;
  SubtitleGenerationJob? _generationJob;

  SubtitleModelStore get modelStore => _aiEngine.modelStore;
  SubtitleGenerationJob? get generationJob => _generationJob;
  bool canEditSubtitle(String trackPath) =>
      _trackResolver(trackPath)?.isRemoteAsmr != true;

  bool startScriptGeneration(
    String trackPath,
    String scriptPath, {
    VoidCallback? onApplied,
  }) => _startGeneration(
    trackPath,
    SubtitleDraftKind.script,
    (onProgress, isCancelled, cancellation) => prepareScriptSubtitle(
      trackPath,
      scriptPath,
      onProgress: onProgress,
      isCancelled: isCancelled,
      cancellation: cancellation,
    ),
    onApplied,
  );

  bool startTranslationGeneration(
    String trackPath,
    String targetLanguage, {
    bool sourceJapaneseConfirmed = false,
    VoidCallback? onApplied,
  }) => _startGeneration(
    trackPath,
    SubtitleDraftKind.translation,
    (onProgress, isCancelled, cancellation) => prepareTranslation(
      trackPath,
      targetLanguage,
      sourceJapaneseConfirmed: sourceJapaneseConfirmed,
      onProgress: onProgress,
      isCancelled: isCancelled,
      cancellation: cancellation,
    ),
    onApplied,
  );

  bool _startGeneration(
    String trackPath,
    SubtitleDraftKind kind,
    Future<SubtitleDraft?> Function(
      void Function(SubtitleTaskProgress),
      bool Function(),
      Future<void>,
    )
    prepare,
    VoidCallback? onApplied,
  ) {
    final existing = _generationJob;
    if (existing?.status == SubtitleGenerationStatus.running) {
      return false;
    }
    final job = SubtitleGenerationJob(trackPath: trackPath, kind: kind);
    _generationJob = job;
    notifyListeners();
    unawaited(_runGeneration(job, prepare, onApplied));
    return true;
  }

  Future<void> _runGeneration(
    SubtitleGenerationJob job,
    Future<SubtitleDraft?> Function(
      void Function(SubtitleTaskProgress),
      bool Function(),
      Future<void>,
    )
    prepare,
    VoidCallback? onApplied,
  ) async {
    try {
      final draft = await prepare(
        (progress) {
          if (!identical(_generationJob, job) || job._cancelRequested) return;
          job._progress = progress;
          notifyListeners();
        },
        () => job._cancelRequested,
        job._cancellation.future,
      );
      if (job._cancelRequested) {
        job._status = SubtitleGenerationStatus.cancelled;
      } else if (draft == null || draft.cues.isEmpty) {
        job._status = SubtitleGenerationStatus.noMatch;
      } else {
        job._progress = const SubtitleTaskProgress('saving', 0, '');
        notifyListeners();
        await saveDraft(job.trackPath, draft);
        job._status = SubtitleGenerationStatus.completed;
        try {
          onApplied?.call();
        } catch (error, stackTrace) {
          AppLogService.warning(
            'subtitle_applied_but_enable_failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
    } on SubtitleTaskCancelled {
      job._status = SubtitleGenerationStatus.cancelled;
    } catch (error, stackTrace) {
      if (job._cancelRequested) {
        job._status = SubtitleGenerationStatus.cancelled;
      } else {
        job._errorMessage = error.toString();
        AppLogService.warning(
          'subtitle_generation_failed',
          error: error,
          stackTrace: stackTrace,
        );
        job._status = SubtitleGenerationStatus.failed;
      }
    } finally {
      if (identical(_generationJob, job)) notifyListeners();
    }
  }

  void cancelGeneration() {
    final job = _generationJob;
    if (job == null ||
        job.status != SubtitleGenerationStatus.running ||
        job.progress?.stage == 'saving') {
      return;
    }
    job._cancelRequested = true;
    if (!job._cancellation.isCompleted) job._cancellation.complete();
    notifyListeners();
  }

  void clearGenerationJob() {
    final job = _generationJob;
    if (job == null || job.status == SubtitleGenerationStatus.running) return;
    _generationJob = null;
    notifyListeners();
  }

  final Map<String, Future<SubtitleTrack?>> _loading =
      <String, Future<SubtitleTrack?>>{};
  final Map<String, SubtitleTrack?> _tracks = <String, SubtitleTrack?>{};
  final Map<String, Future<SubtitleTrack?>> _results =
      <String, Future<SubtitleTrack?>>{};
  final Map<String, Duration> _offsets = <String, Duration>{};
  final Map<String, String> _customPaths = <String, String>{};
  final Map<String, int> _trackRevisions = <String, int>{};
  int _generation = 0;

  bool hasResult(String trackPath) => _tracks.containsKey(trackPath);
  bool isLoading(String trackPath) => _loading.containsKey(trackPath);
  bool hasKnownSubtitle(String trackPath) {
    return _tracks[trackPath]?.cues.isNotEmpty == true ||
        _hasRemoteSubtitleUrl(_trackResolver(trackPath));
  }

  Duration getOffset(String trackPath) => _offsets[trackPath] ?? Duration.zero;

  String? getCustomSubtitlePath(String trackPath) => _customPaths[trackPath];

  SubtitleLanguage classifyCurrentSubtitle(String trackPath) {
    final track = _tracks[trackPath];
    if (track == null || track.cues.isEmpty) return SubtitleLanguage.unknown;
    return classifySubtitleLanguage(track.cues);
  }

  Future<bool> isTimedSubtitleFile(String filePath) async {
    final bytes = await _fileCacheGateway.readDocumentBytes(filePath);
    if (bytes == null) return false;
    final parsed = await parseSubtitleTrackFromRaw(
      sourcePath: filePath,
      raw: decodeWorkText(bytes).text,
      extension: path.extension(filePath).toLowerCase(),
    );
    return parsed != null && parsed.cues.isNotEmpty;
  }

  Future<SubtitleDraft?> prepareScriptSubtitle(
    String trackPath,
    String scriptPath, {
    void Function(SubtitleTaskProgress)? onProgress,
    bool Function()? isCancelled,
    Future<void>? cancellation,
  }) => _aiEngine.prepareScript(
    trackPath,
    scriptPath,
    onProgress: onProgress,
    isCancelled: isCancelled,
    cancellation: cancellation,
  );

  Future<SubtitleDraft> prepareTranslation(
    String trackPath,
    String targetLanguage, {
    bool sourceJapaneseConfirmed = false,
    void Function(SubtitleTaskProgress)? onProgress,
    bool Function()? isCancelled,
    Future<void>? cancellation,
  }) async {
    final source = await japaneseSourceCues(
      trackPath,
      sourceJapaneseConfirmed: sourceJapaneseConfirmed,
    );
    return _aiEngine.prepareTranslation(
      source,
      targetLanguage,
      trackPath: trackPath,
      onProgress: onProgress,
      isCancelled: isCancelled,
      cancellation: cancellation,
    );
  }

  Future<List<SubtitleCue>> japaneseSourceCues(
    String trackPath, {
    bool sourceJapaneseConfirmed = false,
  }) async {
    final track = _tracks[trackPath] ?? await load(trackPath);
    if (track == null || track.cues.isEmpty) {
      throw StateError('No subtitles to translate');
    }
    final language = classifyCurrentSubtitle(trackPath);
    if (language == SubtitleLanguage.other ||
        (language == SubtitleLanguage.unknown && !sourceJapaneseConfirmed)) {
      throw StateError('Subtitle source is not Japanese');
    }
    return track.cues
        .map(
          (cue) => SubtitleCue(
            start: cue.start,
            end: cue.end,
            text: cue.text.split('\n').first,
          ),
        )
        .toList(growable: false);
  }

  Future<SubtitleTrack> saveDraft(String trackPath, SubtitleDraft draft) async {
    await _settingsReady;
    _validateCues(trackPath, draft.cues);
    final dest = draft.kind == SubtitleDraftKind.script
        ? await _scriptSubtitleFile(trackPath)
        : File(
            path.join(
              (await _subtitlesDirectoryResolver()).path,
              '${md5.convert(utf8.encode(trackPath))}-translation.srt',
            ),
          );
    if (draft.kind == SubtitleDraftKind.script) {
      await _writeLrc(dest, draft.cues);
      await _writeSafScript(trackPath, dest);
    } else {
      await _writeSrt(dest, draft.cues);
    }
    final savedFromFile = await _loadFromFile(dest.path);
    if (savedFromFile == null || savedFromFile.cues.isEmpty) {
      throw StateError('Generated subtitle file could not be read');
    }
    _customPaths[trackPath] = dest.path;
    await _persistCustomPaths(throwOnFailure: true);
    _trackRevisions[trackPath] = (_trackRevisions[trackPath] ?? 0) + 1;
    final saved = savedFromFile.withOffset(getOffset(trackPath));
    _tracks[trackPath] = saved;
    _results[trackPath] = SynchronousFuture<SubtitleTrack?>(saved);
    _trimResults();
    _onTrackLoaded?.call(trackPath, saved);
    notifyListeners();
    return saved;
  }

  Future<File> _scriptSubtitleFile(String trackPath) async {
    if (!trackPath.startsWith('content://') &&
        !trackPath.startsWith('http://') &&
        !trackPath.startsWith('https://') &&
        await File(trackPath).exists()) {
      return File(
        path.join(
          path.dirname(trackPath),
          '${path.basenameWithoutExtension(trackPath)}.lrc',
        ),
      );
    }
    final name =
        trackPath.startsWith('content://') ||
            trackPath.startsWith('http://') ||
            trackPath.startsWith('https://')
        ? Uri.parse(trackPath).pathSegments.last.split(':').last
        : path.basename(trackPath);
    final stem = path.basenameWithoutExtension(name);
    final root = await _subtitlesDirectoryResolver();
    final dir = Directory(
      path.join(root.path, md5.convert(utf8.encode(trackPath)).toString()),
    );
    await dir.create(recursive: true);
    return File(path.join(dir.path, '$stem.lrc'));
  }

  Future<void> _writeSafScript(String trackPath, File file) async {
    if (!trackPath.startsWith('content://')) return;
    final groupKey = _trackResolver(trackPath)?.groupKey;
    if (groupKey == null || !groupKey.startsWith('content://')) {
      throw StateError('Audio folder is unavailable for subtitle saving');
    }
    final saved = await _fileCacheGateway.writeTrackSubtitle(
      folder: groupKey,
      name:
          '${path.basenameWithoutExtension(Uri.parse(trackPath).pathSegments.last.split(':').last)}.lrc',
      bytes: await file.readAsBytes(),
    );
    if (!saved) throw StateError('Failed to save subtitle beside audio');
  }

  Future<void> setTrackOffset(String trackPath, Duration offset) async {
    if (offset == Duration.zero) {
      _offsets.remove(trackPath);
    } else {
      _offsets[trackPath] = offset;
    }
    unawaited(_persistOffsets());
    final currentTrack = _tracks[trackPath];
    if (currentTrack != null) {
      final updatedTrack = currentTrack.withOffset(offset);
      _tracks[trackPath] = updatedTrack;
      _results[trackPath] = SynchronousFuture<SubtitleTrack?>(updatedTrack);
      _onTrackLoaded?.call(trackPath, updatedTrack);
    }
    notifyListeners();
  }

  Future<SubtitleTrack?> importSubtitle(
    String trackPath,
    String filePath,
  ) async {
    await _settingsReady;
    final bytes = await _fileCacheGateway.readDocumentBytes(filePath);
    if (bytes == null) return null;
    final previousPath = _customPaths[trackPath];
    try {
      final extension = path.extension(filePath).toLowerCase();
      final dir = await _subtitlesDirectoryResolver();
      final safeKey = md5.convert(utf8.encode(trackPath)).toString();
      final destFile = File(
        path.join(
          dir.path,
          '$safeKey-import-${DateTime.now().microsecondsSinceEpoch}$extension',
        ),
      );
      await destFile.writeAsBytes(bytes, flush: true);
      final localTrack = await _loadFromFile(destFile.path);
      if (localTrack == null || localTrack.cues.isEmpty) {
        await destFile.delete();
        return null;
      }

      _customPaths[trackPath] = destFile.path;
      await _persistCustomPaths(throwOnFailure: true);

      _trackRevisions[trackPath] = (_trackRevisions[trackPath] ?? 0) + 1;
      final offset = getOffset(trackPath);
      final readyTrack = localTrack.withOffset(offset);
      _tracks[trackPath] = readyTrack;
      _results[trackPath] = SynchronousFuture<SubtitleTrack?>(readyTrack);
      _trimResults();
      _onTrackLoaded?.call(trackPath, readyTrack);
      notifyListeners();
      return readyTrack;
    } catch (error, stackTrace) {
      if (previousPath == null) {
        _customPaths.remove(trackPath);
      } else {
        _customPaths[trackPath] = previousPath;
      }
      AppLogService.warning(
        'import_subtitle_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<SubtitleTrack> saveEditedSubtitle(
    String trackPath,
    List<SubtitleCue> cues,
  ) async {
    if (!canEditSubtitle(trackPath)) {
      throw StateError('ASMR.ONE subtitles cannot be edited');
    }
    await _settingsReady;
    _validateCues(trackPath, cues, allowEmpty: true);

    final dir = await _subtitlesDirectoryResolver();
    final safeKey = md5.convert(utf8.encode(trackPath)).toString();
    final destFile = File(path.join(dir.path, '$safeKey-edited.srt'));
    await _writeSrt(destFile, cues);
    final savedFromFile = await _loadFromFile(destFile.path);
    if (savedFromFile == null) {
      throw StateError('Edited subtitle file could not be read');
    }
    final edited = savedFromFile.withOffset(getOffset(trackPath));
    _customPaths[trackPath] = destFile.path;
    await _persistCustomPaths();
    _trackRevisions[trackPath] = (_trackRevisions[trackPath] ?? 0) + 1;
    _tracks[trackPath] = edited;
    _results[trackPath] = SynchronousFuture<SubtitleTrack?>(edited);
    _trimResults();
    _onTrackLoaded?.call(trackPath, edited);
    notifyListeners();

    return edited;
  }

  static void _validateCues(
    String trackPath,
    List<SubtitleCue> cues, {
    bool allowEmpty = false,
  }) {
    if (trackPath.isEmpty || (cues.isEmpty && !allowEmpty)) {
      throw ArgumentError('A track and subtitle cues are required.');
    }
    for (var index = 0; index < cues.length; index++) {
      final cue = cues[index];
      if (cue.start < Duration.zero ||
          cue.end <= cue.start ||
          cue.text.trim().isEmpty ||
          (index > 0 && cue.start < cues[index - 1].end)) {
        throw ArgumentError(
          'Subtitle cues must be ordered and non-overlapping.',
        );
      }
    }
  }

  static Future<void> _writeSrt(File destFile, List<SubtitleCue> cues) async {
    final content = cues.indexed
        .map((entry) {
          final (index, cue) = entry;
          return '${index + 1}\n${_srtTime(cue.start)} --> ${_srtTime(cue.end)}\n${cue.text.trim()}';
        })
        .join('\n\n');
    await _writeSubtitleContent(destFile, '$content\n');
  }

  static Future<void> _writeLrc(File destFile, List<SubtitleCue> cues) async {
    final lines = <String>[];
    for (final cue in cues) {
      lines.add('[${_lrcTime(cue.start)}]${cue.text.trim()}');
      lines.add('[${_lrcTime(cue.end)}]');
    }
    await _writeSubtitleContent(destFile, '${lines.join('\n')}\n');
  }

  static String _lrcTime(Duration duration) {
    final milliseconds = duration.inMilliseconds;
    final minutes = milliseconds ~/ 60000;
    final seconds = (milliseconds ~/ 1000) % 60;
    final millis = milliseconds % 1000;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}';
  }

  static Future<void> _writeSubtitleContent(
    File destFile,
    String content,
  ) async {
    final tempFile = File('${destFile.path}.tmp');
    final backupFile = File('${destFile.path}.bak');
    await tempFile.writeAsString(content, flush: true);

    if (await backupFile.exists()) await backupFile.delete();
    if (await destFile.exists()) await destFile.rename(backupFile.path);
    try {
      await tempFile.rename(destFile.path);
      if (await backupFile.exists()) await backupFile.delete();
    } catch (_) {
      if (await backupFile.exists()) await backupFile.rename(destFile.path);
      rethrow;
    }
  }

  static String _srtTime(Duration duration) {
    final milliseconds = duration.inMilliseconds;
    final hours = milliseconds ~/ 3600000;
    final minutes = (milliseconds ~/ 60000) % 60;
    final seconds = (milliseconds ~/ 1000) % 60;
    final millis = milliseconds % 1000;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')},${millis.toString().padLeft(3, '0')}';
  }

  static Future<Directory> _defaultSubtitlesDirectory() async {
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory(path.join(supportDir.path, 'imported_subtitles'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _loadPersistedSettings() async {
    try {
      final rawOffsets = await AppPreferences.getStringList(
        'subtitle_track_offsets',
      );
      if (rawOffsets != null) {
        for (final item in rawOffsets) {
          final idx = item.lastIndexOf('|');
          if (idx > 0) {
            final trackKey = item.substring(0, idx);
            final ms = int.tryParse(item.substring(idx + 1));
            if (ms != null && trackKey.isNotEmpty) {
              _offsets.putIfAbsent(trackKey, () => Duration(milliseconds: ms));
            }
          }
        }
      }
      final rawCustom = await AppPreferences.getStringList(
        'subtitle_custom_paths',
      );
      if (rawCustom != null) {
        for (final item in rawCustom) {
          final idx = item.lastIndexOf('|');
          if (idx > 0) {
            final trackKey = item.substring(0, idx);
            final customPath = item.substring(idx + 1);
            if (trackKey.isNotEmpty && customPath.isNotEmpty) {
              _customPaths.putIfAbsent(trackKey, () => customPath);
            }
          }
        }
      }
    } catch (error, stack) {
      AppLogService.warning(
        'Failed to load persisted subtitle settings',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<void> _persistOffsets() async {
    final list = _offsets.entries
        .map((e) => '${e.key}|${e.value.inMilliseconds}')
        .toList(growable: false);
    await AppPreferences.setStringList('subtitle_track_offsets', list);
  }

  Future<void> _persistCustomPaths({bool throwOnFailure = false}) async {
    final list = _customPaths.entries
        .map((e) => '${e.key}|${e.value}')
        .toList(growable: false);
    final saved = await AppPreferences.setStringList(
      'subtitle_custom_paths',
      list,
    );
    if (!saved && throwOnFailure) {
      throw StateError('Failed to save subtitle file selection');
    }
  }

  Future<SubtitleTrack?> load(String trackPath) {
    if (_tracks.containsKey(trackPath)) {
      return _results.putIfAbsent(
        trackPath,
        () => SynchronousFuture<SubtitleTrack?>(_tracks[trackPath]),
      );
    }
    final existing = _loading[trackPath];
    if (existing != null) return existing;
    final requestGeneration = _generation;
    final requestRevision = _trackRevisions[trackPath] ?? 0;
    late final Future<SubtitleTrack?> task;
    task = () async {
      try {
        await _settingsReady;
        final track = _trackResolver(trackPath);
        final subtitleTrack =
            await (_subtitleLoader?.call(trackPath, track) ??
                _loadTrack(trackPath, track));
        if (requestRevision != (_trackRevisions[trackPath] ?? 0)) {
          return _tracks[trackPath];
        }
        if (requestGeneration != _generation ||
            !identical(_loading[trackPath], task)) {
          return subtitleTrack;
        }
        if (subtitleTrack != null || !_hasRemoteSubtitleUrl(track)) {
          _tracks[trackPath] = subtitleTrack;
          _results[trackPath] = SynchronousFuture<SubtitleTrack?>(
            subtitleTrack,
          );
          _trimResults();
        }
        _onTrackLoaded?.call(trackPath, subtitleTrack);
        notifyListeners();
        return subtitleTrack;
      } finally {
        if (identical(_loading[trackPath], task)) {
          unawaited(_loading.remove(trackPath));
        }
      }
    }();
    _loading[trackPath] = task;
    return task;
  }

  SubtitleTrack? trackSync(String trackPath) => _tracks[trackPath];

  String? textAt(
    String trackPath,
    Duration position, {
    SubtitleTrack? subtitleTrack,
    bool persistent = false,
  }) {
    final cue = (subtitleTrack ?? _tracks[trackPath])?.cueAt(
      position,
      persistent: persistent,
    );
    final text = cue?.text.trim();
    return text == null || text.isEmpty ? null : text;
  }

  void clear() {
    _generation++;
    _loading.clear();
    _trackRevisions.clear();
    _tracks.clear();
    _results.clear();
    notifyListeners();
  }

  Future<SubtitleTrack?> _loadTrack(String trackPath, MusicTrack? track) async {
    SubtitleTrack? loaded;
    final customPath = _customPaths[trackPath];
    if (customPath != null) {
      loaded = await _loadFromFile(customPath);
    }
    if (loaded == null) {
      if (trackPath.startsWith('content://')) {
        loaded = await _loadContentTrack(trackPath, track);
      } else if (track?.isRemoteAsmr == true && track != null) {
        loaded = await _loadAsmrTrack(track);
      } else {
        loaded = await loadSubtitleTrackForAudio(trackPath);
      }
    }
    if (loaded != null) {
      final offset = getOffset(trackPath);
      if (offset != Duration.zero) {
        loaded = loaded.withOffset(offset);
      }
    }
    return loaded;
  }

  Future<SubtitleTrack?> _loadFromFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    try {
      final bytes = await file.readAsBytes();
      final raw = decodeWorkText(bytes).text;
      if (raw.trim().isEmpty) {
        return SubtitleTrack(sourcePath: filePath, cues: const []);
      }
      final extension = path.extension(filePath).toLowerCase();
      return await parseSubtitleTrackFromRaw(
        sourcePath: filePath,
        raw: raw,
        extension: extension,
      );
    } catch (error, stackTrace) {
      AppLogService.warning(
        'custom_subtitle_file_load_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  bool _hasRemoteSubtitleUrl(MusicTrack? track) {
    if (track?.isRemoteAsmr != true) return false;
    return track?.remoteMetadata?['subtitleUrl']
            ?.toString()
            .trim()
            .isNotEmpty ==
        true;
  }

  void _trimResults() {
    if (_tracks.length <= 20) return;
    final oldestKey = _tracks.keys.first;
    _tracks.remove(oldestKey);
    unawaited(_results.remove(oldestKey));
  }

  Future<SubtitleTrack?> _loadContentTrack(
    String trackPath,
    MusicTrack? track,
  ) async {
    try {
      final raw = await _fileCacheGateway.resolveTrackSubtitle(
        path: trackPath,
        groupKey: track?.groupKey,
      );
      if (raw == null) return null;
      final text = raw['text']?.toString();
      final extension = raw['extension']?.toString();
      if (text == null ||
          text.isEmpty ||
          extension == null ||
          extension.isEmpty) {
        return null;
      }
      final dir = await _subtitlesDirectoryResolver();
      final safeKey = md5.convert(utf8.encode(trackPath)).toString();
      final localFile = File(
        path.join(
          dir.path,
          '$safeKey-content${extension.startsWith('.') ? extension : '.$extension'}',
        ),
      );
      await _writeSubtitleContent(localFile, text);
      return _loadFromFile(localFile.path);
    } on MissingPluginException {
      return null;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'content_subtitle_load_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<SubtitleTrack?> _loadAsmrTrack(MusicTrack track) async {
    final metadata = track.remoteMetadata;
    if (metadata == null) return null;
    final subtitleUrl = metadata['subtitleUrl']?.toString().trim() ?? '';
    if (subtitleUrl.isEmpty) return null;
    final subtitleExtension = _resolveAsmrSubtitleExtension(
      metadata['subtitleExtension']?.toString().trim(),
      subtitleUrl: subtitleUrl,
      subtitleSourcePath: metadata['subtitleSourcePath']?.toString(),
      subtitleTitle: metadata['subtitleTitle']?.toString(),
    );
    try {
      final dir = await _subtitlesDirectoryResolver();
      final safeKey = md5.convert(utf8.encode(track.path)).toString();
      final localFile = File(
        path.join(
          dir.path,
          '$safeKey-remote${subtitleExtension.isEmpty ? '.txt' : subtitleExtension}',
        ),
      );
      final cached = await _loadFromFile(localFile.path);
      if (cached != null) return cached;
      final bytes = await WorkTextService(platformGateway: _fileCacheGateway)
          .readDocumentBytes(
            WorkTextFile(
              name: metadata['subtitleTitle']?.toString() ?? 'subtitle',
              relativePath: metadata['subtitleSourcePath']?.toString() ?? '',
              path: subtitleUrl,
            ),
          );
      if (bytes == null || bytes.isEmpty) return null;
      await _writeSubtitleContent(localFile, decodeWorkText(bytes).text);
      return _loadFromFile(localFile.path);
    } catch (error, stackTrace) {
      AppLogService.warning(
        'asmr_subtitle_load_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  String _resolveAsmrSubtitleExtension(
    String? metadataExtension, {
    required String subtitleUrl,
    String? subtitleSourcePath,
    String? subtitleTitle,
  }) {
    final normalized = _normalizedSubtitleExtension(metadataExtension ?? '');
    if (normalized.isNotEmpty) return normalized;
    for (final candidate in <String?>[
      subtitleSourcePath,
      subtitleTitle,
      subtitleUrl,
    ]) {
      final resolved = _normalizedSubtitleExtension(
        _subtitleExtensionFromCandidate(candidate),
      );
      if (resolved.isNotEmpty) return resolved;
    }
    return '';
  }

  String _normalizedSubtitleExtension(String extension) {
    final trimmed = extension.trim().toLowerCase();
    if (trimmed.isEmpty) return '';
    return trimmed.startsWith('.') ? trimmed : '.$trimmed';
  }

  String _subtitleExtensionFromCandidate(String? candidate) {
    if (candidate == null) return '';
    final trimmed = candidate.trim();
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(trimmed);
    final sourcePath = uri != null && uri.hasScheme ? uri.path : trimmed;
    return path.extension(sourcePath);
  }
}
