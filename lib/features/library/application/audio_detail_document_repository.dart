import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../../../core/media/audio_detail.dart';
import '../../../core/persistence/json_document_store.dart';
import '../../player/domain/time_segment_label.dart';
import '../data/audio_detail_cover_store.dart';
import '../data/audio_detail_json_codec.dart';

const String audioDetailDocumentName = 'doujin-audio.json';

final class AudioDetailDocumentReadResult {
  const AudioDetailDocumentReadResult({
    this.detail,
    this.timeSegmentLabels = const [],
    required this.status,
    this.error,
  });

  final AudioDetail? detail;
  final List<TimeSegmentLabel> timeSegmentLabels;
  final JsonDocumentReadStatus status;
  final String? error;
}

final class AudioDetailDocumentRepository {
  AudioDetailDocumentRepository({
    required JsonDocumentStore store,
    AudioDetailJsonCodec codec = const AudioDetailJsonCodec(),
    AudioDetailCoverStore? coverStore,
  }) : _store = store,
       _codec = codec,
       _coverStore = coverStore ?? AudioDetailCoverStore();

  final JsonDocumentStore _store;
  final AudioDetailJsonCodec _codec;
  final AudioDetailCoverStore _coverStore;

  // Sibling audio files share one document, so the entire read/merge/write
  // must be ordered even across repository instances.
  static final Map<String, Future<void>> _pendingSaves = {};

  Future<AudioDetailDocumentReadResult> read(AudioDetailTarget target) async {
    final location = locationFor(target);
    final codec = _codec;
    if (_store case final DefaultJsonDocumentStore defaultStore) {
      final decoded = await defaultStore.readAndTransform(
        location,
        (result) => _decodeReadResult(codec, result, target),
      );
      return _finalizeDecodedRead(decoded, target);
    }
    final result = await _store.read(location);
    final snapshot = result.snapshot;
    if (result.status != JsonDocumentReadStatus.found || snapshot == null) {
      return AudioDetailDocumentReadResult(
        status: result.status,
        error: result.error,
      );
    }
    final decoded = await Isolate.run(
      () => _decodeReadResult(codec, result, target),
    );
    return _finalizeDecodedRead(decoded, target);
  }

  /// Reads and decodes [targets], deduplicating sibling targets that share a
  /// single document location so each JSON file is read and parsed once.
  Future<List<AudioDetailDocumentReadResult>> readMany(
    List<AudioDetailTarget> targets,
  ) async {
    if (targets.isEmpty) return const [];
    if (targets.length == 1) return [await read(targets.first)];

    final groupsByKey =
        <
          String,
          ({
            JsonDocumentLocation location,
            List<int> indices,
            List<AudioDetailTarget> targets,
          })
        >{};
    for (var i = 0; i < targets.length; i++) {
      final target = targets[i];
      final location = locationFor(target);
      final group = groupsByKey.putIfAbsent(
        location.lockKey,
        () => (location: location, indices: <int>[], targets: <AudioDetailTarget>[]),
      );
      group.indices.add(i);
      group.targets.add(target);
    }

    final results = List<AudioDetailDocumentReadResult?>.filled(
      targets.length,
      null,
    );
    final codec = _codec;
    final localGroups =
        <
          ({
            JsonDocumentLocation location,
            List<int> indices,
            List<AudioDetailTarget> targets,
          })
        >[];
    final otherGroups =
        <
          ({
            JsonDocumentLocation location,
            List<int> indices,
            List<AudioDetailTarget> targets,
          })
        >[];

    final defaultStore = _store is DefaultJsonDocumentStore ? _store : null;
    for (final group in groupsByKey.values) {
      if (defaultStore != null && !group.location.usesSaf) {
        localGroups.add(group);
      } else {
        otherGroups.add(group);
      }
    }

    if (localGroups.isNotEmpty) {
      final locations = [for (final group in localGroups) group.location];
      final groupedTargets = [for (final group in localGroups) group.targets];
      final decodedGroups = await defaultStore!.readManyLocalAndTransform(
        locations,
        (readResults) => [
          for (var i = 0; i < readResults.length; i++)
            _decodeReadResultMany(codec, readResults[i], groupedTargets[i]),
        ],
      );
      for (var g = 0; g < localGroups.length; g++) {
        final group = localGroups[g];
        final decodedList = decodedGroups[g];
        for (var j = 0; j < group.indices.length; j++) {
          results[group.indices[j]] = await _finalizeDecodedRead(
            decodedList[j],
            group.targets[j],
          );
        }
      }
    }

    for (final group in otherGroups) {
      final readResult = await _store.read(group.location);
      final List<_DecodedDocumentEntry> decodedList;
      if (readResult.status != JsonDocumentReadStatus.found ||
          readResult.snapshot == null) {
        decodedList = List.filled(group.targets.length, (
          status: readResult.status,
          document: null,
          error: readResult.error,
        ));
      } else {
        final groupTargets = group.targets;
        decodedList = await Isolate.run(
          () => _decodeReadResultMany(codec, readResult, groupTargets),
        );
      }
      for (var j = 0; j < group.indices.length; j++) {
        results[group.indices[j]] = await _finalizeDecodedRead(
          decodedList[j],
          group.targets[j],
        );
      }
    }

    return [for (final result in results) result!];
  }

