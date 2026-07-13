import 'dart:convert';

class AudioEffectsState {
  const AudioEffectsState({
    this.skipSilenceEnabled = false,
    this.noiseReductionEnabled = false,
    this.volumeNormalizationEnabled = false,
    this.eqEnabled = false,
    this.eqPresetId,
    this.eqBandLevels = const <int, double>{},
    this.panning = 0.0,
  });

  static const AudioEffectsState flat = AudioEffectsState();

  final bool skipSilenceEnabled;
  final bool noiseReductionEnabled;
  final bool volumeNormalizationEnabled;
  final bool eqEnabled;
  final String? eqPresetId;
  final Map<int, double> eqBandLevels;
  final double panning;

  bool get hasEnabledEffects =>
      skipSilenceEnabled ||
      noiseReductionEnabled ||
      volumeNormalizationEnabled ||
      eqEnabled ||
      eqPresetId != null ||
      eqBandLevels.isNotEmpty ||
      panning != 0.0;

  AudioEffectsState copyWith({
    bool? skipSilenceEnabled,
    bool? noiseReductionEnabled,
    bool? volumeNormalizationEnabled,
    bool? eqEnabled,
    Object? eqPresetId = _sentinel,
    Map<int, double>? eqBandLevels,
    double? panning,
  }) {
    return AudioEffectsState(
      skipSilenceEnabled: skipSilenceEnabled ?? this.skipSilenceEnabled,
      noiseReductionEnabled:
          noiseReductionEnabled ?? this.noiseReductionEnabled,
      volumeNormalizationEnabled:
          volumeNormalizationEnabled ?? this.volumeNormalizationEnabled,
      eqEnabled: eqEnabled ?? this.eqEnabled,
      eqPresetId: identical(eqPresetId, _sentinel)
          ? this.eqPresetId
          : eqPresetId as String?,
      eqBandLevels: Map<int, double>.unmodifiable(
        eqBandLevels ?? this.eqBandLevels,
      ),
      panning: panning ?? this.panning,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'skipSilenceEnabled': skipSilenceEnabled,
      'noiseReductionEnabled': noiseReductionEnabled,
      'volumeNormalizationEnabled': volumeNormalizationEnabled,
      'eqEnabled': eqEnabled,
      'eqPresetId': eqPresetId,
      'eqBandLevels': eqBandLevels.entries
          .map(
            (entry) => <String, Object?>{
              'frequencyHz': entry.key,
              'gainDb': entry.value,
            },
          )
          .toList(growable: false),
      'panning': panning,
    };
  }

  Map<String, Object?> toPlatformMap({required bool channelSwapEnabled}) {
    return <String, Object?>{
      ...toJson(),
      'channelSwapEnabled': channelSwapEnabled,
    };
  }

  String toDatabaseJson() => json.encode(toJson());

  factory AudioEffectsState.fromJson(Object? raw) {
    if (raw is String) {
      if (raw.isEmpty) return AudioEffectsState.flat;
      try {
        return AudioEffectsState.fromJson(json.decode(raw));
      } catch (_) {
        return AudioEffectsState.flat;
      }
    }
    if (raw is! Map) return AudioEffectsState.flat;
    return AudioEffectsState(
      skipSilenceEnabled: raw['skipSilenceEnabled'] as bool? ?? false,
      noiseReductionEnabled: raw['noiseReductionEnabled'] as bool? ?? false,
      volumeNormalizationEnabled:
          raw['volumeNormalizationEnabled'] as bool? ?? false,
      eqEnabled: raw['eqEnabled'] as bool? ?? false,
      eqPresetId: (raw['eqPresetId'] as String?)?.trim().isEmpty ?? true
          ? null
          : raw['eqPresetId'] as String?,
      eqBandLevels: Map<int, double>.unmodifiable(
        _decodeBandLevels(raw['eqBandLevels']),
      ),
      panning: (raw['panning'] as num?)?.toDouble() ?? 0.0,
    );
  }

  factory AudioEffectsState.fromPlatformMap(Object? raw) {
    return AudioEffectsState.fromJson(raw);
  }

  @override
  bool operator ==(Object other) {
    return other is AudioEffectsState &&
        other.skipSilenceEnabled == skipSilenceEnabled &&
        other.noiseReductionEnabled == noiseReductionEnabled &&
        other.volumeNormalizationEnabled == volumeNormalizationEnabled &&
        other.eqEnabled == eqEnabled &&
        other.eqPresetId == eqPresetId &&
        _mapEquals(other.eqBandLevels, eqBandLevels) &&
        other.panning == panning;
  }

