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
    final result = await _store.read(locationFor(target));
    final snapshot = result.snapshot;
    if (result.status != JsonDocumentReadStatus.found || snapshot == null) {
      return AudioDetailDocumentReadResult(
        status: result.status,
        error: result.error,
      );
    }
    try {
      final codec = _codec;
      final decoded = await Isolate.run(
        () => codec.decodeDocument(snapshot.bytes, target),
      );
      return AudioDetailDocumentReadResult(
        detail: await _coverStore.restore(
          decoded.detail.copyWith(target: target),
          decoded.fields,
        ),
        timeSegmentLabels: decoded.timeSegmentLabels,
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
    bool onlyTimeSegments = false,
  }) async {
    final key = locationFor(detail.target).lockKey;
    final previous = _pendingSaves[key] ?? Future<void>.value();
    final completion = Completer<void>();
    _pendingSaves[key] = completion.future;
    await previous;
    try {
      return await _saveExplicit(
        detail,
        previousTarget: previousTarget,
        timeSegmentLabels: timeSegmentLabels,
        onlyTimeSegments: onlyTimeSegments,
      );
    } finally {
      completion.complete();
      if (identical(_pendingSaves[key], completion.future)) {
        final _ = _pendingSaves.remove(key);
      }
    }
  }

  Future<JsonDocumentWriteResult> _saveExplicit(
    AudioDetail detail, {
    AudioDetailTarget? previousTarget,
    List<TimeSegmentLabel>? timeSegmentLabels,
    required bool onlyTimeSegments,
  }) async {
    final location = locationFor(detail.target);
    final codec = _codec;
    final coverFields = <String, Object?>{
      ...await _coverStore.documentFields(detail),
      if (timeSegmentLabels != null)
        ..._codec.timeSegmentFields(detail.target, timeSegmentLabels),
    };
    for (var attempt = 0; attempt < 2; attempt++) {
      final current = await _store.read(location);
      final snapshot = current.snapshot;
      if (current.status == JsonDocumentReadStatus.missing) {
        final created = await _store.write(
          location: location,
          bytes: await Isolate.run(
            () => codec.encodeNew(detail, additionalFields: coverFields),
          ),
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

      Uint8List bytes;
      try {
        bytes = await Isolate.run(
          () => onlyTimeSegments
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
