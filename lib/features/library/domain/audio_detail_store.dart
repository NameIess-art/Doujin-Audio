import '../../../core/media/audio_detail.dart';

abstract interface class AudioDetailStore {
  Future<AudioDetail?> load(AudioDetailTarget target);

  Future<List<AudioDetail>> loadMany(Iterable<AudioDetailTarget> targets);

  Future<void> upsert(AudioDetail detail);

  Future<void> upsertMany(Iterable<AudioDetail> details);

  Future<void> delete(AudioDetailTarget target);

  Future<void> deleteMany(Iterable<AudioDetailTarget> targets);
}
