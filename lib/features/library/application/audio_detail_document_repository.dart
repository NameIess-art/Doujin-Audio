import 'dart:typed_data';

import '../../../core/media/audio_detail.dart';
import '../../../core/persistence/json_document_store.dart';
import '../data/audio_detail_cover_store.dart';
import '../data/audio_detail_json_codec.dart';

const String audioDetailDocumentName = 'doujin-audio.json';

final class AudioDetailDocumentReadResult {
  const AudioDetailDocumentReadResult({
    this.detail,
    required this.status,
    this.error,
  });

  final AudioDetail? detail;
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
      final decoded = _codec.decodeDocument(snapshot.bytes, target);
      return AudioDetailDocumentReadResult(
        detail: await _coverStore.restore(
          decoded.detail.copyWith(target: target),
          decoded.fields,
        ),
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
  }) async {
    final location = locationFor(detail.target);
    final coverFields = await _coverStore.documentFields(detail);
    for (var attempt = 0; attempt < 2; attempt++) {
      final current = await _store.read(location);
      final snapshot = current.snapshot;
      if (current.status == JsonDocumentReadStatus.missing) {
        final created = await _store.write(
          location: location,
          bytes: _codec.encodeNew(detail, additionalFields: coverFields),
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
        bytes = _codec.merge(
          snapshot.bytes,
          detail,
          previousTarget: previousTarget,
          additionalFields: coverFields,
        );
      } on FormatException {
        // Explicit user saves may rebuild an empty, truncated or invalid
        // application-owned document. Automatic imports never call this path.
        bytes = _codec.encodeNew(detail, additionalFields: coverFields);
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
