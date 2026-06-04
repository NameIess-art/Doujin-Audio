import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/audio_effects.dart';
import 'package:nameless_audio/services/dart_playback_bridge.dart';

void main() {
  test('Windows dart playback exposes fixed EQ capabilities', () {
    expect(dartPlaybackWindowsEqCapabilities.supported, isTrue);
    expect(dartPlaybackWindowsEqCapabilities.minGainDb, -12);
    expect(dartPlaybackWindowsEqCapabilities.maxGainDb, 12);
    expect(
      dartPlaybackWindowsEqCapabilities.bands.map((band) => band.frequencyHz),
      <int>[31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000],
    );
  });

  test('Windows dart playback builds filters for enabled effects', () {
    final filters = buildDartPlaybackAudioFiltersForTest(
      const NativeAudioEffects(
        state: AudioEffectsState(
          skipSilenceEnabled: true,
          noiseReductionEnabled: true,
          volumeNormalizationEnabled: true,
          eqEnabled: true,
          eqBandLevels: <int, double>{1000: 20, 123: 4},
          panning: -1.0,
        ),
        channelSwapEnabled: true,
      ),
    );

    expect(
      filters.any((filter) => filter.contains('@na_skip_silence')),
      isTrue,
    );
    expect(
      filters.any(
        (filter) =>
            filter.contains('silenceremove') &&
            filter.contains('stop_duration=0.9') &&
            filter.contains('stop_threshold=-60dB'),
      ),
      isTrue,
    );
    expect(
      filters.any((filter) => filter.contains('afftdn=nr=6:nf=-55')),
      isTrue,
    );
    expect(
      filters.any(
        (filter) =>
            filter.contains('dynaudnorm=f=500:g=5:p=0.6:m=3') &&
            filter.contains('alimiter=limit=0.95'),
      ),
      isTrue,
    );
    expect(
      filters.any(
        (filter) =>
            filter.contains('@na_panning') &&
            filter.contains('c0=1*c0') &&
            filter.contains('c1=0*c1'),
      ),
      isTrue,
    );
    expect(
      filters.any(
        (filter) =>
            filter.contains('@na_eq') &&
            filter.contains('f=1000') &&
            filter.contains('g=12') &&
            !filter.contains('f=123'),
      ),
      isTrue,
    );
    expect(
      filters.any((filter) => filter.contains('@na_channel_swap')),
      isTrue,
    );
    expect(filters.map((filter) => filter.split(':').first), <String>[
      '@na_skip_silence',
      '@na_noise_reduction',
      '@na_volume_norm',
      '@na_eq',
      '@na_panning',
      '@na_channel_swap',
    ]);
  });

  test('Windows dart playback omits neutral panning and flat EQ filters', () {
    final filters = buildDartPlaybackAudioFiltersForTest(
      const NativeAudioEffects(
        state: AudioEffectsState(eqEnabled: true),
        channelSwapEnabled: false,
      ),
    );

    expect(filters, isEmpty);
  });
}
