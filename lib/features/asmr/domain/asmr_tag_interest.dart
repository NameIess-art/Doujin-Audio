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

/// Persisted taste signals and directory share stable keys across content languages.
class AsmrTagPreferences {
  AsmrTagPreferences({this.limit = 20}) : assert(limit > 0);
  final int limit;
  final Map<String, AsmrTag> tags = {};
  final Map<String, double> learned = {};
  final Set<String> manualInterests = {};
  final Set<String> excluded = {};
  final Map<String, int> consumedSequences = {};
  bool catalogComplete = false;

  String resolve(String name) {
    final normalized = normalizeAsmrTag(name);
    if (tags.containsKey(name)) return name;
    for (final tag in tags.values) {
      if (tag.aliases.any((alias) => normalizeAsmrTag(alias) == normalized)) {
        return tag.key;
      }
    }
    final key = 'local:$normalized';
    tags.putIfAbsent(key, () => AsmrTag(key: key, name: name.trim()));
    return key;
  }

  void mergeTag(AsmrTag tag) => mergeTags([tag]);

  void mergeTags(Iterable<AsmrTag> incoming) {
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

    for (final tag in tags.values) {
      index(tag);
    }
    for (final tag in incoming) {
      final keys = <String>{
        for (final alias in tag.aliases)
          ...?localAliases[normalizeAsmrTag(alias)],
      }..remove(tag.key);
      // Match the previous sequential merge order when several locals share aliases.
      final ordered = keys.toList()
        ..sort((a, b) => localOrder[a]!.compareTo(localOrder[b]!));
      final aliases = {...tag.aliases, ...?tags[tag.key]?.aliases};
      for (final key in ordered) {
        final previous = tags.remove(key)!;
        unindex(previous);
        localOrder.remove(key);
        aliases.addAll(previous.aliases);
        learned[tag.key] = (learned[tag.key] ?? 0) + (learned.remove(key) ?? 0);
        if (manualInterests.remove(key)) manualInterests.add(tag.key);
        if (excluded.remove(key)) excluded.add(tag.key);
      }
      final merged = AsmrTag(
        key: tag.key,
        name: tag.name,
        onlineId: tag.onlineId,
        aliases: aliases,
      );
      tags[tag.key] = merged;
      index(merged);
    }
  }

  List<AsmrTagInterest> get listenedInterests {
    final values = learned.entries
        .where((e) => e.value > 0 && tags.containsKey(e.key))
        .map((e) => AsmrTagInterest(tag: tags[e.key]!, weight: e.value))
        .toList();
    values.sort((a, b) {
      final order = b.weight.compareTo(a.weight);
      return order == 0 ? a.tag.name.compareTo(b.tag.name) : order;
    });
    return values.take(limit).toList(growable: false);
  }

  List<AsmrTagInterest> get interests => listenedInterests;

  void setInterested(String key, bool value) {
    if (!tags.containsKey(key)) throw ArgumentError.value(key, 'key');
    if (value) {
      manualInterests.add(key);
    } else {
      manualInterests.remove(key);
    }
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
    for (final contribution in contributions) {
      final keys = contribution.tags
          .where((e) => e.trim().isNotEmpty)
          .map(resolve)
          .toSet();
      if (keys.isEmpty || contribution.duration <= Duration.zero) continue;
      // Every associated tag or creator was heard for the full playback time.
      final minutes =
          contribution.duration.inMilliseconds / Duration.millisecondsPerMinute;
      for (final key in keys) {
        learned[key] = (learned[key] ?? 0) + minutes;
      }
    }
    consumedSequences[epoch] = sequence;
    return true;
  }

  bool excludes({
    required Iterable<String> names,
    Iterable<int> ids = const [],
  }) =>
      ids.any((id) => excluded.contains('online:$id')) ||
      names.any((name) {
        final normalized = normalizeAsmrTag(name);
        return excluded.any(
          (key) =>
              tags[key]?.aliases.any(
                (alias) => normalizeAsmrTag(alias) == normalized,
              ) ??
              false,
        );
      });

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

  Map<String, Object?> toJson() => {
    'tags': tags.values.map((e) => e.toJson()).toList(),
    'learned': learned,
    'manualInterests': manualInterests.toList(),
    'excluded': excluded.toList(),
    'sequences': consumedSequences,
    'complete': catalogComplete,
    'limit': limit,
  };
  factory AsmrTagPreferences.fromJson(Map<String, dynamic> json) {
    final state = AsmrTagPreferences(
      limit: (json['limit'] as num?)?.toInt() ?? 20,
    );
    for (final raw in json['tags'] as List? ?? []) {
      final tag = AsmrTag.fromJson(Map<String, dynamic>.from(raw as Map));
      state.tags[tag.key] = tag;
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
    state.consumedSequences.addAll(
      (json['sequences'] as Map? ?? {}).map(
        (key, value) => MapEntry(key.toString(), (value as num).toInt()),
      ),
    );
    state.catalogComplete = json['complete'] == true;
    return state;
  }
}
