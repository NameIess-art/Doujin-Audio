part of 'windows_playback_bridge.dart';

class _WindowsPlaybackSession {
  _WindowsPlaybackSession(this.id, this.readNativePlaylist);
  final String id;
  final Future<String> Function(Player)? readNativePlaylist;
  Player? player;
  VideoController? videoController;
  final subscriptions = <StreamSubscription<dynamic>>[];
  Future<void> serial = Future.value();
  bool retired = false, eventPending = false;
  bool stopAfterCurrentTrack = false, nativeQueueLimited = false;
  final nativeQueueIndices = <int, int>{};
  Object? lastEventKey;
  int queueRevision = 0, externalQueueRevision = 0, emittedQueueRevision = -1;
  Duration? lastProgressPosition;
  Duration? duration;

  Future<T> enqueue<T>(Future<T> Function() action) {
    final result = serial.then((_) => action());
    serial = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  List<Map<String, Object?>> _queue = [];
  List<String>? _cachedRetainedUris;

  List<Map<String, Object?>> get queue => _queue;
  set queue(List<Map<String, Object?>> items) {
    var retainedChanged = items.length != _queue.length;
    if (!retainedChanged) {
      for (var i = 0; i < items.length; i++) {
        if (items[i]['uri'] != _queue[i]['uri']) {
          retainedChanged = true;
          break;
        }
      }
    }
    _queue = items;
    if (retainedChanged) invalidateRetainedUris();
  }

  void invalidateRetainedUris() {
    _cachedRetainedUris = null;
    queueRevision++;
  }

  int index = 0;
  Duration position = Duration.zero;
  Duration? pendingStart;
  double volume = 1, speed = 1, fade = 1;
  double? temporarySpeed;
  bool repeatOne = false,
      repeatAll = false,
      shuffle = false,
      wantsPlay = false,
      completed = false,
      opening = false;
  NativeAudioEffects effects = NativeAudioEffects(
    state: AudioEffectsState.flat,
    channelSwapEnabled: false,
  );
  String? error;
  bool hasRetainedCurrent = false;
  int commandId = 0, retryAttempt = 0, generation = 0, retryGeneration = 0;
  Timer? retryTimer;
  Duration? retryStartedAt;

  void cancelRetry() {
    retryGeneration++;
    retryTimer?.cancel();
  }

  NativePlaybackSnapshot snapshot({bool includeRetainedUris = true}) {
    final item = queue[index];
    final state = player?.state;
    return NativePlaybackSnapshot(
      sessionId: id,
      uri: item['uri'] as String?,
      path: item['path'] as String?,
      title: item['title'] as String?,
      subtitle: item['subtitle'] as String?,
      artUri: item['artUri'] as String?,
      playing: state?.playing == true && !opening && error == null,
      playWhenReady: wantsPlay,
      processingState: opening || pendingStart != null
          ? 'loading'
          : state == null
          ? completed
                ? 'completed'
                : 'idle'
          : state.completed
          ? 'completed'
          : state.buffering
          ? 'buffering'
          : 'ready',
      position: position,
      bufferedPosition: state?.buffer ?? Duration.zero,
      duration: state?.duration ?? duration,
      volume: volume,
      speed: speed,
      boostGain: volume > 1 ? volume : 1,
      channelSwapEnabled: effects.channelSwapEnabled,
      audioEffects: effects.state,
      eqCapabilities: windowsEqCapabilities,
      error: error,
      queueIndex: index,
      retainedUris: includeRetainedUris
          ? (_cachedRetainedUris ??= immutableList(
              queue.map((i) => i['uri'] as String),
            ))
          : const [],
      hasRetainedUrisPayload: includeRetainedUris,
      transportCommandId: commandId,
      stopAfterCurrentTrack: stopAfterCurrentTrack,
    );
  }

  static String _queueKey(Map<String, Object?> item) =>
      (item['path'] ?? item['uri']) as String;

  Future<List<int>> nativeEntryIds(Player player) async {
    final platform = player.platform;
    if (readNativePlaylist == null && platform is! NativePlayer) {
      return player.state.playlist.medias.map(identityHashCode).toList();
    }
    // mpv FORMAT_STRING prints NODE properties as JSON. The physical order and
    // stable entry IDs remain distinct even when multiple entries share a URI.
    final raw = readNativePlaylist != null
        ? await readNativePlaylist!(player)
        : await (platform as NativePlayer).getProperty('playlist');
    final entries = jsonDecode(raw);
    if (entries is! List) throw FormatException('Invalid native playlist', raw);
    final ids = <int>[];
    final seen = <int>{};
    for (final entry in entries) {
      final id = entry is Map ? entry['id'] : null;
      if (id is! int || !seen.add(id)) {
        throw FormatException('Invalid native playlist entry ID', entry);
      }
      ids.add(id);
    }
    return ids;
  }

  Future<int?> currentNativeEntryId(Player player) async {
    final platform = player.platform;
    if (platform is NativePlayer) {
      final index = int.parse(
        await platform.getProperty('playlist-playing-pos'),
      );
      return index < 0
          ? null
          : int.parse(await platform.getProperty('playlist/$index/id'));
    }
    final playlist = player.state.playlist;
    return playlist.index < 0 || playlist.index >= playlist.medias.length
        ? null
        : identityHashCode(playlist.medias[playlist.index]);
  }

  Future<void> mapNativeEntries(Player player) async {
    final generation = this.generation;
    final ids = await nativeEntryIds(player);
    if (retired ||
        !identical(this.player, player) ||
        generation != this.generation) {
      return;
    }
    if (ids.isEmpty) throw StateError('Current native playlist is empty');
    nativeQueueIndices
      ..clear()
      ..addAll({
        for (var i = 0; i < ids.length; i++)
          ids[i]: nativeQueueLimited ? index : i,
      });
  }

  Future<void> updateQueue(
    List<Map<String, Object?>> queue, {
    int? queueStartIndex,
    required bool Function() isCurrent,
    bool restoreNativeQueue = false,
  }) async {
    final previousQueue = this.queue;
    final previous = previousQueue[this.index];
    final items = queue.map((item) => Map<String, Object?>.from(item)).toList();
    final previousKey = _queueKey(previous);
    var occurrence = previousQueue
        .take(this.index)
        .where((item) => _queueKey(item) == previousKey)
        .length;
    var index = -1;
    for (var i = 0; i < items.length; i++) {
      if (_queueKey(items[i]) == previousKey && occurrence-- == 0) {
        index = i;
        break;
      }
    }
    if (queueStartIndex != null &&
        _queueKey(items[queueStartIndex]) == previousKey) {
      index = queueStartIndex;
    }
    hasRetainedCurrent = index < 0;
    if (index < 0) {
      // Finish the removed current item with its existing decoder.
      items.insert(0, Map<String, Object?>.from(previous));
      index = 0;
    }
    final player = this.player;
    if (player != null && (!nativeQueueLimited || restoreNativeQueue)) {
      // mpv shuffles physical entries; their IDs remain stable even when URIs
      // repeat. Reconcile edits against that order without reopening the decoder.
      final ids = await nativeEntryIds(player);
      if (!isCurrent() || !identical(this.player, player)) return;
      final physicalQueue = [
        for (final id in ids) previousQueue[nativeQueueIndices[id]!],
      ];
      final currentToken = ids.indexWhere(
        (id) => nativeQueueIndices[id] == this.index,
      );
      if (currentToken < 0) throw StateError('Current native entry is missing');
      final order = List.generate(physicalQueue.length, (i) => i);
      final nativeItems = [...physicalQueue];
      opening = true;
      try {
        final available = <(String, Object?), List<int>>{};
        for (var i = 0; i < physicalQueue.length; i++) {
          if (i == currentToken) continue;
          available
              .putIfAbsent((
                _queueKey(physicalQueue[i]),
                physicalQueue[i]['uri'],
              ), () => [])
              .add(i);
        }
        final cursors = <(String, Object?), int>{};
        final desired = <int?>[];
        for (var i = 0; i < items.length; i++) {
          if (i == index) {
            desired.add(currentToken);
            continue;
          }
          final key = (_queueKey(items[i]), items[i]['uri']);
          final tokens = available[key];
          final cursor = cursors[key] ?? 0;
          if (tokens != null && cursor < tokens.length) {
            desired.add(tokens[cursor]);
            cursors[key] = cursor + 1;
          } else {
            desired.add(null);
          }
        }
        final retained = desired.whereType<int>().toSet();
        for (var i = order.length - 1; i >= 0; i--) {
          if (!retained.contains(order[i])) {
            await player.remove(i);
            if (!isCurrent()) return;
            order.removeAt(i);
            nativeItems.removeAt(i);
          }
        }
        var newToken = -1;
        for (var i = 0; i < desired.length; i++) {
          final token = desired[i];
          // Unchanged prefixes are common when appending or trimming a queue.
          // Searching them from the start makes those edits quadratic.
          var from = token == null
              ? -1
              : i < order.length && order[i] == token
              ? i
              : order.indexOf(token);
          if (from < 0) {
            await player.add(Media(items[i]['uri'] as String));
            if (!isCurrent()) return;
            from = order.length;
            order.add(newToken--);
            nativeItems.add(items[i]);
          }
          if (from != i) {
            await player.move(from, i);
            order.insert(i, order.removeAt(from));
            nativeItems.insert(i, nativeItems.removeAt(from));
          }
          if (!isCurrent()) return;
        }
        // The edited physical order now matches the requested logical order.
        nativeQueueLimited = false;
        await mapNativeEntries(player);
      } catch (_) {
        if (isCurrent() && !restoreNativeQueue) {
          // Earlier successful edits remain applied when a later command fails.
          this.queue = nativeItems;
          this.index = order.indexOf(currentToken);
          await mapNativeEntries(player);
        }
        rethrow;
      } finally {
        opening = false;
      }
    }
    this.queue = items;
    this.index = index;
    if (restoreNativeQueue) nativeQueueLimited = false;
    if (player != null &&
        pendingStart != null &&
        player.state.duration > Duration.zero) {
      final position = pendingStart!;
      final generation = this.generation;
      pendingStart = null;
      await player.seek(position);
      if (isCurrent() && generation == this.generation && wantsPlay) {
        await player.play();
      }
    }
  }

  Future<void> releasePlayer() async {
    cancelRetry();
    temporarySpeed = null;
    final current = player;
    if (current == null) return;
    if (current.state.duration > Duration.zero) {
      duration = current.state.duration;
    }
    player = null;
    nativeQueueIndices.clear();
    nativeQueueLimited = false;
    videoController = null;
    pendingStart = null;
    lastProgressPosition = null;
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    subscriptions.clear();
    await current.dispose();
  }
}