  Future<AudioDetailDocumentReadResult> _finalizeDecodedRead(
    _DecodedDocumentEntry decoded,
    AudioDetailTarget target,
  ) async {
    final document = decoded.document;
    if (decoded.status != JsonDocumentReadStatus.found || document == null) {
      return AudioDetailDocumentReadResult(
        status: decoded.status,
        error: decoded.error,
      );
    }
    try {
      return AudioDetailDocumentReadResult(
        detail: await _coverStore.restore(
          document.detail.copyWith(target: target),
          document.fields,
        ),
        timeSegmentLabels: document.timeSegmentLabels,
        status: JsonDocumentReadStatus.found,
      );
    } on Object catch (error) {
      return AudioDetailDocumentReadResult(
        status: JsonDocumentReadStatus.unreadable,
        error: error.toString(),
      );
    }
  }

  Future<JsonDocumentWriteResult> saveExplicit(
    AudioDetail detail, {
    AudioDetailTarget? previousTarget,
    List<TimeSegmentLabel>? timeSegmentLabels,
    Future<List<TimeSegmentLabel>> Function()? loadTimeSegmentLabels,
    bool onlyTimeSegments = false,
    bool onlyMissingDuration = false,
    void Function()? beforeCommit,
  }) async {
    final key = locationFor(detail.target).lockKey;
    final previous = _pendingSaves[key] ?? Future<void>.value();
    final completion = Completer<void>();
    _pendingSaves[key] = completion.future;
    await previous;
    try {
      beforeCommit?.call();
      return await _saveExplicit(
        detail,
        previousTarget: previousTarget,
        timeSegmentLabels: timeSegmentLabels,
        loadTimeSegmentLabels: loadTimeSegmentLabels,
        onlyTimeSegments: onlyTimeSegments,
        onlyMissingDuration: onlyMissingDuration,
        beforeCommit: beforeCommit,
      );
    } finally {
      completion.complete();
      if (identical(_pendingSaves[key], completion.future)) {
        final _ = _pendingSaves.remove(key);
      }
    }
  }

  Future<JsonDocumentWriteResult> saveMissingDuration(
    AudioDetail detail, {
    List<TimeSegmentLabel>? timeSegmentLabels,
    Future<List<TimeSegmentLabel>> Function()? loadTimeSegmentLabels,
    void Function()? beforeCommit,
  }) => saveExplicit(
    detail,
    timeSegmentLabels: timeSegmentLabels,
    loadTimeSegmentLabels: loadTimeSegmentLabels,
    onlyMissingDuration: true,
    beforeCommit: beforeCommit,
  );

