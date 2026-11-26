import 'dart:collection';

String normalizeAsmrTag(String value) => value.trim().toLowerCase();

class AsmrTag {
  AsmrTag({
    required this.key,
    required this.name,
    this.onlineId,
    Iterable<String> aliases = const [],
  }) : aliases = List.unmodifiable(
         {name, ...aliases}.where((e) => e.trim().isNotEmpty),
       );
  final String key;
  final String name;
  final int? onlineId;
  final List<String> aliases;
  Map<String, Object?> toJson() => {
    'key': key,
    'name': name,
    'id': onlineId,
    'aliases': aliases,
  };
  factory AsmrTag.fromJson(Map<String, dynamic> json) => AsmrTag(
    key: json['key'] as String,
    name: json['name'] as String,
    onlineId: (json['id'] as num?)?.toInt(),
    aliases: (json['aliases'] as List? ?? []).cast<String>(),
  );
}

class AsmrTagInterest {
  const AsmrTagInterest({required this.tag, required this.weight});
  final AsmrTag tag;
  final double weight;
}

class _AsmrInterestDirectory {
  _AsmrInterestDirectory([this.entries = const {}, this.localKeys = const {}]);

  static final Expando<Map<String, String>> _aliasToKeyCache =
      Expando<Map<String, String>>('asmr_interest_alias_to_key');

  final Map<String, AsmrTag> entries;
  final Set<String> localKeys;
  late final Map<String, AsmrTag> view = UnmodifiableMapView(entries);
  bool shared = true;

  Map<String, String> get aliasToKey {
    final cached = _aliasToKeyCache[this];
    if (cached != null) return cached;
    final index = <String, String>{};
    for (final tag in entries.values) {
      for (final alias in tag.aliases) {
        index.putIfAbsent(normalizeAsmrTag(alias), () => tag.key);
      }
    }
    return _aliasToKeyCache[this] = index;
  }

  void clearAliasCache() {
    _aliasToKeyCache[this] = null;
  }

  _AsmrInterestDirectory copy() {
    final copied = _AsmrInterestDirectory(Map.of(entries), Set.of(localKeys))
      ..shared = false;
    final cached = _aliasToKeyCache[this];
    if (cached != null) {
      _aliasToKeyCache[copied] = Map.of(cached);
    }
    return copied;
  }

  void addLocal(AsmrTag tag, String alias) {
    entries[tag.key] = tag;
    localKeys.add(tag.key);
    if (tag.aliases.isNotEmpty) _aliasToKeyCache[this]?[alias] = tag.key;
  }
}

/// Persisted taste signals and directory share stable keys across content languages.
class AsmrTagPreferences {
  AsmrTagPreferences({this.limit = 20}) : assert(limit > 0);
  static const updatedAtMsKey = 'updatedAtMs';
  static const _separateCatalogKey = 'separateCatalog';

  final int limit;
  _AsmrInterestDirectory _directory = _AsmrInterestDirectory();
  Map<String, AsmrTag> get tags => _directory.view;
  final Map<String, double> learned = {};
  final Set<String> manualInterests = {};
  final Set<String> excluded = {};
  final Map<String, int> selectionUpdatedAt = {};
  final Map<String, Map<String, double>> deviceLearned = {};
  final Map<String, int> consumedSequences = {};
  ({Set<String> keys, Set<String> aliases})? _cachedExclusions;
  bool _catalogComplete = false;
  bool _catalogChanged = false;
  String? _storedCatalogKey;
  int? _updatedAtMs;
  int? get updatedAtMs => _updatedAtMs;

  bool get catalogComplete => _catalogComplete;
  set catalogComplete(bool value) {
    if (value == _catalogComplete) return;
    _catalogComplete = value;
    _catalogChanged = true;
  }

  bool needsCatalogSave(String key) =>
      _catalogChanged ||
      (_storedCatalogKey != key &&
          (catalogComplete ||
              _directory.entries.length > _directory.localKeys.length));

