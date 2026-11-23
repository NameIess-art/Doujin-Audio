import '../../../core/media/audio_detail.dart';
import '../../../core/media/time_segment_label.dart';

abstract interface class AudioDetailStore {
  Future<AudioDetail?> load(AudioDetailTarget target);

  Future<List<AudioDetail>> loadMany(Iterable<AudioDetailTarget> targets);

  Future<void> upsert(AudioDetail detail);

  Future<void> upsertMany(Iterable<AudioDetail> details);

  Future<List<TimeSegmentLabel>> loadTimeSegmentLabelsForTarget(
    AudioDetailTarget target,
  );

  Future<void> importDetails(
    Iterable<AudioDetail> details,
    Iterable<TimeSegmentLabel> labels,
  );

  Future<void> delete(AudioDetailTarget target);

  Future<void> deleteMany(Iterable<AudioDetailTarget> targets);
}

/// Optional fast-path projection queries supported by SQLite-backed stores.
abstract interface class AudioDetailFastQueryStore implements AudioDetailStore {
  /// Returns a map from `AudioLibraryDetailKey.forTarget(target)` to persisted
  /// duration (or `null` when the row exists with no duration). Targets with no
  /// row in storage are omitted.
  Future<Map<String, Duration?>> loadDurations(
    Iterable<AudioDetailTarget> targets,
  );

  /// Loads search-relevant detail projections without hydrating cover or
  /// timestamp columns.
  Future<List<AudioDetail>> loadSearchDetails(
    Iterable<AudioDetailTarget> targets,
  );
}
