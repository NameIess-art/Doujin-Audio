import 'dart:async';

import '../../../core/media/audio_detail.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/persistence/json_document_store.dart';
import '../domain/audio_detail_store.dart';
import '../data/audio_detail_cover_store.dart';
import 'audio_detail_document_repository.dart';

class AudioDetailLoadResult {
  const AudioDetailLoadResult({required this.detail});

  final AudioDetail detail;
}

class AudioDetailSaveResult {
  const AudioDetailSaveResult({
    required this.detail,
    required this.documentStatus,
    this.documentError,
  });

  final AudioDetail detail;
  final JsonDocumentWriteStatus documentStatus;
  final Object? documentError;

  bool get documentFailed => documentStatus == JsonDocumentWriteStatus.conflict;
}

class AudioDetailBackupImportResult {
  const AudioDetailBackupImportResult({
    this.changedDetails = const <AudioDetail>[],
    this.importedCount = 0,
    this.failureCount = 0,
  });

  final List<AudioDetail> changedDetails;
  final int importedCount;
  final int failureCount;
}

final class AudioDetailOperationCancelled implements Exception {
  const AudioDetailOperationCancelled();
}

final Object _audioDetailCommitGuardZoneKey = Object();

class AudioDetailRepository {
  AudioDetailRepository({
    required AudioDetailStore databaseRepository,
    AudioDetailDocumentRepository? documentRepository,
    JsonDocumentStore? jsonDocumentStore,
    AudioDetailCoverStore? coverStore,
    DateTime Function()? now,
  }) : _store = databaseRepository,
       _documents =
           documentRepository ??
           AudioDetailDocumentRepository(
             store: jsonDocumentStore ?? DefaultJsonDocumentStore(),
           ),
       _coverStore = coverStore ?? AudioDetailCoverStore(),
       _now = now ?? DateTime.now;

  final AudioDetailStore _store;
  final AudioDetailDocumentRepository _documents;
  final AudioDetailCoverStore _coverStore;
  final DateTime Function() _now;

  bool get _canCommit {
    final guard = Zone.current[_audioDetailCommitGuardZoneKey];
    return guard is! bool Function() || guard();
  }

  void _ensureCanCommit() {
    if (!_canCommit) throw const AudioDetailOperationCancelled();
  }

  static Future<T> runWithCommitGuard<T>(
    bool Function() guard,
    Future<T> Function() action,
  ) => runZoned(
    action,
    zoneValues: <Object?, Object?>{_audioDetailCommitGuardZoneKey: guard},
  );

  Future<AudioDetailLoadResult> load(AudioDetailTarget target) async {
    final normalizedTarget = _normalizeTarget(target);
    final detail = await _store.load(normalizedTarget);
    return AudioDetailLoadResult(
      detail: detail ?? AudioDetail.empty(normalizedTarget),
    );
  }

  Future<List<AudioDetailLoadResult>> loadMany(
    Iterable<AudioDetailTarget> targets,
  ) async {
    final ordered = targets.map(_normalizeTarget).toList(growable: false);
    final details = await _store.loadMany(ordered);
    final byKey = <String, AudioDetail>{
      for (final detail in details) _key(detail.target): detail,
    };
    return <AudioDetailLoadResult>[
      for (final target in ordered)
        AudioDetailLoadResult(
          detail: byKey[_key(target)] ?? AudioDetail.empty(target),
        ),
    ];
  }

  Future<AudioDetailSaveResult> save(AudioDetail detail) async {
    return _saveExplicit(detail);
  }

  Future<AudioDetailSaveResult> retarget(
    AudioDetailTarget previousTarget,
    AudioDetail detail,
  ) {
    return _saveExplicit(
      detail,
      previousTarget: _normalizeTarget(previousTarget),
    );
  }

  Future<AudioDetailSaveResult> _saveExplicit(
    AudioDetail detail, {
    AudioDetailTarget? previousTarget,
  }) async {
    final normalized = _coverStore
        .normalize(detail)
        .copyWith(target: _normalizeTarget(detail.target))
        .normalizedForSave(_now());
    _ensureCanCommit();
    await _store.upsert(normalized);
    _ensureCanCommit();
    final document = await _documents.saveExplicit(
      normalized,
      previousTarget: previousTarget,
    );
    return AudioDetailSaveResult(
      detail: normalized,
      documentStatus: document.status,
      documentError: document.error,
    );
  }

  Future<AudioDetail> updateDerivedFields(AudioDetail detail) async {
    final normalized = _coverStore
        .normalize(detail)
        .copyWith(target: _normalizeTarget(detail.target))
        .normalizedForSave(_now());
    _ensureCanCommit();
    await _store.upsert(normalized);
    return normalized;
  }