  void markCatalogSaved(String key) {
    _storedCatalogKey = key;
    _catalogChanged = false;
  }

  _AsmrInterestDirectory get _editableDirectory {
    if (_directory.shared) _directory = _directory.copy();
    return _directory;
  }

  String resolve(String name) {
    final normalized = normalizeAsmrTag(name);
    if (_directory.entries.containsKey(name)) return name;
    final directLocal = 'local:$normalized';
    if (_directory.entries.containsKey(directLocal)) return directLocal;
    final aliasKey = _directory.aliasToKey[normalized];
    if (aliasKey != null) return aliasKey;
    final directory = _editableDirectory;
    // Keep an already-built index current when a listening batch adds names.
    directory.addLocal(
      AsmrTag(key: directLocal, name: name.trim()),
      normalized,
    );
    return directLocal;
  }

  void mergeTag(AsmrTag tag) => mergeTags([tag]);

  void mergeTags(Iterable<AsmrTag> incoming) {
    if (incoming.isEmpty) return;
    _cachedExclusions = null;
    final directory = _editableDirectory;
    final entries = directory.entries;
    directory.clearAliasCache();
    final localAliases = <String, Set<String>>{};
    final localOrder = <String, int>{};
    var nextOrder = 0;
    void index(AsmrTag tag) {
      if (!tag.key.startsWith('local:')) return;
      localOrder.putIfAbsent(tag.key, () => nextOrder++);
      for (final alias in tag.aliases) {
        localAliases
            .putIfAbsent(normalizeAsmrTag(alias), () => <String>{})
            .add(tag.key);
      }
    }

    void unindex(AsmrTag tag) {
      for (final alias in tag.aliases) {
        localAliases[normalizeAsmrTag(alias)]?.remove(tag.key);
      }
    }

    for (final key in directory.localKeys) {
      index(entries[key]!);
    }
    for (final tag in incoming) {
      final keys = <String>{
        for (final alias in tag.aliases)
          ...?localAliases[normalizeAsmrTag(alias)],
      }..remove(tag.key);
      // Match the previous sequential merge order when several locals share aliases.
      final ordered = keys.toList()
        ..sort((a, b) => localOrder[a]!.compareTo(localOrder[b]!));
      final aliases = {...tag.aliases, ...?entries[tag.key]?.aliases};
      for (final key in ordered) {
        final previous = entries.remove(key)!;
        directory.localKeys.remove(key);
        unindex(previous);
        localOrder.remove(key);
        aliases.addAll(previous.aliases);
        learned[tag.key] = (learned[tag.key] ?? 0) + (learned.remove(key) ?? 0);
        if (manualInterests.remove(key)) manualInterests.add(tag.key);
        if (excluded.remove(key)) excluded.add(tag.key);
        if (selectionUpdatedAt.remove(key) case final int ts) {
          final currentTs = selectionUpdatedAt[tag.key];
          if (currentTs == null || ts > currentTs) {
            selectionUpdatedAt[tag.key] = ts;
          }
        }
        for (final weights in deviceLearned.values) {
          if (weights.remove(key) case final double w) {
            weights[tag.key] = (weights[tag.key] ?? 0) + w;
          }
        }
      }
      final merged = AsmrTag(
        key: tag.key,
        name: tag.name,
        onlineId: tag.onlineId,
        aliases: aliases,
      );
      entries[tag.key] = merged;
      if (tag.key.startsWith('local:')) {
        directory.localKeys.add(tag.key);
      } else {
        _catalogChanged = true;
      }
      index(merged);
    }
  }

  List<AsmrTagInterest> get listenedInterests =>
      rankedListeningInterests.take(limit).toList(growable: false);

