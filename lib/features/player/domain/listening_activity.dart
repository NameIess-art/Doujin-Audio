import '../../../core/media/music_track.dart';
import '../../../core/media/audio_detail.dart';

String listeningWorkKey(MusicTrack track) {
  final rj = AudioDetail.findRjCodeInText(
    [
      track.remoteMetadata?['sourceId'],
      track.groupSubtitle,
      track.groupTitle,
      track.path,
    ].join(' '),
  );
  if (rj != null) return 'rj:${rj.toUpperCase()}';
  final id = track.remoteMetadata?['id'];
  if (track.isRemoteAsmr && id != null) return 'asmr:$id';
  return 'local:${track.groupKey.replaceAll('\\', '/').toLowerCase()}';
}

final class ListeningDay {
  const ListeningDay({required this.date, required this.duration});
  final DateTime date;
  final Duration duration;
}

final class ListeningHistoryEntry {
  const ListeningHistoryEntry({
    required this.workKey,
    required this.track,
    this.lastPlayedAt,
  });
  final String workKey;
  final MusicTrack track;
  final DateTime? lastPlayedAt;
}

final class ListeningActivityView {
  const ListeningActivityView({
    this.days = const [],
    this.history = const [],
    this.hasMoreHistory = false,
  });
  final List<ListeningDay> days;
  final List<ListeningHistoryEntry> history;
  final bool hasMoreHistory;
}

final class ListeningWorkContribution {
  const ListeningWorkContribution({
    required this.workKey,
    required this.track,
    required this.milliseconds,
    required this.lastPlayedAtMs,
  });
  final String workKey;
  final MusicTrack track;
  final int milliseconds;
  final int lastPlayedAtMs;
}

final class ListeningDayContribution {
  const ListeningDayContribution({
    required this.date,
    required this.totalMs,
    required this.works,
  });
  final String date;
  final int totalMs;
  final List<ListeningWorkContribution> works;
}

abstract interface class ListeningActivityRepository {
  Future<bool> importBatch(String batchId, List<ListeningDayContribution> days);
  Future<List<ListeningDay>> loadDays();
  Future<List<ListeningHistoryEntry>> loadHistory({
    int offset = 0,
    int limit = 40,
  });
  Future<MusicTrack?> findTrack(String workKey);
  Future<void> seedHistory(List<ListeningHistoryEntry> entries);
}
