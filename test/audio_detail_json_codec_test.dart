import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/core/media/time_segment_label.dart';
import 'package:doujin_audio/features/library/data/audio_detail_json_codec.dart';

void main() {
  const codec = AudioDetailJsonCodec();

  test('folder document round-trips schema v1 extended fields', () {
    final target = AudioDetailTarget.libraryRootFolder('/library/work');
    final detail = AudioDetail.empty(target).copyWith(
      workTitle: 'Work',
      voiceActors: const <String>['A', 'B'],
      tags: const <String>['tag'],
      duration: const Duration(seconds: 12),
      rating: 4.5,
    );

    final restored = codec.decode(codec.encodeNew(detail), target);

    expect(restored.workTitle, 'Work');
    expect(restored.voiceActors, const <String>['A', 'B']);
    expect(restored.tags, const <String>['tag']);
    expect(restored.duration, const Duration(seconds: 12));
    expect(restored.rating, 4.5);
  });

  test('manual merge preserves unknown fields and unrelated list entries', () {
    final target = AudioDetailTarget.singleAudioFile('/library/one.mp3');
    final existing = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<Object?>[
          <String, Object?>{
            'schemaVersion': 1,
            'type': 'audio-detail',
            'targetPath': '/library/other.mp3',
            'workTitle': 'Other',
            'foreign': 1,
          },
          <String, Object?>{
            'schemaVersion': 1,
            'type': 'audio-detail',
            'targetPath': '/library/one.mp3',
            'workTitle': 'Old',
            'unknown': <String, Object?>{'kept': true},
          },
        ]),
      ),
    );

    final merged =
        jsonDecode(
              utf8.decode(
                codec.merge(
                  existing,
                  AudioDetail.empty(target).copyWith(workTitle: 'New'),
                ),
              ),
            )
            as List<Object?>;

    expect((merged.first as Map)['foreign'], 1);
    expect((merged.first as Map)['workTitle'], 'Other');
    expect((merged[1] as Map)['unknown'], <String, Object?>{'kept': true});
    expect((merged[1] as Map)['workTitle'], 'New');
  });

  test('retarget replaces a list entry in place and keeps stable order', () {
    final previous = AudioDetailTarget.singleAudioFile('/library/old.mp3');
    final detail = AudioDetail.empty(
      AudioDetailTarget.singleAudioFile('/library/new.mp3'),
    ).copyWith(workTitle: 'Renamed');
    final existing = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<Object?>[
          <String, Object?>{
            'schemaVersion': 1,
            'type': 'audio-detail',
            'targetPath': '/library/old.mp3',
            'unknown': 7,
          },
          <String, Object?>{'targetPath': '/library/other.mp3'},
        ]),
      ),
    );

    final merged =
        jsonDecode(
              utf8.decode(
                codec.merge(existing, detail, previousTarget: previous),
              ),
            )
            as List<Object?>;

    expect((merged.first as Map)['targetPath'], '/library/new.mp3');
    expect((merged.first as Map)['unknown'], 7);
    expect((merged[1] as Map)['targetPath'], '/library/other.mp3');
  });

  test('blank truncated and wrong field types are rejected on import', () {
    final target = AudioDetailTarget.libraryRootFolder('/library/work');
    for (final bytes in <Uint8List>[
      Uint8List.fromList(utf8.encode('  ')),
      Uint8List.fromList(utf8.encode('{')),
      Uint8List.fromList(
        utf8.encode('{"schemaVersion":1,"type":"audio-detail","tags":{}}'),
      ),
      Uint8List.fromList(
        utf8.encode(
          '{"schemaVersion":1,"type":"audio-detail",'
          '"targetType":"single-audio-file"}',
        ),
      ),
    ]) {
      expect(() => codec.decode(bytes, target), throwsFormatException);
    }
  });

  test(
    'timeSegmentFields skips unrepresentable track paths and allows POSIX colons',
    () {
      final target = AudioDetailTarget.libraryRootFolder('/library/work');
      final now = DateTime.utc(2026);
      TimeSegmentLabel makeLabel(String id, String trackKey) =>
          TimeSegmentLabel(
            id: id,
            trackKey: trackKey,
            name: 'Seg $id',
            start: const Duration(seconds: 1),
            end: const Duration(seconds: 10),
            colorValue: 0xff112233,
            createdAt: now,
            updatedAt: now,
          );

      final fields = codec.timeSegmentFields(target, [
        makeLabel('outside', '/other/track.mp3'),
        makeLabel('root', '/library/work'),
        makeLabel('posix-colon', '/library/work/01: Intro.mp3'),
      ]);
      final encodedList = fields['timeSegmentLabels'] as List<Object?>;
      expect(encodedList, hasLength(1));
      expect(
        (encodedList.single as Map<String, Object?>)['trackPath'],
        '01: Intro.mp3',
      );

      final bytes = codec.encodeNew(
        AudioDetail.empty(target),
        additionalFields: fields,
      );
      final decoded = codec.decodeDocument(bytes, target);
      expect(decoded.timeSegmentLabels, hasLength(1));
      expect(
        PathMatcher.equalsNormalized(
          decoded.timeSegmentLabels.single.trackKey,
          '/library/work/01: Intro.mp3',
        ),
        isTrue,
      );

      for (final badPath in <String>[
        'C:/outside.mp3',
        'C:relative.mp3',
        'content://provider/track.mp3',
        'tree::sub/01.mp3',
      ]) {
        final badBytes = Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'type': 'audio-detail',
              'timeSegmentLabels': [
                <String, Object?>{
                  'id': 'bad',
                  'trackPath': badPath,
                  'name': 'Bad',
                  'startMs': 1000,
                  'endMs': 2000,
                  'colorValue': 0xff112233,
                  'createdAt': now.toIso8601String(),
                  'updatedAt': now.toIso8601String(),
                },
              ],
            }),
          ),
        );
        expect(
          () => codec.decodeDocument(badBytes, target),
          throwsFormatException,
          reason: 'Expected $badPath to be rejected',
        );
      }
    },
  );
}