  List<AsmrTagInterest> get rankedListeningInterests {
    final values = learned.entries
        .where((e) => e.value > 0 && tags.containsKey(e.key))
        .map((e) => AsmrTagInterest(tag: tags[e.key]!, weight: e.value))
        .toList();
    values.sort((a, b) {
      final order = b.weight.compareTo(a.weight);
      return order == 0 ? a.tag.name.compareTo(b.tag.name) : order;
    });
    return values;
  }

  List<AsmrTagInterest> fillInterestSlots(
    Iterable<AsmrTagInterest> rankedListening,
  ) {
    final interests = rankedListening
        .where((entry) => !excluded.contains(entry.tag.key))
        .take(limit)
        .toList();
    if (interests.length == limit) return interests;

    final rankedKeys = interests.map((entry) => entry.tag.key).toSet();
    final manualTags =
        manualInterests
            .where(
              (key) => !rankedKeys.contains(key) && !excluded.contains(key),
            )
            .map((key) => tags[key])
            .whereType<AsmrTag>()
            .toList()
          ..sort((a, b) {
            final name = a.name.compareTo(b.name);
            return name == 0 ? a.key.compareTo(b.key) : name;
          });
    interests.addAll(
      manualTags
          .take(limit - interests.length)
          .map((tag) => AsmrTagInterest(tag: tag, weight: 0)),
    );
    return interests;
  }

  void setInterested(String key, bool value) {
    _setSelection(manualInterests, key, value);
  }

  void setExcluded(String key, bool value) {
    _setSelection(excluded, key, value);
  }

