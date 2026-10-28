import 'dart:async';

import '../../../core/media/audio_detail.dart';
import '../../../core/media/music_track.dart';
import '../../../core/logging/app_log_service.dart';
import '../domain/listening_activity.dart';
import '../domain/playback_usage.dart';

typedef ListeningInterestRecorder =
    Future<void> Function({
      required String batchId,
      required List<({List<String> tags, Duration duration})> contributions,
    });

/// Imports durable player batches before acknowledging them at their source.
final class ListeningActivityService {
  ListeningActivityService({
    required ListeningActivityRepository repository,
    required Future<List<PlaybackUsageBatch>> Function() readUsage,
    required Future<void> Function(List<String>) acknowledgeUsage,
    required FutureOr<MusicTrack?> Function(String) resolveTrack,
    required ListeningInterestRecorder recordInterests,
    ListeningInterestRecorder? recordVoiceActorInterests,
    ListeningInterestRecorder? recordCircleInterests,
    Future<AudioDetail> Function(MusicTrack)? resolveLocalAudioDetail,
    DateTime Function()? now,
  }) : _repository = repository,
       _readUsage = readUsage,
       _acknowledgeUsage = acknowledgeUsage,
       _resolveTrack = resolveTrack,
       _recordInterests = recordInterests,
       _recordVoiceActorInterests = recordVoiceActorInterests,
       _recordCircleInterests = recordCircleInterests,
       _resolveLocalAudioDetail = resolveLocalAudioDetail,
       _now = now ?? DateTime.now;

  final ListeningActivityRepository _repository;
  final Future<List<PlaybackUsageBatch>> Function() _readUsage;
  final Future<void> Function(List<String>) _acknowledgeUsage;
  final FutureOr<MusicTrack?> Function(String) _resolveTrack;
  final ListeningInterestRecorder _recordInterests;
  final ListeningInterestRecorder? _recordVoiceActorInterests;
  final ListeningInterestRecorder? _recordCircleInterests;
  final Future<AudioDetail> Function(MusicTrack)? _resolveLocalAudioDetail;
  final DateTime Function() _now;
  final _changes = StreamController<ListeningActivityView>.broadcast();
  ListeningActivityView? _view;
  Future<void> _tail = Future.value();
  Timer? _timer;
  bool _disposed = false;
  Future<void>? _disposeFuture;
  Future<void>? _startFuture;
  bool _needsReload = true;
  DateTime? _loadedDay;
  int _historyLimit = 40;

  Stream<ListeningActivityView> get states => Stream.multi((events) {
    final subscription = _changes.stream.listen(
      events.addSync,
      onError: events.addErrorSync,
    );
    final view = _view;
    if (view != null) events.addSync(view);
    events.onCancel = subscription.cancel;
  }, isBroadcast: true);

