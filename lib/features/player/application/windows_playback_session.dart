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
  int queueRevision = 0,
      externalQueueRevision = 0,
      emittedQueueRevision = -1,
      seekRevision = 0;
  Duration? lastProgressPosition;
  Duration? lastProgressElapsed;
  Duration? duration;

  Future<T> enqueue<T>(Future<T> Function() action) {
    final result = serial.then((_) => action());
    serial = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  List<Map<String, Object?>> _queue = [];
  List<String>? _cachedRetainedUris;
  Map<String, Object?>? _referenceItem;
  PlaybackMediaReference? _reference;

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
    // A network retry can replace the URI on the current queue item in place.
    _referenceItem = null;
    _reference = null;
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
  // A partially applied native edit can leave the retained decoder off index 0.
  int? retainedCurrentIndex;
  int commandId = 0, retryAttempt = 0, generation = 0, retryGeneration = 0;
  Timer? retryTimer;
  Duration? retryStartedAt;

  static PlaybackMediaReference referenceFor(Map<String, Object?> item) {
    final parsed = PlaybackMediaReference.parse(item['uri'] as String);
    return PlaybackMediaReference(
      streamUrl: parsed.streamUrl,
      startMs: (item['clipStartMs'] as num?)?.toInt() ?? parsed.startMs,
      endMs: (item['clipEndMs'] as num?)?.toInt() ?? parsed.endMs,
      httpHeaders:
          (item['httpHeaders'] as Map?)?.cast<String, String>() ??
          parsed.httpHeaders,
    );
  }

  static String _nativeMediaPath(String uri) {
    if (!Platform.isWindows || uri.isEmpty) return uri;
    if (uri.startsWith(r'\\?\') || uri.startsWith(r'\\')) return uri;
    final hasDrivePrefix =
        uri.length >= 2 &&
        uri[1] == ':' &&
        ((uri.codeUnitAt(0) >= 65 && uri.codeUnitAt(0) <= 90) ||
            (uri.codeUnitAt(0) >= 97 && uri.codeUnitAt(0) <= 122));
    if (!hasDrivePrefix) return uri;
    final normalized = p.normalize(uri.replaceAll('/', r'\'));
    final trimmed =
        normalized.length > 3 && normalized.endsWith(r'\')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    return r'\\?\' + trimmed;
  }

  static Media mediaFor(Map<String, Object?> item) {
    final reference = referenceFor(item);
    return Media(
      reference.streamUrl,
      start: reference.isChapter
          ? Duration(milliseconds: reference.startMs)
          : null,
      end: reference.endMs == null
          ? null
          : Duration(milliseconds: reference.endMs!),
      httpHeaders: reference.httpHeaders,
    );
  }

  PlaybackMediaReference get reference {
    final item = queue[index];
    if (!identical(item, _referenceItem)) {
      _reference = referenceFor(item);
      _referenceItem = item;
    }
    return _reference!;
  }

  Duration absolutePosition(Duration relative) =>
      relative + Duration(milliseconds: reference.startMs);
  Duration clampPosition(Duration position) {
    final end = reference.durationMs;
    final milliseconds = position.inMilliseconds;
    return Duration(
      milliseconds: milliseconds.clamp(0, end ?? 0x7fffffffffffffff),
    );
  }

  Duration relativePosition(Duration absolute) =>
      clampPosition(absolute - Duration(milliseconds: reference.startMs));
  Duration? relativeDuration(Duration? absolute) {
    final chapterDuration = reference.durationMs;
    if (chapterDuration != null) return Duration(milliseconds: chapterDuration);
    return absolute == null || absolute <= Duration.zero
        ? null
        : relativePosition(absolute);
  }

  Duration? get currentDuration =>
      relativeDuration(player?.state.duration) ?? duration;

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
          : completed || (!reference.isChapter && state.completed)
          ? 'completed'
          : state.buffering
          ? 'buffering'
          : 'ready',
      position: position,
      bufferedPosition: relativePosition(state?.buffer ?? Duration.zero),
      duration: currentDuration,
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
      return player.state.playlist.medias.map(mockMediaId).toList();
    }
    // mpv FORMAT_STRING prints NODE properties as JSON. The physical order and
    // stable entry IDs remain distinct even when multiple entries share a URI.
    final raw = readNativePlaylist != null
        ? await readNativePlaylist!(player)
        : await (platform as NativePlayer).getProperty('playlist');
    if (raw.length >= 128 * 1024) return compute(_decodeNativeEntryIds, raw);
    return _decodeNativeEntryIds(raw);
  }

  static List<int> _decodeNativeEntryIds(String raw) {
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
        : mockMediaId(playlist.medias[playlist.index]);
  }

  Future<void> mapNativeEntries(Player player) async {
    final generation = this.generation;
    final ids = await nativeEntryIds(player);
    if (retired ||
        !identical(this.player, player) ||
        generation != this.generation) {
      return;
    }
    _setNativeEntryOrder(ids);
  }

  void _setNativeEntryOrder(List<int> ids) {
    if (ids.isEmpty) throw StateError('Current native playlist is empty');
    nativeQueueIndices
      ..clear()
      ..addAll({
        for (var i = 0; i < ids.length; i++)
          ids[i]: nativeQueueLimited ? index : i,
      });
  }

  Future<void> keepCurrentNativeEntry(Player player) async {
    final platform = player.platform;
    final currentId = await currentNativeEntryId(player);
    final logicalIndex = nativeQueueIndices[currentId];
    if (currentId == null || logicalIndex == null) {
      throw StateError('Current native entry is unmapped');
    }
    if (platform is NativePlayer) {
      // mpv keeps the current decoder. Synchronize media_kit's public queue
      // state once so later edits still operate on the same physical entries.
      final current = mediaFor(queue[logicalIndex]);
      final playlist = Playlist([current]);
      await platform.command(['playlist-clear']);
      if (await platform.getProperty('playlist-count') != '1' ||
          int.tryParse(await platform.getProperty('playlist/0/id')) !=
              currentId) {
        throw StateError('Current native entry was not retained');
      }
      platform.current = playlist.medias;
      platform.state = platform.state.copyWith(playlist: playlist);
    } else {
      final ids = await nativeEntryIds(player);
      final currentIndex = ids.indexOf(currentId);
      if (currentIndex < 0) throw StateError('Current native entry is missing');
      for (var i = ids.length - 1; i >= 0; i--) {
        if (i != currentIndex) await player.remove(i);
      }
    }
    index = logicalIndex;
    nativeQueueLimited = true;
    _setNativeEntryOrder([currentId]);
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
    final retainCurrent = index < 0;
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
      final addedItems = <Map<String, Object?>>[];
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
        // Keep the longest subsequence already in physical order. A queue-head
        // drag to the tail then moves that entry once instead of every successor.
        final tails = <int>[];
        final predecessors = <int, int?>{};
        for (final token in desired.whereType<int>()) {
          var low = 0, high = tails.length;
          while (low < high) {
            final middle = (low + high) ~/ 2;
            if (tails[middle] < token) {
              low = middle + 1;
            } else {
              high = middle;
            }
          }
          predecessors[token] = low == 0 ? null : tails[low - 1];
          if (low == tails.length) {
            tails.add(token);
          } else {
            tails[low] = token;
          }
        }
        final stationary = <int>{};
        int? token = tails.lastOrNull;
        while (token != null) {
          stationary.add(token);
          token = predecessors[token];
        }
        for (var i = order.length - 1; i >= 0; i--) {
          if (!retained.contains(order[i])) {
            await player.remove(i);
            if (!isCurrent()) return;
            order.removeAt(i);
          }
        }
        var newToken = -1;
        final platform = player.platform;
        if (platform is NativePlayer) {
          // Batch media_kit's Dart playlist state update once after appending
          // to avoid O(N^2) list copies from repeated NativePlayer.add calls.
          final appendedMedias = <Media>[];
          try {
            for (var i = 0; i < desired.length; i++) {
              if (desired[i] == null) {
                final media = mediaFor(items[i]);
                await platform.command([
                  'loadfile',
                  _nativeMediaPath(media.uri),
                  'append',
                ]);
                appendedMedias.add(media);
                if (!isCurrent()) return;
                desired[i] = newToken;
                order.add(newToken--);
                addedItems.add(items[i]);
              }
            }
          } finally {
            if (appendedMedias.isNotEmpty) {
              final medias = [...platform.current, ...appendedMedias];
              platform.current = medias;
              platform.state = platform.state.copyWith(
                playlist: platform.state.playlist.copyWith(medias: medias),
              );
            }
          }
        } else {
          for (var i = 0; i < desired.length; i++) {
            if (desired[i] == null) {
              await player.add(mediaFor(items[i]));
              if (!isCurrent()) return;
              desired[i] = newToken;
              order.add(newToken--);
              addedItems.add(items[i]);
            }
          }
        }
        if (restoreNativeQueue && ids.length == 1) {
          // Appended entries are already in order. Move the retained decoder
          // once instead of moving every entry that preceded it.
          if (index > 0) await player.move(0, index + 1);
          if (!isCurrent()) return;
        } else {
          final positions = <int, int>{
            for (var i = 0; i < order.length; i++) order[i]: i,
          };
          var nextIndex = order.length;
          for (var i = desired.length - 1; i >= 0; i--) {
            final token = desired[i]!;
            if (stationary.contains(token)) {
              // Read a stationary anchor only when a move precedes it.
              if (i > 0 && !stationary.contains(desired[i - 1])) {
                nextIndex = positions[token]!;
              }
            } else {
              final from = positions[token]!;
              final to = nextIndex;
              // mpv inserts before the original target index. Passing length
              // places an entry at the tail even when it moves forward.
              final destination = from < to ? to - 1 : to;
              if (from != destination) {
                await player.move(from, to);
                order.insert(destination, order.removeAt(from));
                final start = from < destination ? from : destination;
                final end = from < destination ? destination : from;
                for (var pos = start; pos <= end; pos++) {
                  positions[order[pos]] = pos;
                }
              }
              nextIndex = destination;
            }
            if (!isCurrent()) return;
          }
        }
        // The edited physical order now matches the requested logical order.
        nativeQueueLimited = false;
        if (addedItems.isEmpty) {
          _setNativeEntryOrder([for (final token in order) ids[token]]);
        } else {
          await mapNativeEntries(player);
        }
      } catch (_) {
        if (isCurrent() && !restoreNativeQueue) {
          // Earlier successful edits remain applied when a later command fails.
          this.queue = [
            for (final token in order)
              token >= 0 ? physicalQueue[token] : addedItems[-token - 1],
          ];
          this.index = order.indexOf(currentToken);
          retainedCurrentIndex = retainCurrent ? this.index : null;
          await mapNativeEntries(player);
        }
        rethrow;
      } finally {
        opening = false;
      }
    }
    final keepRetained =
        retainCurrent ||
        (restoreNativeQueue &&
            retainedCurrentIndex != null &&
            this.index == retainedCurrentIndex &&
            index == retainedCurrentIndex);
    this.queue = items;
    this.index = index;
    retainedCurrentIndex = keepRetained ? index : null;
    if (restoreNativeQueue) nativeQueueLimited = false;
    if (player != null &&
        pendingStart != null &&
        player.state.duration > Duration.zero) {
      await restorePendingPosition(player, isCurrent: isCurrent);
    }
  }

  Future<void> restorePendingPosition(
    Player player, {
    required bool Function() isCurrent,
  }) async {
    final target = pendingStart!;
    final generation = this.generation;
    // Ignore decoder positions from the start of the file until the seek lands.
    try {
      await player.seek(absolutePosition(target));
    } finally {
      pendingStart = null;
    }
    if (isCurrent() &&
        generation == this.generation &&
        identical(this.player, player) &&
        wantsPlay) {
      await player.play();
    }
  }

  Future<void> releasePlayer() async {
    cancelRetry();
    temporarySpeed = null;
    final current = player;
    if (current == null) return;
    if (current.state.duration > Duration.zero) {
      duration = relativeDuration(current.state.duration);
    }
    player = null;
    nativeQueueIndices.clear();
    nativeQueueLimited = false;
    videoController = null;
    pendingStart = null;
    lastProgressPosition = null;
    lastProgressElapsed = null;
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    subscriptions.clear();
    await current.dispose();
  }
}