  Future<AudioDetailBackupImportResult> importBackupsMany(
    Iterable<AudioDetailTarget> targets,
  ) async {
    final ordered = targets.map(_normalizeTarget).toList(growable: false);
    if (ordered.isEmpty) return const AudioDetailBackupImportResult();
    final existing = await _store.loadMany(ordered);
    final existingByKey = <String, AudioDetail>{
      for (final detail in existing) _key(detail.target): detail,
    };
    final changed = <AudioDetail>[];
    var imported = 0;
    var failures = 0;
    for (final target in ordered) {
      final document = await _documents.read(target);
      final fileDetail = document.detail;
      if (fileDetail == null) {
        if (document.status == JsonDocumentReadStatus.unreadable) failures++;
        continue;
      }
      imported++;
      final database = existingByKey[_key(target)];
      final merged = _mergeImported(database, fileDetail, target);
      if (database == null || !_sameDetail(database, merged)) {
        changed.add(merged);
        existingByKey[_key(target)] = merged;
      }
    }
    _ensureCanCommit();
    await _store.upsertMany(changed);
    return AudioDetailBackupImportResult(
      changedDetails: List<AudioDetail>.unmodifiable(changed),
      importedCount: imported,
      failureCount: failures,
    );
  }

  Future<void> delete(AudioDetailTarget target) =>
      _store.delete(_normalizeTarget(target));

  Future<void> deleteMany(Iterable<AudioDetailTarget> targets) =>
      _store.deleteMany(targets.map(_normalizeTarget));

  Future<AudioDetailSaveResult?> prefillRjCodeFromText(
    AudioDetailTarget target,
    String text,
  ) async {
    final rjCode = AudioDetail.findRjCodeInText(text);
    if (rjCode == null) return null;
    final current = (await load(target)).detail;
    if (current.rjCode.isNotEmpty) return null;
    final updated = await updateDerivedFields(current.copyWith(rjCode: rjCode));
    return AudioDetailSaveResult(
      detail: updated,
      documentStatus: JsonDocumentWriteStatus.preserved,
    );
  }

  AudioDetail _mergeImported(
    AudioDetail? database,
    AudioDetail file,
    AudioDetailTarget target,
  ) {
    if (database == null) return file.copyWith(target: target);
    final fileIsNewer =
        file.updatedAt != null &&
        (database.updatedAt == null ||
            file.updatedAt!.isAfter(database.updatedAt!));
    final primary = fileIsNewer ? file : database;
    final secondary = fileIsNewer ? database : file;
    final preferFileUserFields =
        fileIsNewer || (file.updatedAt == null && database.updatedAt == null);
    final user = preferFileUserFields ? file : primary;
    return primary.copyWith(
      target: target,
      rjCode: _nonEmpty(user.rjCode, secondary.rjCode),
      workTitle: _nonEmpty(user.workTitle, secondary.workTitle),
      circleName: _nonEmpty(user.circleName, secondary.circleName),
      voiceActors: user.voiceActors.isNotEmpty
          ? user.voiceActors
          : secondary.voiceActors,
      tags: user.tags.isNotEmpty ? user.tags : secondary.tags,
      cardCoverPath: database.cardCoverPath ?? file.cardCoverPath,
      cardCoverSelected: database.cardCoverPath != null
          ? database.cardCoverSelected
          : file.cardCoverSelected,
      duration: database.duration ?? file.duration,
      releaseDate: user.releaseDate ?? secondary.releaseDate,
      salesCount: user.salesCount ?? secondary.salesCount,
      rating: user.rating ?? secondary.rating,
      createdAt: database.createdAt ?? file.createdAt,
      updatedAt: fileIsNewer ? file.updatedAt : database.updatedAt,
    );
  }

  AudioDetailTarget _normalizeTarget(AudioDetailTarget target) =>
      AudioDetailTarget(
        targetType: target.targetType,
        targetPath: PathMatcher.normalize(target.targetPath),
      );

  String _key(AudioDetailTarget target) =>
      '${target.targetType.dbValue}\x1F${PathMatcher.equivalenceKey(target.targetPath)}';
}

String _nonEmpty(String preferred, String fallback) =>
    preferred.trim().isNotEmpty ? preferred : fallback;

bool _sameDetail(AudioDetail first, AudioDetail second) =>
    first.target == second.target &&
    first.rjCode == second.rjCode &&
    first.workTitle == second.workTitle &&
    first.circleName == second.circleName &&
    _sameList(first.voiceActors, second.voiceActors) &&
    _sameList(first.tags, second.tags) &&
    first.cardCoverPath == second.cardCoverPath &&
    first.cardCoverSelected == second.cardCoverSelected &&
    first.releaseDate == second.releaseDate &&
    first.duration == second.duration &&
    first.salesCount == second.salesCount &&
    first.rating == second.rating &&
    first.createdAt == second.createdAt &&
    first.updatedAt == second.updatedAt;

bool _sameList(List<String> first, List<String> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}
