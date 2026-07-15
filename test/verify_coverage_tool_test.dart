import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporaryDirectory;
  late String verifierPath;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'nameless_audio_coverage_verifier_',
    );
    verifierPath = File('tool/verify_coverage.dart').absolute.path;
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('aggregates all files matching a configured module prefix', () async {
    final result = await _runVerifier(
      verifierPath: verifierPath,
      directory: temporaryDirectory,
      baseline: <String, Object?>{
        'minimumTotalLineCoveragePercent': 70,
        'moduleMinimumLineCoveragePercent': <String, num>{'lib/feature/': 75},
      },
      lcov: _lcov(<({String path, int found, int hit})>[
        (path: 'lib/feature/first.dart', found: 10, hit: 10),
        (path: 'lib/feature/second.dart', found: 10, hit: 5),
      ]),
    );

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('Module lib/feature/: 75.00%'));
  });

  test('fails when total or module coverage is below its threshold', () async {
    final result = await _runVerifier(
      verifierPath: verifierPath,
      directory: temporaryDirectory,
      baseline: <String, Object?>{
        'minimumTotalLineCoveragePercent': 80,
        'moduleMinimumLineCoveragePercent': <String, num>{'lib/feature/': 90},
      },
      lcov: _lcov(<({String path, int found, int hit})>[
        (path: 'lib/feature/value.dart', found: 10, hit: 7),
      ]),
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('Coverage check failed.'));
  });

  test(
    'fails when a configured module prefix has no coverage records',
    () async {
      final result = await _runVerifier(
        verifierPath: verifierPath,
        directory: temporaryDirectory,
        baseline: <String, Object?>{
          'minimumTotalLineCoveragePercent': 50,
          'moduleMinimumLineCoveragePercent': <String, num>{'lib/missing/': 50},
        },
        lcov: _lcov(<({String path, int found, int hit})>[
          (path: 'lib/present/value.dart', found: 10, hit: 10),
        ]),
      );

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('lib/missing/'));
    },
  );
}

Future<ProcessResult> _runVerifier({
  required String verifierPath,
  required Directory directory,
  required Map<String, Object?> baseline,
  required String lcov,
}) async {
  final baselineFile = File('${directory.path}/baseline.json');
  final lcovFile = File('${directory.path}/lcov.info');
  await baselineFile.writeAsString(jsonEncode(baseline));
  await lcovFile.writeAsString(lcov);
  return Process.run(Platform.isWindows ? 'dart.bat' : 'dart', <String>[
    'run',
    verifierPath,
    lcovFile.path,
    baselineFile.path,
  ], runInShell: true);
}

String _lcov(List<({String path, int found, int hit})> records) {
  final buffer = StringBuffer();
  for (final record in records) {
    buffer
      ..writeln('SF:${record.path}')
      ..writeln('LF:${record.found}')
      ..writeln('LH:${record.hit}')
      ..writeln('end_of_record');
  }
  return buffer.toString();
}