  @override
  int get hashCode => Object.hash(
    skipSilenceEnabled,
    noiseReductionEnabled,
    volumeNormalizationEnabled,
    eqEnabled,
    eqPresetId,
    Object.hashAll(
      eqBandLevels.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
    panning,
  );
}

class EqBandInfo {
  const EqBandInfo({required this.frequencyHz});

  final int frequencyHz;

  factory EqBandInfo.fromJson(Object? raw) {
    if (raw is! Map) return const EqBandInfo(frequencyHz: 0);
    return EqBandInfo(frequencyHz: (raw['frequencyHz'] as num?)?.round() ?? 0);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'frequencyHz': frequencyHz,
  };

  @override
  bool operator ==(Object other) =>
      other is EqBandInfo && other.frequencyHz == frequencyHz;

  @override
  int get hashCode => frequencyHz.hashCode;
}

class EqCapabilities {
  const EqCapabilities({
    required this.supported,
    this.minGainDb = -12,
    this.maxGainDb = 12,
    this.bands = const <EqBandInfo>[],
  });

  static const EqCapabilities unsupported = EqCapabilities(supported: false);

  final bool supported;
  final double minGainDb;
  final double maxGainDb;
  final List<EqBandInfo> bands;

  factory EqCapabilities.fromJson(Object? raw) {
    if (raw is! Map) return EqCapabilities.unsupported;
    final rawBands = raw['bands'];
    return EqCapabilities(
      supported: raw['supported'] as bool? ?? false,
      minGainDb: (raw['minGainDb'] as num?)?.toDouble() ?? -12,
      maxGainDb: (raw['maxGainDb'] as num?)?.toDouble() ?? 12,
      bands: rawBands is List
          ? rawBands.map(EqBandInfo.fromJson).toList(growable: false)
          : const <EqBandInfo>[],
    );
  }

  @override
  bool operator ==(Object other) {
    return other is EqCapabilities &&
        other.supported == supported &&
        other.minGainDb == minGainDb &&
        other.maxGainDb == maxGainDb &&
        _listEquals(other.bands, bands);
  }

  @override
  int get hashCode =>
      Object.hash(supported, minGainDb, maxGainDb, Object.hashAll(bands));
}

class EqPreset {
  const EqPreset({
    required this.id,
    required this.labelKey,
    required this.bandLevels,
  });

  final String id;
  final String labelKey;
  final Map<int, double> bandLevels;

  bool get isCustom => id.startsWith('custom_');

  @override
  bool operator ==(Object other) {
    return other is EqPreset &&
        other.id == id &&
        other.labelKey == labelKey &&
        _mapEquals(other.bandLevels, bandLevels);
  }

  @override
  int get hashCode => Object.hash(
    id,
    labelKey,
    Object.hashAll(
      bandLevels.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'labelKey': labelKey,
      'bandLevels': bandLevels.entries
          .map(
            (entry) => <String, Object?>{
              'frequencyHz': entry.key,
              'gainDb': entry.value,
            },
          )
          .toList(growable: false),
    };
  }

  factory EqPreset.fromJson(Object? raw) {
    if (raw is! Map) {
      return const EqPreset(id: '', labelKey: '', bandLevels: <int, double>{});
    }
    return EqPreset(
      id: raw['id'] as String? ?? '',
      labelKey: raw['labelKey'] as String? ?? '',
      bandLevels: Map<int, double>.unmodifiable(
        _decodeBandLevels(raw['bandLevels']),
      ),
    );
  }
}

class NativeAudioEffects {
  const NativeAudioEffects({
    required this.state,
    required this.channelSwapEnabled,
  });

  final AudioEffectsState state;
  final bool channelSwapEnabled;

  Map<String, Object?> toPlatformMap() {
    return state.toPlatformMap(channelSwapEnabled: channelSwapEnabled);
  }
}

const Object _sentinel = Object();

Map<int, double> _decodeBandLevels(Object? raw) {
  if (raw is List) {
    final levels = <int, double>{};
    for (final item in raw) {
      if (item is! Map) continue;
      final frequencyHz = (item['frequencyHz'] as num?)?.round();
      final gainDb = (item['gainDb'] as num?)?.toDouble();
      if (frequencyHz == null || frequencyHz <= 0 || gainDb == null) continue;
      levels[frequencyHz] = gainDb;
    }
    return levels;
  }
  if (raw is Map) {
    final levels = <int, double>{};
    for (final entry in raw.entries) {
      final frequencyHz = int.tryParse(entry.key.toString());
      final gainDb = entry.value is num
          ? (entry.value as num).toDouble()
          : double.tryParse(entry.value.toString());
      if (frequencyHz == null || frequencyHz <= 0 || gainDb == null) continue;
      levels[frequencyHz] = gainDb;
    }
    return levels;
  }
  return const <int, double>{};
}

bool _mapEquals(Map<int, double> a, Map<int, double> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
