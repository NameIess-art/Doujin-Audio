import 'dart:convert';
import 'dart:typed_data';

import '../../../core/media/audio_detail.dart';
import '../../../core/media/path_matcher.dart';
import '../../player/domain/time_segment_label.dart';

final class AudioDetailJsonDocument {
  const AudioDetailJsonDocument({
    required this.detail,
    required this.fields,
    this.timeSegmentLabels = const [],
  });

  final AudioDetail detail;
  final List<TimeSegmentLabel> timeSegmentLabels;
  final Map<String, Object?> fields;
}

final class AudioDetailJsonCodec {
  const AudioDetailJsonCodec();

  AudioDetail decode(Uint8List bytes, AudioDetailTarget target) {
    return decodeDocument(bytes, target).detail;
  }

  AudioDetailJsonDocument decodeDocument(
    Uint8List bytes,
    AudioDetailTarget target,
  ) {
    final root = _decodeRoot(bytes);
    final raw = switch (root) {
      Map<Object?, Object?> map => Map<String, Object?>.from(map),
      List<Object?> list => _findTargetEntry(list, target),
      _ => throw const FormatException('Unsupported audio detail document'),
    };
    return AudioDetailJsonDocument(
      detail: _detailFromJson(target, raw),
      timeSegmentLabels: _labelsFromJson(raw, target),
      fields: Map<String, Object?>.unmodifiable(raw),
    );
  }

  Uint8List encodeNew(
    AudioDetail detail, {
    Map<String, Object?> additionalFields = const <String, Object?>{},
  }) {
    final value =
        detail.target.targetType == AudioDetailTargetType.singleAudioFile
        ? <Object?>[_detailToJson(detail, additionalFields)]
        : _detailToJson(detail, additionalFields);
    return _encode(value);
  }

  Uint8List merge(
    Uint8List existingBytes,
    AudioDetail detail, {
    AudioDetailTarget? previousTarget,
    Map<String, Object?> additionalFields = const <String, Object?>{},
  }) {
    final root = _decodeRoot(existingBytes);
    final updated = switch (root) {
      Map<Object?, Object?> map when detail.target.isLibraryRootFolder =>
        _mergeEntry(Map<String, Object?>.from(map), detail, additionalFields),
      List<Object?> list
          when detail.target.targetType ==
              AudioDetailTargetType.singleAudioFile =>
        _mergeList(
          list,
          detail,
          previousTarget: previousTarget,
          additionalFields: additionalFields,
        ),
      _ => throw const FormatException('Audio detail document layout mismatch'),
    };
    return _encode(updated);
  }

  Map<String, Object?> timeSegmentFields(
    AudioDetailTarget target,
    Iterable<TimeSegmentLabel> labels,
  ) => {
    'timeSegmentLabels': [
      for (final label in labels)
        {
          'id': label.id,
          'trackPath': target.isLibraryRootFolder
              ? PathMatcher.relativeWithin(label.trackKey, target.targetPath)
              : '',
          'name': label.name,
          'startMs': label.start.inMilliseconds,
          'endMs': label.end.inMilliseconds,
          'colorValue': label.colorValue,
          'createdAt': label.createdAt.toIso8601String(),
          'updatedAt': label.updatedAt.toIso8601String(),
        },
    ],
  };

