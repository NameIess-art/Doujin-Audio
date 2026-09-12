import '../../../core/media/audio_detail.dart';
import '../../player/domain/time_segment_label.dart';

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