  Future<JsonDocumentWriteResult> _saveExplicit(
    AudioDetail detail, {
    AudioDetailTarget? previousTarget,
    List<TimeSegmentLabel>? timeSegmentLabels,
    Future<List<TimeSegmentLabel>> Function()? loadTimeSegmentLabels,
    required bool onlyTimeSegments,
    required bool onlyMissingDuration,
    void Function()? beforeCommit,
  }) async {
    final location = locationFor(detail.target);
    final codec = _codec;
    Map<String, Object?>? preparedFields;
    for (var attempt = 0; attempt < 2; attempt++) {
      final current = await _store.read(location);
      beforeCommit?.call();
      final snapshot = current.snapshot;
      // Complete duration documents need no cover preparation or label query.
      // Still validate the source so corrupt documents remain retryable.
      if (onlyMissingDuration && snapshot != null) {
        try {
          final patch = await Isolate.run(
            () => codec.mergeMissingDuration(snapshot.bytes, detail),
          );
          if (patch == null) {
            return const JsonDocumentWriteResult(
              status: JsonDocumentWriteStatus.preserved,
            );
          }
        } on FormatException catch (error) {
          return JsonDocumentWriteResult(
            status: JsonDocumentWriteStatus.conflict,
            error: error.toString(),
          );
        }
      }
      if (preparedFields == null) {
        final labels = timeSegmentLabels ?? await loadTimeSegmentLabels?.call();
        preparedFields = <String, Object?>{
          ...await _coverStore.documentFields(detail),
          if (labels != null) ...codec.timeSegmentFields(detail.target, labels),
        };
      }
      final coverFields = preparedFields;
      if (current.status == JsonDocumentReadStatus.missing) {
        final bytes = await Isolate.run(
          () => codec.encodeNew(detail, additionalFields: coverFields),
        );
        beforeCommit?.call();
        final created = await _store.write(
          location: location,
          bytes: bytes,
          mode: JsonDocumentWriteMode.createIfAbsent,
        );
        if (created.status != JsonDocumentWriteStatus.preserved) return created;
        continue;
      }
      if (snapshot == null) {
        return JsonDocumentWriteResult(
          status: JsonDocumentWriteStatus.conflict,
          error: current.error ?? 'document_unreadable',
        );
      }

      Uint8List? bytes;
      try {
        bytes = await Isolate.run(
          () => onlyMissingDuration
              ? codec.mergeMissingDuration(
                  snapshot.bytes,
                  detail,
                  additionalFields: coverFields,
                )
              : onlyTimeSegments
              ? codec.mergeTimeSegments(
                  snapshot.bytes,
                  detail,
                  codec.timeSegmentFields(detail.target, timeSegmentLabels!),
                )
              : codec.merge(
                  snapshot.bytes,
                  detail,
                  previousTarget: previousTarget,
                  additionalFields: coverFields,
                ),
        );
      } on FormatException catch (error) {
        return JsonDocumentWriteResult(
          status: JsonDocumentWriteStatus.conflict,
          error: error.toString(),
        );
      }
      if (bytes == null) {
        return const JsonDocumentWriteResult(
          status: JsonDocumentWriteStatus.preserved,
        );
      }
      beforeCommit?.call();
      final replaced = await _store.write(
        location: location,
        bytes: bytes,
        mode: JsonDocumentWriteMode.replaceIfRevision,
        expectedRevision: snapshot.revision,
      );
      if (replaced.status != JsonDocumentWriteStatus.conflict) return replaced;
    }
    return const JsonDocumentWriteResult(
      status: JsonDocumentWriteStatus.conflict,
      error: 'concurrent_document_update',
    );
  }

  JsonDocumentLocation locationFor(AudioDetailTarget target) {
    return target.isLibraryRootFolder
        ? JsonDocumentLocation.folderChild(
            folder: target.targetPath,
            name: audioDetailDocumentName,
          )
        : JsonDocumentLocation.fileSibling(
            filePath: target.targetPath,
            name: audioDetailDocumentName,
          );
  }
}

typedef _DecodedDocumentEntry = ({
  JsonDocumentReadStatus status,
  AudioDetailJsonDocument? document,
  String? error,
});

_DecodedDocumentEntry _decodeReadResult(
  AudioDetailJsonCodec codec,
  JsonDocumentReadResult result,
  AudioDetailTarget target,
) {
  final snapshot = result.snapshot;
  if (result.status != JsonDocumentReadStatus.found || snapshot == null) {
    return (status: result.status, document: null, error: result.error);
  }
  try {
    return (
      status: JsonDocumentReadStatus.found,
      document: codec.decodeDocument(snapshot.bytes, target),
      error: null,
    );
  } on Object catch (error) {
    return (
      status: JsonDocumentReadStatus.unreadable,
      document: null,
      error: error.toString(),
    );
  }
}

List<_DecodedDocumentEntry> _decodeReadResultMany(
  AudioDetailJsonCodec codec,
  JsonDocumentReadResult result,
  List<AudioDetailTarget> targets,
) {
  final snapshot = result.snapshot;
  if (result.status != JsonDocumentReadStatus.found || snapshot == null) {
    return List.filled(targets.length, (
      status: result.status,
      document: null,
      error: result.error,
    ));
  }
  final decoded = codec.decodeDocumentsForTargets(snapshot.bytes, targets);
  return [
    for (final entry in decoded)
      entry.document == null
          ? (
              status: JsonDocumentReadStatus.unreadable,
              document: null,
              error: entry.error,
            )
          : (
              status: JsonDocumentReadStatus.found,
              document: entry.document,
              error: null,
            ),
  ];
}