  List<TimeSegmentLabel> _labelsFromJson(
    Map<String, Object?> json,
    AudioDetailTarget target,
  ) {
    if (!json.containsKey('timeSegmentLabels')) return const [];
    final value = json['timeSegmentLabels'];
    if (value is! List) {
      throw const FormatException('Invalid timeSegmentLabels');
    }
    final result = <TimeSegmentLabel>[];
    final ids = <String>{};
    for (final item in value) {
      if (item is! Map) {
        throw const FormatException('Invalid time segment label');
      }
      final fields = Map<String, Object?>.from(item);
      final id = _string(fields, 'id');
      final name = _string(fields, 'name');
      final relative = fields['trackPath'];
      if (id.trim().isEmpty ||
          !ids.add(id) ||
          name.trim().isEmpty ||
          relative is! String ||
          (target.isLibraryRootFolder
              ? relative.isEmpty
              : relative.isNotEmpty) ||
          relative.contains('\\') ||
          relative.contains(':') ||
          relative.contains('\x00') ||
          relative.startsWith('/') ||
          (relative.isNotEmpty &&
              relative
                  .split('/')
                  .any(
                    (part) => part.isEmpty || part == '.' || part == '..',
                  ))) {
        throw const FormatException('Invalid time segment identity or path');
      }
      final start = _integer(fields, 'startMs', minimum: 0);
      final end = _integer(fields, 'endMs', minimum: 0);
      final color = _integer(fields, 'colorValue', minimum: 0);
      final created = _date(fields, 'createdAt');
      final updated = _date(fields, 'updatedAt');
      if (start == null ||
          end == null ||
          end <= start ||
          color == null ||
          color > 0xffffffff ||
          created == null ||
          updated == null ||
          updated.isBefore(created)) {
        throw const FormatException('Invalid time segment values');
      }
      final root = target.targetPath;
      final trackKey = !target.isLibraryRootFolder
          ? root
          : PathMatcher.isContentUri(root)
          ? (root.contains('::') ? '$root/$relative' : '$root::$relative')
          : PathMatcher.join(root, relative);
      result.add(
        TimeSegmentLabel(
          id: id,
          trackKey: trackKey,
          name: name,
          start: Duration(milliseconds: start),
          end: Duration(milliseconds: end),
          colorValue: color,
          createdAt: created,
          updatedAt: updated,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  Uint8List mergeTimeSegments(
    Uint8List bytes,
    AudioDetail detail,
    Map<String, Object?> fields,
  ) {
    final target = detail.target;
    final root = _decodeRoot(bytes);
    if (root is Map && target.isLibraryRootFolder) {
      final entry = Map<String, Object?>.from(root);
      _detailFromJson(target, entry);
      return _encode({...entry, ...fields});
    }
    if (root is List && !target.isLibraryRootFolder) {
      if (!root.any(
        (item) =>
            item is Map &&
            item['targetPath'] is String &&
            PathMatcher.equalsNormalized(
              item['targetPath'] as String,
              target.targetPath,
            ),
      )) {
        return _encode([...root, _detailToJson(detail, fields)]);
      }
      final entry = _findTargetEntry(root, target);
      _detailFromJson(target, entry);
      return _encode([
        for (final item in root)
          if (item is Map && item['targetPath'] == entry['targetPath'])
            {...entry, ...fields}
          else
            item,
      ]);
    }
    throw const FormatException('Audio detail document layout mismatch');
  }

  Object? _decodeRoot(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const FormatException('Empty audio detail document');
    }
    final text = utf8.decode(bytes);
    if (text.trim().isEmpty) {
      throw const FormatException('Blank audio detail document');
    }
    return jsonDecode(text);
  }

  Map<String, Object?> _findTargetEntry(
    List<Object?> list,
    AudioDetailTarget target,
  ) {
    for (final item in list) {
      if (item is! Map) continue;
      final entry = Map<String, Object?>.from(item);
      final targetPath = entry['targetPath'];
      if (targetPath is String &&
          PathMatcher.equalsNormalized(targetPath, target.targetPath)) {
        return entry;
      }
    }
    throw const FormatException('Audio detail entry not found');
  }

  List<Object?> _mergeList(
    List<Object?> source,
    AudioDetail detail, {
    AudioDetailTarget? previousTarget,
    required Map<String, Object?> additionalFields,
  }) {
    final result = List<Object?>.from(source);
    final matchTarget = previousTarget ?? detail.target;
    for (var index = 0; index < result.length; index++) {
      final item = result[index];
      if (item is! Map) continue;
      final entry = Map<String, Object?>.from(item);
      final targetPath = entry['targetPath'];
      if (targetPath is String &&
          PathMatcher.equalsNormalized(targetPath, matchTarget.targetPath)) {
        result[index] = _mergeEntry(entry, detail, additionalFields);
        return result;
      }
    }
    result.add(_detailToJson(detail, additionalFields));
    return result;
  }

  Map<String, Object?> _mergeEntry(
    Map<String, Object?> existing,
    AudioDetail detail,
    Map<String, Object?> additionalFields,
  ) => <String, Object?>{
    ...existing,
    ..._detailToJson(detail, additionalFields),
  };

  AudioDetail _detailFromJson(
    AudioDetailTarget fallbackTarget,
    Map<String, Object?> json,
  ) {
    if (json['schemaVersion'] != 1 || json['type'] != 'audio-detail') {
      throw const FormatException('Unsupported audio detail schema');
    }
    final targetType = switch (json['targetType']) {
      String value => AudioDetailTargetType.fromBackupValue(value),
      null => fallbackTarget.targetType,
      _ => null,
    };
    if (targetType == null) {
      throw const FormatException('Unknown audio detail target type');
    }
    if (targetType != fallbackTarget.targetType) {
      throw const FormatException('Audio detail target type mismatch');
    }
    final targetPath = switch (json['targetPath']) {
      String value when value.trim().isNotEmpty => value,
      null => fallbackTarget.targetPath,
      _ => throw const FormatException('Invalid audio detail target path'),
    };
    return AudioDetail(
      target: AudioDetailTarget(targetType: targetType, targetPath: targetPath),
      rjCode: _string(json, 'rjCode'),
      workTitle: _string(json, 'workTitle'),
      circleName: _string(json, 'circleName'),
      voiceActors: _stringList(json, 'voiceActors'),
      tags: _stringList(json, 'tags'),
      cardCoverPath: _nullableString(json, 'cardCoverPath'),
      cardCoverSelected: json['cardCoverSelected'] == true,
      releaseDate: _date(json, 'releaseDate'),
      duration: _duration(json),
      salesCount: _integer(json, 'salesCount', minimum: 0),
      rating: _number(json, 'rating', minimum: 0, maximum: 5),
      createdAt: _date(json, 'createdAt'),
      updatedAt: _date(json, 'updatedAt'),
    );
  }

  Map<String, Object?> _detailToJson(
    AudioDetail detail,
    Map<String, Object?> additionalFields,
  ) {
    return <String, Object?>{
      'schemaVersion': 1,
      'type': 'audio-detail',
      'targetType': detail.target.targetType.backupValue,
      'targetPath': detail.target.targetPath,
      'rjCode': detail.rjCode,
      'workTitle': detail.workTitle,
      'circleName': detail.circleName,
      'voiceActors': detail.voiceActors,
      'tags': detail.tags,
      'cardCoverPath': detail.cardCoverPath,
      'cardCoverSelected': detail.cardCoverSelected,
      'releaseDate': detail.releaseDate?.toIso8601String(),
      'durationMs': detail.duration?.inMilliseconds,
      'salesCount': detail.salesCount,
      'rating': detail.rating,
      'createdAt': detail.createdAt?.toIso8601String(),
      'updatedAt': detail.updatedAt?.toIso8601String(),
      ...additionalFields,
    };
  }

  Uint8List _encode(Object? value) => Uint8List.fromList(
    utf8.encode(const JsonEncoder.withIndent('  ').convert(value)),
  );
}

String _string(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return '';
  if (value is! String) throw FormatException('Invalid field: $field');
  return value;
}

String? _nullableString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! String) throw FormatException('Invalid field: $field');
  return value;
}

List<String> _stringList(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return const <String>[];
  if (value is! List || value.any((item) => item is! String)) {
    throw FormatException('Invalid field: $field');
  }
  return AudioDetail.normalizeList(value.cast<String>());
}

DateTime? _date(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Invalid field: $field');
  }
  final parsed = DateTime.tryParse(value.trim());
  if (parsed == null) throw FormatException('Invalid field: $field');
  return parsed;
}

Duration? _duration(Map<String, Object?> json) {
  final value = json['durationMs'];
  if (value == null) return null;
  final milliseconds = _integer(json, 'durationMs', minimum: 1);
  return Duration(milliseconds: milliseconds!);
}

int? _integer(Map<String, Object?> json, String field, {required int minimum}) {
  final value = json[field];
  if (value == null) return null;
  final parsed = switch (value) {
    int number => number,
    num number when number == number.toInt() => number.toInt(),
    String text => int.tryParse(text.trim()),
    _ => null,
  };
  if (parsed == null || parsed < minimum) {
    throw FormatException('Invalid field: $field');
  }
  return parsed;
}

double? _number(
  Map<String, Object?> json,
  String field, {
  required double minimum,
  required double maximum,
}) {
  final value = json[field];
  if (value == null) return null;
  final parsed = switch (value) {
    num number => number.toDouble(),
    String text => double.tryParse(text.trim()),
    _ => null,
  };
  if (parsed == null ||
      !parsed.isFinite ||
      parsed < minimum ||
      parsed > maximum) {
    throw FormatException('Invalid field: $field');
  }
  return parsed;
}
