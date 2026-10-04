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
    SubtitleAiEngine? aiEngine,
    DateTime Function()? now,
  }) : _trackResolver = trackResolver,
       _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _onTrackLoaded = onTrackLoaded,
       _subtitleLoader = subtitleLoader,
       _subtitlesDirectoryResolver =
           subtitlesDirectoryResolver ?? _defaultSubtitlesDirectory,
       _aiEngine = aiEngine ?? SubtitleAiEngine(),
       _now = now ?? DateTime.now {
    if (initialOffsets != null) _offsets.addAll(initialOffsets);
    _settingsReady = _loadPersistedSettings();
  }

  final PlaybackTrackResolver _trackResolver;
  final FileCachePlatformGateway _fileCacheGateway;
  final void Function(String trackPath, SubtitleTrack? track)? _onTrackLoaded;
  final PlaybackSubtitleLoader? _subtitleLoader;
  final Future<Directory> Function() _subtitlesDirectoryResolver;
  final SubtitleAiEngine _aiEngine;
  final DateTime Function() _now;
  static const _automaticRetryInterval = Duration(seconds: 30);
  final Map<
    String,
    ({(String?, String?, String?, String?, String?) source, DateTime retryAt})
  >
  _automaticRetries = {};
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

  bool _isRemote(String trackPath) =>
      trackPath.startsWith('https://') || trackPath.startsWith('http://');

  Future<bool> hasLocalSubtitleFile(String trackPath) async {
    await _settingsReady;
    if (_isRemote(trackPath)) {
      return _customPaths.containsKey(trackPath) || _tracks[trackPath] != null;
    }
    if (trackPath.startsWith('content://')) {
      return await _fileCacheGateway.resolveTrackSubtitle(
            path: trackPath,
            groupKey: _trackResolver(trackPath)?.groupKey,
          ) !=
          null;
    }
    return await findSubtitleFileForAudio(trackPath) != null;
  }

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
    final extension = draft.kind == SubtitleDraftKind.script ? '.lrc' : '.srt';
    final content = draft.kind == SubtitleDraftKind.script
        ? _lrcContent(draft.cues)
        : _srtContent(draft.cues);
    String? savedPath;
    if (_isRemote(trackPath)) {
      final dest = await _remoteSubtitleFile(trackPath, extension);
      await _writeSubtitleContent(dest, content);
      savedPath = dest.path;
      _customPaths[trackPath] = savedPath;
      await _persistCustomPaths(throwOnFailure: true);
    } else {
      savedPath = await _fileCacheGateway.saveTrackSubtitle(
        trackPath: trackPath,
        groupKey: _trackResolver(trackPath)?.groupKey,
        extension: extension,
        bytes: Uint8List.fromList(utf8.encode(content)),
        overwrite: true,
      );
    }
    if (savedPath == null) {
      throw StateError('Failed to save subtitle beside audio');
    }
    final savedFromFile = await _loadFromFile(savedPath);
    if (savedFromFile == null || savedFromFile.cues.isEmpty) {
      throw StateError('Generated subtitle file could not be read');
    }
    return _applySubtitle(trackPath, savedFromFile);
  }

  Future<File> _remoteSubtitleFile(String trackPath, String extension) async {
    final name = Uri.parse(trackPath).pathSegments.last;
    final stem = path.basenameWithoutExtension(name);
    final root = await _subtitlesDirectoryResolver();
    final dir = Directory(
      path.join(root.path, md5.convert(utf8.encode(trackPath)).toString()),
    );
    await dir.create(recursive: true);
    return File(path.join(dir.path, '$stem$extension'));
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
    String filePath, {
    String? fileName,
    bool overwrite = false,
  }) async {
    await _settingsReady;
    final bytes = await _fileCacheGateway.readDocumentBytes(filePath);
    if (bytes == null) return null;
    final previousPath = _customPaths[trackPath];
    try {
      final extension = path.extension(fileName ?? filePath).toLowerCase();
      final parsed = await parseSubtitleTrackFromRaw(
        sourcePath: filePath,
        raw: decodeWorkText(bytes).text,
        extension: extension,
      );
      if (parsed == null || parsed.cues.isEmpty) return null;
      String? savedPath;
      if (_isRemote(trackPath)) {
        if (previousPath != null && !overwrite) return null;
        final dest = await _remoteSubtitleFile(trackPath, extension);
        await dest.writeAsBytes(bytes, flush: true);
        if (filePath.startsWith('content://')) {
          if (!await _fileCacheGateway.deleteDocumentPath(filePath)) {
            throw StateError('Failed to move subtitle source');
          }
        } else if (!path.equals(
          path.absolute(filePath),
          path.absolute(dest.path),
        )) {
          await File(filePath).delete();
        }
        savedPath = dest.path;
        _customPaths[trackPath] = savedPath;
        await _persistCustomPaths(throwOnFailure: true);
      } else {
        savedPath = await _fileCacheGateway.saveTrackSubtitle(
          trackPath: trackPath,
          groupKey: _trackResolver(trackPath)?.groupKey,
          extension: extension,
          bytes: bytes,
          sourcePath: filePath,
          overwrite: overwrite,
        );
      }
      if (savedPath == null) return null;
      final saved = await _loadFromFile(savedPath);
      if (saved == null) {
        throw StateError('Imported subtitle could not be read');
      }
      return _applySubtitle(trackPath, saved);
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

    final current = await load(trackPath);
    if (current == null) throw StateError('No subtitle file to edit');
    final sourcePath = current.sourcePath;
    final bytes = await _fileCacheGateway.readDocumentBytes(sourcePath);
    if (bytes == null) throw StateError('Subtitle file is unavailable');
    final content = _editedSubtitleContent(
      sourcePath,
      decodeWorkText(bytes).text,
      cues,
    );
    if (cues.isNotEmpty) {
      final parsed = await parseSubtitleTrackFromRaw(
        sourcePath: sourcePath,
        raw: content,
        extension: path.extension(sourcePath),
      );
      if (parsed == null || parsed.cues.length != cues.length) {
        throw StateError('Edited cues cannot be stored in the subtitle format');
      }
    }
    if (sourcePath.startsWith('content://')) {
      final saved = await _fileCacheGateway.writeTrackSubtitle(
        path: sourcePath,
        bytes: Uint8List.fromList(utf8.encode(content)),
      );
      if (!saved) throw StateError('Failed to write subtitle file');
    } else {
      final file = File(sourcePath);
      await _writeSubtitleContent(file, content);
    }
    final savedFromFile = await _loadFromFile(sourcePath);
    if (savedFromFile == null) {
      throw StateError('Edited subtitle file could not be read');
    }
    return _applySubtitle(trackPath, savedFromFile);
  }

  SubtitleTrack _applySubtitle(String trackPath, SubtitleTrack subtitle) {
    _automaticRetries.remove(trackPath);
    final edited = subtitle.withOffset(getOffset(trackPath));
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

  static String _srtContent(List<SubtitleCue> cues, {bool webVtt = false}) {
    final content = cues.indexed
        .map((entry) {
          final (index, cue) = entry;
          final start = _srtTime(cue.start);
          final end = _srtTime(cue.end);
          final timing = webVtt
              ? '${start.replaceAll(',', '.')} --> ${end.replaceAll(',', '.')}'
              : '$start --> $end';
          return '${index + 1}\n$timing\n${cue.text.trim()}';
        })
        .join('\n\n');
    return '${webVtt ? 'WEBVTT\n\n' : ''}$content\n';
  }

  static String _lrcContent(List<SubtitleCue> cues) {
    final lines = <String>[];
    for (final cue in cues) {
      for (final line in cue.text.trim().split('\n')) {
        lines.add('[${_lrcTime(cue.start)}]$line');
      }
      lines.add('[${_lrcTime(cue.end)}]');
    }
    return '${lines.join('\n')}\n';
  }

  static String _editedSubtitleContent(
    String sourcePath,
    String original,
    List<SubtitleCue> cues,
  ) {
    if (cues.isEmpty) return '\n';
    var extension = path.extension(sourcePath).toLowerCase();
    if (!const {
      '.srt',
      '.lrc',
      '.vtt',
      '.webvtt',
      '.ass',
      '.ssa',
    }.contains(extension)) {
      final raw = original.trimLeft().replaceFirst('\uFEFF', '');
      if (raw.startsWith('WEBVTT')) {
        extension = '.vtt';
      } else if (RegExp(
        r'^\[events\]',
        caseSensitive: false,
        multiLine: true,
      ).hasMatch(raw)) {
        extension = '.ass';
      } else if (RegExp(r'\[\d+:\d{1,2}(?:[.:]\d{1,3})?\]').hasMatch(raw)) {
        extension = '.lrc';
      } else {
        extension = '.srt';
      }
    }
    return switch (extension) {
      '.lrc' => _lrcContent(cues),
      '.vtt' || '.webvtt' => _srtContent(cues, webVtt: true),
      '.srt' => _srtContent(cues),
      '.ass' || '.ssa' => _assContent(original, cues),
      _ => throw StateError('Unsupported subtitle format: $extension'),
    };
  }

  static String _assContent(String original, List<SubtitleCue> cues) {
    final lines = original.replaceAll('\r\n', '\n').split('\n');
    var inEvents = false;
    List<String>? columns;
    final templates = <List<String>>[];
    final kept = <String>[];
    var insertionIndex = -1;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('[')) {
        inEvents = trimmed.toLowerCase() == '[events]';
      }
      if (inEvents && trimmed.toLowerCase().startsWith('format:')) {
        columns = trimmed
            .substring(7)
            .split(',')
            .map((column) => column.trim().toLowerCase())
            .toList();
        insertionIndex = kept.length + 1;
      }
      if (inEvents && trimmed.toLowerCase().startsWith('dialogue:')) {
        final count = columns?.length;
        if (count == null) throw StateError('Missing ASS event format');
        final fields = trimmed.substring(9).split(',');
        if (fields.length < count) throw StateError('Invalid ASS dialogue');
        templates.add([
          ...fields.take(count - 1),
          fields.skip(count - 1).join(','),
        ]);
      } else {
        kept.add(line);
      }
    }
    if (columns == null ||
        insertionIndex < 0 ||
        templates.isEmpty ||
        columns.last != 'text' ||
        !columns.contains('start') ||
        !columns.contains('end')) {
      throw StateError('Unsupported ASS event format');
    }
    final dialogue = <String>[];
    for (var index = 0; index < cues.length; index++) {
      final cue = cues[index];
      final values = List<String>.of(
        templates[index < templates.length ? index : templates.length - 1],
      );
      values[columns.indexOf('start')] = _assTime(cue.start);
      values[columns.indexOf('end')] = _assTime(cue.end);
      values[columns.indexOf('text')] = cue.text.trim().replaceAll('\n', r'\N');
      dialogue.add('Dialogue: ${values.join(',')}');
    }
    kept.insertAll(insertionIndex, dialogue);
    return '${kept.join('\n').trimRight()}\n';
  }

  static String _assTime(Duration duration) {
    final time = _srtTime(duration).replaceAll(',', '.');
    return time.substring(0, time.length - 1);
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
            if (_isRemote(trackKey) && customPath.isNotEmpty) {
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

  Future<SubtitleTrack?> loadAutomatically(String trackPath) =>
      _load(trackPath, automatic: true);

  Future<SubtitleTrack?> load(String trackPath) =>
      _load(trackPath, automatic: false);

  Future<SubtitleTrack?> _load(String trackPath, {required bool automatic}) {
    if (_tracks.containsKey(trackPath)) {
      return _results.putIfAbsent(
        trackPath,
        () => SynchronousFuture<SubtitleTrack?>(_tracks[trackPath]),
      );
    }
    final existing = _loading[trackPath];
    if (existing != null) return existing;
    final source = _subtitleSource(trackPath);
    final retry = _automaticRetries[trackPath];
    if (automatic &&
        retry != null &&
        retry.source == source &&
        _now().isBefore(retry.retryAt)) {
      return SynchronousFuture<SubtitleTrack?>(null);
    }
    _automaticRetries.remove(trackPath);
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
        } else {
          // Progress-driven consumers may revisit a failed URL every tick.
          // Explicit loads bypass this temporary cooldown.
          _automaticRetries[trackPath] = (
            source: source,
            retryAt: _now().add(_automaticRetryInterval),
          );
          if (_automaticRetries.length > 20) {
            _automaticRetries.remove(_automaticRetries.keys.first);
          }
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

  (String?, String?, String?, String?, String?) _subtitleSource(
    String trackPath,
  ) {
    final metadata = _trackResolver(trackPath)?.remoteMetadata;
    return (
      metadata?['subtitleUrl']?.toString(),
      metadata?['subtitleExtension']?.toString(),
      metadata?['subtitleSourcePath']?.toString(),
      metadata?['subtitleTitle']?.toString(),
      _customPaths[trackPath],
    );
  }

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
    _automaticRetries.clear();
    notifyListeners();
  }

  Future<SubtitleTrack?> _loadTrack(String trackPath, MusicTrack? track) async {
    SubtitleTrack? loaded;
    final customPath = _isRemote(trackPath) ? _customPaths[trackPath] : null;
    if (customPath != null) {
      loaded = await _loadFromFile(customPath);
    }
    if (loaded == null) {
      if (trackPath.startsWith('content://')) {
        loaded = await _loadContentTrack(trackPath, track);
      } else if (track?.isRemoteAsmr == true && track != null) {
        loaded = await _loadAsmrTrack(track);
      } else {
        final file = await findSubtitleFileForAudio(trackPath);
        if (file != null) loaded = await _loadFromFile(file.path);
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
    try {
      final bytes = await _fileCacheGateway.readDocumentBytes(filePath);
      if (bytes == null) return null;
      final raw = decodeWorkText(bytes).text;
      if (raw.trim().isEmpty || raw.trim() == 'WEBVTT') {
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
      final sourcePath = raw['sourcePath']?.toString();
      if (text == null ||
          sourcePath == null ||
          sourcePath.isEmpty ||
          extension == null ||
          extension.isEmpty) {
        return null;
      }
      if (text.trim().isEmpty) {
        return SubtitleTrack(sourcePath: sourcePath, cues: const []);
      }
      return parseSubtitleTrackFromRaw(
        sourcePath: sourcePath,
        raw: text,
        extension: extension,
      );
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
