import 'dart:math';

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
  final Map<String, AsmrTag> tags = {};
  final Map<String, double> weights = {};
  final Map<String, double> learned = {};
  final Map<String, double> hiddenUntil = {};
  final Set<String> excluded = {};
  final Map<String, int> consumedSequences = {};
  bool seeded = false;
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

  void mergeTag(AsmrTag tag) {
    final keys = tags.values
        .where(
          (old) =>
              old.key != tag.key &&
              old.onlineId == null &&
              old.aliases.any(
                (alias) => tag.aliases.any(
                  (value) => normalizeAsmrTag(value) == normalizeAsmrTag(alias),
                ),
              ),
        )
        .map((e) => e.key)
        .toList();
    final aliases = {...tag.aliases, ...?tags[tag.key]?.aliases};
    for (final key in keys) {
      aliases.addAll(tags.remove(key)!.aliases);
      weights[tag.key] = (weights[tag.key] ?? 0) + (weights.remove(key) ?? 0);
      final previousLearned = learned[tag.key] ?? 0;
      final mergedLearned = learned.remove(key) ?? 0;
      final threshold = hiddenUntil.remove(key);
      final existingThreshold = hiddenUntil[tag.key];
      learned[tag.key] = previousLearned + mergedLearned;
      if (threshold != null || existingThreshold != null) {
        final remaining = max(
          (threshold ?? mergedLearned) - mergedLearned,
          (existingThreshold ?? previousLearned) - previousLearned,
        );
        hiddenUntil[tag.key] = learned[tag.key]! + remaining;
      }
      if (excluded.remove(key)) excluded.add(tag.key);
    }
    tags[tag.key] = AsmrTag(
      key: tag.key,
      name: tag.name,
      onlineId: tag.onlineId,
      aliases: aliases,
    );
  }

  List<AsmrTagInterest> get interests {
    final values = weights.entries
        .where(
          (e) =>
              e.value > 0 &&
              !hiddenUntil.containsKey(e.key) &&
              tags.containsKey(e.key),
        )
        .map((e) => AsmrTagInterest(tag: tags[e.key]!, weight: e.value))
        .toList();
    values.sort((a, b) {
      final listening = (learned[b.tag.key] ?? 0).compareTo(
        learned[a.tag.key] ?? 0,
      );
      if (listening != 0) return listening;
      final order = b.weight.compareTo(a.weight);
      return order == 0 ? a.tag.name.compareTo(b.tag.name) : order;
    });
    return values;
  }

  void setInterested(String key, bool value) {
    if (!tags.containsKey(key)) throw ArgumentError.value(key, 'key');
    if (value) {
      weights[key] = max(weights[key] ?? 0, 1);
      hiddenUntil.remove(key);
    } else {
      final reduction = (weights[key] ?? 0) * .1;
      weights[key] = (weights[key] ?? 0) - reduction;
      hiddenUntil[key] = (learned[key] ?? 0) + max(10, reduction);
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
      final minutes =
          contribution.duration.inMilliseconds /
          Duration.millisecondsPerMinute /
          keys.length;
      for (final key in keys) {
        weights[key] = (weights[key] ?? 0) + minutes;
        learned[key] = (learned[key] ?? 0) + minutes;
        if (hiddenUntil[key] != null && learned[key]! >= hiddenUntil[key]!) {
          hiddenUntil.remove(key);
        }
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

  Map<String, double> get recommendationWeights {
    final result = <String, double>{};
    for (final entry in weights.entries) {
      for (final alias in tags[entry.key]?.aliases ?? <String>[]) {
        result[normalizeAsmrTag(alias)] = entry.value;
      }
    }
    return result;
  }

  Map<String, Object?> toJson() => {
    'tags': tags.values.map((e) => e.toJson()).toList(),
    'weights': weights,
    'learned': learned,
    'hiddenUntil': hiddenUntil,
    'excluded': excluded.toList(),
    'sequences': consumedSequences,
    'seeded': seeded,
    'complete': catalogComplete,
  };
  factory AsmrTagPreferences.fromJson(Map<String, dynamic> json) {
    final state = AsmrTagPreferences();
    for (final raw in json['tags'] as List? ?? []) {
      final tag = AsmrTag.fromJson(Map<String, dynamic>.from(raw as Map));
      state.tags[tag.key] = tag;
    }
    for (final pair in [
      (state.weights, 'weights'),
      (state.learned, 'learned'),
      (state.hiddenUntil, 'hiddenUntil'),
    ]) {
      final values = json[pair.$2] as Map? ?? {};
      pair.$1.addAll(
        values.map(
          (key, value) => MapEntry(key.toString(), (value as num).toDouble()),
        ),
      );
    }
    state.excluded.addAll((json['excluded'] as List? ?? []).cast<String>());
    state.consumedSequences.addAll(
      (json['sequences'] as Map? ?? {}).map(
        (key, value) => MapEntry(key.toString(), (value as num).toInt()),
      ),
    );
    state.seeded = json['seeded'] == true;
    state.catalogComplete = json['complete'] == true;
    return state;
  }
  AsmrTagPreferences();
}