  void _setSelection(Set<String> selection, String key, bool value) {
    if (!tags.containsKey(key)) throw ArgumentError.value(key, 'key');
    final changed = value ? selection.add(key) : selection.remove(key);
    if (changed) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      _updatedAtMs = nowMs;
      selectionUpdatedAt[key] = nowMs;
      _cachedExclusions = null;
    }
  }

  /// Snapshots this device's own learned weights (`learned - sum(otherPeers)`)
  /// into [deviceLearned] so cross-device merges remain strictly idempotent.
  Map<String, Map<String, double>> snapshotDeviceLearned(String localDeviceId) {
    final otherSums = <String, double>{};
    for (final entry in deviceLearned.entries) {
      if (entry.key == localDeviceId) continue;
      for (final item in entry.value.entries) {
        if (item.value > 0 && item.value.isFinite) {
          otherSums[item.key] = (otherSums[item.key] ?? 0) + item.value;
        }
      }
    }
    final own = <String, double>{};
    for (final item in learned.entries) {
      if (!item.value.isFinite || item.value <= 0) continue;
      final delta = item.value - (otherSums[item.key] ?? 0);
      if (delta > 1e-6) own[item.key] = delta;
    }
    if (own.isNotEmpty) {
      deviceLearned[localDeviceId] = own;
    }
    return {
      for (final entry in deviceLearned.entries)
        if (entry.value.isNotEmpty) entry.key: Map<String, double>.of(entry.value),
    };
  }

  bool mergeCrossPlatformSync({
    required String localDeviceId,
    required Iterable<AsmrTag> incomingTags,
    required Set<String> peerManualInterests,
    required Set<String> peerExcluded,
    required Map<String, int> peerSelectionUpdatedAt,
    required int? peerUpdatedAtMs,
    required Map<String, Map<String, double>> peerDeviceLearned,
  }) {
    var changed = false;
    snapshotDeviceLearned(localDeviceId);
    final beforeTagCount = tags.length;
    mergeTags(incomingTags);
    if (tags.length != beforeTagCount) changed = true;

    String canonicalKey(String rawKey) =>
        tags.containsKey(rawKey) ? rawKey : resolve(rawKey);

    for (final entry in peerDeviceLearned.entries) {
      if (entry.key == localDeviceId || entry.value.isEmpty) continue;
      final localPeerMap = deviceLearned.putIfAbsent(
        entry.key,
        () => <String, double>{},
      );
      for (final weightEntry in entry.value.entries) {
        final value = weightEntry.value;
        if (!value.isFinite || value <= 0) continue;
        final resolvedKey = canonicalKey(weightEntry.key);
        final existing = localPeerMap[resolvedKey] ?? 0;
        if (value > existing + 1e-6) {
          localPeerMap[resolvedKey] = value;
          changed = true;
        }
      }
    }

    if (deviceLearned.isNotEmpty) {
      final recomputed = <String, double>{};
      for (final map in deviceLearned.values) {
        for (final entry in map.entries) {
          if (entry.value > 0 && entry.value.isFinite) {
            final resolvedKey = canonicalKey(entry.key);
            recomputed[resolvedKey] =
                (recomputed[resolvedKey] ?? 0) + entry.value;
          }
        }
      }
      for (final entry in recomputed.entries) {
        final current = learned[entry.key] ?? 0;
        if (entry.value > current + 1e-6) {
          learned[entry.key] = entry.value;
          changed = true;
        }
      }
    }

    final mappedPeerManual = peerManualInterests.map(canonicalKey).toSet();
    final mappedPeerExcluded = peerExcluded.map(canonicalKey).toSet();
    final mappedPeerTimestamps = <String, int>{};
    for (final entry in peerSelectionUpdatedAt.entries) {
      final k = canonicalKey(entry.key);
      final prev = mappedPeerTimestamps[k];
      if (prev == null || entry.value > prev) {
        mappedPeerTimestamps[k] = entry.value;
      }
    }

    final allSelectionKeys = <String>{
      ...manualInterests,
      ...excluded,
      ...selectionUpdatedAt.keys,
      ...mappedPeerManual,
      ...mappedPeerExcluded,
      ...mappedPeerTimestamps.keys,
    };
    final fallbackLocalTs = _updatedAtMs ?? 0;
    final fallbackPeerTs = peerUpdatedAtMs ?? 0;

    for (final key in allSelectionKeys) {
      if (!tags.containsKey(key)) continue;
      final peerHasRecord =
          mappedPeerTimestamps.containsKey(key) ||
          mappedPeerManual.contains(key) ||
          mappedPeerExcluded.contains(key);
      if (!peerHasRecord) continue;

      final localHasRecord =
          selectionUpdatedAt.containsKey(key) ||
          manualInterests.contains(key) ||
          excluded.contains(key);
      final localTs = selectionUpdatedAt[key] ?? (localHasRecord ? fallbackLocalTs : -1);
      final peerTs = mappedPeerTimestamps[key] ?? fallbackPeerTs;

      if (peerTs > localTs) {
        final nextManual = mappedPeerManual.contains(key);
        final nextExcluded = mappedPeerExcluded.contains(key);
        if (manualInterests.contains(key) != nextManual) {
          if (nextManual) {
            manualInterests.add(key);
          } else {
            manualInterests.remove(key);
          }
          changed = true;
        }
        if (excluded.contains(key) != nextExcluded) {
          if (nextExcluded) {
            excluded.add(key);
          } else {
            excluded.remove(key);
          }
          _cachedExclusions = null;
          changed = true;
        }
        selectionUpdatedAt[key] = peerTs;
      } else if (peerTs == localTs) {
        if (mappedPeerManual.contains(key) && manualInterests.add(key)) {
          changed = true;
        }
        if (mappedPeerExcluded.contains(key) && excluded.add(key)) {
          _cachedExclusions = null;
          changed = true;
        }
      }
    }

    if (changed) {
      final maxTs = peerUpdatedAtMs != null &&
              (_updatedAtMs == null || peerUpdatedAtMs > _updatedAtMs!)
          ? peerUpdatedAtMs
          : DateTime.now().millisecondsSinceEpoch;
      _updatedAtMs = maxTs;
    }
    return changed;
  }

  bool recordListeningBatch(
    String batchId,
    List<({List<String> tags, Duration duration})> contributions,
  ) {
    final split = batchId.lastIndexOf(':');
    if (split < 1) {
      throw ArgumentError.value(batchId, 'batchId', 'Expected epoch:sequence');
    }
    final epoch = batchId.substring(0, split);
    final sequence = int.parse(batchId.substring(split + 1));
    if (sequence <= (consumedSequences[epoch] ?? -1)) return false;
    var learnedChanged = false;
    for (final contribution in contributions) {
      final keys = contribution.tags
          .where((e) => e.trim().isNotEmpty)
          .map(resolve)
          .toSet();
      if (keys.isEmpty || contribution.duration <= Duration.zero) continue;
      learnedChanged = true;
      // Every associated tag or creator was heard for the full playback time.
      final minutes =
          contribution.duration.inMilliseconds / Duration.millisecondsPerMinute;
      for (final key in keys) {
        learned[key] = (learned[key] ?? 0) + minutes;
      }
    }
    if (learnedChanged) _updatedAtMs = DateTime.now().millisecondsSinceEpoch;
    consumedSequences[epoch] = sequence;
    return true;
  }

  bool excludes({
    required Iterable<String> names,
    Iterable<int> ids = const [],
  }) {
    if (excluded.isEmpty) return false;
    if (ids.any((id) => excluded.contains('online:$id'))) return true;
    if (names.isEmpty) return false;
    final aliases = _exclusionAliases;
    return names.any((name) => aliases.contains(normalizeAsmrTag(name)));
  }

  Set<String> get _exclusionAliases {
    final cached = _cachedExclusions;
    if (cached != null &&
        cached.keys.length == excluded.length &&
        excluded.containsAll(cached.keys)) {
      return cached.aliases;
    }
    final excludedAliases = <String>{
      for (final key in excluded)
        for (final alias in tags[key]?.aliases ?? const <String>[])
          normalizeAsmrTag(alias),
    };
    _cachedExclusions = (keys: Set.of(excluded), aliases: excludedAliases);
    return excludedAliases;
  }

  Map<String, double> get recommendationWeights =>
      recommendationWeightsFor(listenedInterests);

  Map<String, double> recommendationWeightsFor(
    List<AsmrTagInterest> rankedInterests,
  ) {
    final result = <String, double>{};
    final listened = rankedInterests
        .where(
          (entry) => entry.weight.isFinite && !excluded.contains(entry.tag.key),
        )
        .toList(growable: false);
    final maximum = listened.isEmpty ? 0.0 : listened.first.weight;
    final weights = <String, double>{
      for (final entry in listened) entry.tag.key: entry.weight / maximum,
      for (final key in manualInterests)
        if (!excluded.contains(key)) key: 1,
    };
    for (final entry in weights.entries) {
      final key = entry.key;
      for (final alias in tags[key]?.aliases ?? <String>[]) {
        final name = normalizeAsmrTag(alias);
        if (name.isNotEmpty && entry.value > (result[name] ?? 0)) {
          result[name] = entry.value;
        }
      }
    }
    return result;
  }

  AsmrTagPreferences copy() {
    _directory.shared = true;
    final next = AsmrTagPreferences(limit: limit)
      .._directory = _directory
      ..learned.addAll(learned)
      ..manualInterests.addAll(manualInterests)
      ..excluded.addAll(excluded)
      ..selectionUpdatedAt.addAll(selectionUpdatedAt)
      ..deviceLearned.addAll({
        for (final entry in deviceLearned.entries)
          entry.key: Map<String, double>.of(entry.value),
      })
      ..consumedSequences.addAll(consumedSequences)
      .._updatedAtMs = _updatedAtMs
      .._catalogComplete = _catalogComplete
      .._catalogChanged = _catalogChanged
      .._storedCatalogKey = _storedCatalogKey;
    return next;
  }

  Map<String, Object?> toJson() => {
    'tags': tags.values.map((e) => e.toJson()).toList(),
    'complete': catalogComplete,
    ..._tasteJson(),
  };

  Map<String, Object?> toPreferenceJson() => {
    _separateCatalogKey: true,
    'tags': [
      for (final key in _directory.localKeys) _directory.entries[key]!.toJson(),
    ],
    ..._tasteJson(),
  };

  Map<String, Object?> toCatalogJson() => {
    'tags': [
      for (final entry in _directory.entries.entries)
        if (!_directory.localKeys.contains(entry.key)) entry.value.toJson(),
    ],
    'complete': catalogComplete,
  };

  Map<String, Object?> _tasteJson() => {
    'learned': learned,
    'manualInterests': manualInterests.toList(),
    'excluded': excluded.toList(),
    if (selectionUpdatedAt.isNotEmpty) 'selectionUpdatedAt': selectionUpdatedAt,
    if (deviceLearned.isNotEmpty) 'deviceLearned': deviceLearned,
    'sequences': consumedSequences,
    'limit': limit,
    if (_updatedAtMs != null) updatedAtMsKey: _updatedAtMs,
  };
  factory AsmrTagPreferences.fromJson(
    Map<String, dynamic> json, {
    Map<String, dynamic>? catalog,
    int? limit,
    String? storedCatalogKey,
  }) {
    final state = AsmrTagPreferences(
      limit: limit ?? (json['limit'] as num?)?.toInt() ?? 20,
    );
    final directory = state._editableDirectory;
    final split = json[_separateCatalogKey] == true;
    final catalogJson = split ? catalog : json;
    if (split) {
      for (final raw in catalog?['tags'] as List? ?? []) {
        final tag = AsmrTag.fromJson(Map<String, dynamic>.from(raw as Map));
        directory.entries[tag.key] = tag;
      }
    }
    for (final raw in json['tags'] as List? ?? []) {
      final tag = AsmrTag.fromJson(Map<String, dynamic>.from(raw as Map));
      directory.entries[tag.key] = tag;
      if (tag.key.startsWith('local:')) directory.localKeys.add(tag.key);
    }
    state.learned.addAll(
      (json['learned'] as Map? ?? {}).map(
        (key, value) => MapEntry(key.toString(), (value as num).toDouble()),
      ),
    );
    if (json.containsKey('manualInterests')) {
      state.manualInterests.addAll(
        (json['manualInterests'] as List).cast<String>(),
      );
    } else {
      // Older versions mixed listening and manual selections in weights. Keep
      // their checked tags as preferences, without inventing listening minutes.
      final hidden = json['hiddenUntil'] as Map? ?? {};
      final weights = json['weights'] as Map? ?? {};
      state.manualInterests.addAll(
        weights.entries
            .where((e) => (e.value as num) > 0 && !hidden.containsKey(e.key))
            .map((e) => e.key.toString()),
      );
    }
    state.excluded.addAll((json['excluded'] as List? ?? []).cast<String>());
    state.selectionUpdatedAt.addAll(
      (json['selectionUpdatedAt'] as Map? ?? {}).map(
        (key, value) => MapEntry(key.toString(), (value as num).toInt()),
      ),
    );
    final rawDeviceLearned = json['deviceLearned'];
    if (rawDeviceLearned is Map) {
      for (final entry in rawDeviceLearned.entries) {
        final weights = entry.value;
        if (weights is! Map) continue;
        state.deviceLearned[entry.key.toString()] = weights.map(
          (k, v) => MapEntry(k.toString(), (v as num).toDouble()),
        );
      }
    }
    state.consumedSequences.addAll(
      (json['sequences'] as Map? ?? {}).map(
        (key, value) => MapEntry(key.toString(), (value as num).toInt()),
      ),
    );
    state._catalogComplete = catalogJson?['complete'] == true;
    if (split && catalog != null) state._storedCatalogKey = storedCatalogKey;
    state._updatedAtMs = json[updatedAtMsKey] as int?;
    return state;
  }
}