  Future<void> _serialize(Future<void> Function() action) {
    if (_disposeFuture != null) return Future<void>.value();
    final task = _tail.then((_) async {
      if (_disposed) return;
      try {
        await action();
      } catch (error, stack) {
        _changes.addError(error, stack);
        rethrow;
      }
    });
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  Future<void> start() {
    if (_disposeFuture != null || _timer != null) return Future<void>.value();
    return _startFuture ??= _start().whenComplete(() => _startFuture = null);
  }

  Future<void> _start() async {
    try {
      await refresh();
    } catch (error, stack) {
      AppLogService.error(
        'listening_activity_import_failed',
        error: error,
        stackTrace: stack,
      );
    }
    if (_disposeFuture != null) return;
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(
        refresh(forceReload: false).catchError((
          Object error,
          StackTrace stack,
        ) {
          AppLogService.error(
            'listening_activity_import_failed',
            error: error,
            stackTrace: stack,
          );
        }),
      );
    });
  }

  Future<void> refresh({bool forceReload = true}) => _serialize(() async {
    // Explicit refreshes also observe changes outside the usage importer.
    // Polling retains the snapshot until a successful import changes its data.
    // The chart's date window must also advance when an idle page crosses midnight.
    if (forceReload || _loadedDay != _today()) _needsReload = true;
    final batches = await _readUsage();
    final localDetails = <String, AudioDetail>{};
    for (final batch in batches) {
      final days = <ListeningDayContribution>[];
      final interests = <({List<String> tags, Duration duration})>[];
      final voiceInterests = <({List<String> tags, Duration duration})>[];
      final circleInterests = <({List<String> tags, Duration duration})>[];
      for (final day in batch.days) {
        final works = <ListeningWorkContribution>[];
        for (final work in day.works) {
          final track = await _resolveUsageTrack(work);
          works.add(
            ListeningWorkContribution(
              workKey: work.key,
              track: track,
              milliseconds: work.milliseconds,
              lastPlayedAtMs: work.lastPlayedAtMs,
            ),
          );
          AudioDetail? detail;
          final resolveLocalAudioDetail = _resolveLocalAudioDetail;
          if (!track.isRemoteAsmr && resolveLocalAudioDetail != null) {
            detail =
                localDetails[track.path] ??
                await resolveLocalAudioDetail(track);
            localDetails[track.path] = detail;
          }
          final tags = <String>{
            ...track.tags,
            ..._metadataTags(track.remoteMetadata?['tags']),
            ...?detail?.tags,
          }.toList();
          if (tags.isNotEmpty) {
            interests.add((
              tags: tags,
              duration: Duration(milliseconds: work.milliseconds),
            ));
          }
          final voiceActors = <String>{
            ..._metadataTags(track.remoteMetadata?['voiceActors']),
            ..._metadataTags(track.remoteMetadata?['vas']),
            ...?detail?.voiceActors,
          }.toList();
          if (voiceActors.isNotEmpty) {
            voiceInterests.add((
              tags: voiceActors,
              duration: Duration(milliseconds: work.milliseconds),
            ));
          }
          final circles = <String>{
            track.remoteCircleName,
            if (detail != null) detail.circleName.trim(),
          }..remove('');
          if (circles.isNotEmpty) {
            circleInterests.add((
              tags: circles.toList(),
              duration: Duration(milliseconds: work.milliseconds),
            ));
          }
        }
        days.add(
          ListeningDayContribution(
            date: day.date,
            totalMs: day.totalMs,
            works: works,
          ),
        );
      }
      if (await _repository.importBatch(batch.id, days)) _needsReload = true;
      // Retry the complete batch if either the preference write or native ack
      // failed. Both database and interest imports are independently idempotent.
      await _recordInterests(batchId: batch.id, contributions: interests);
      await _recordVoiceActorInterests?.call(
        batchId: batch.id,
        contributions: voiceInterests,
      );
      await _recordCircleInterests?.call(
        batchId: batch.id,
        contributions: circleInterests,
      );
      await _acknowledgeUsage([batch.id]);
    }
    if (_needsReload) await _reload();
  });

  Future<void> loadMoreHistory() => _serialize(() async {
    _historyLimit += 40;
    _needsReload = true;
    await _reload();
  });

  Future<void> seedHistory(List<ListeningHistoryEntry> entries) =>
      _serialize(() async {
        _needsReload = true;
        await _repository.seedHistory(entries);
        await _reload();
      });

  Future<void> _reload() async {
    final days = await _repository.loadDays();
    final history = await _repository.loadHistory(limit: _historyLimit + 1);
    final view = ListeningActivityView(
      days: List.unmodifiable(days),
      history: List.unmodifiable(history.take(_historyLimit)),
      hasMoreHistory: history.length > _historyLimit,
    );
    _view = view;
    _loadedDay = _today();
    _needsReload = false;
    _changes.add(view);
  }

  DateTime _today() {
    final now = _now();
    return DateTime(now.year, now.month, now.day);
  }

  Future<MusicTrack> _resolveUsageTrack(PlaybackUsageWork work) async {
    final path = work.path ?? work.uri ?? work.key;
    final live = await _resolveTrack(path);
    final descriptor = work.descriptor;
    if (descriptor != null) {
      final recorded = MusicTrack.fromJson(
        Map<String, dynamic>.from(descriptor),
      );
      // Native batches describe what was heard. Startup catalog projections can
      // omit these fields; keep their current name/path without losing metadata.
      return (live ?? recorded).copyWith(
        tags: recorded.tags.isNotEmpty ? recorded.tags : live?.tags,
        remoteMetadataKind:
            recorded.remoteMetadataKind ?? live?.remoteMetadataKind,
        remoteMetadata: recorded.remoteMetadata == null
            ? live?.remoteMetadata
            : {...?live?.remoteMetadata, ...recorded.remoteMetadata!},
      );
    }
    if (live != null) return live;
    final previous = await _repository.findTrack(work.key);
    if (previous != null) return previous;
    return MusicTrack(
      path: path,
      displayName: work.title ?? path,
      groupKey: work.key,
      groupTitle: work.subtitle ?? work.title ?? path,
      groupSubtitle: AudioDetail.findRjCodeInText(work.key) ?? '',
      isSingle: false,
      remoteCoverUrl: work.artUri,
    );
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _timer?.cancel();
    await _tail;
    _disposed = true;
    await _changes.close();
  }
}

Iterable<String> _metadataTags(Object? value) sync* {
  if (value is! List) return;
  for (final tag in value) {
    if (tag is String) yield tag;
    if (tag is Map && tag['name'] is String) yield tag['name'] as String;
  }
}
