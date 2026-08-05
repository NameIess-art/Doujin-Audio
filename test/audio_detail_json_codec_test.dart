import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/audio_detail.dart';
import 'package:nameless_audio/features/library/data/audio_detail_json_codec.dart';

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
}
