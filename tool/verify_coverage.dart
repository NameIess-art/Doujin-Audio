import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

void main(List<String> args) {
  final lcovPath = args.isNotEmpty ? args[0] : 'coverage/lcov.info';
  final baselinePath = args.length > 1
      ? args[1]
      : 'tool/coverage_baseline.json';

  final baselineFile = File(baselinePath);
  if (!baselineFile.existsSync()) {
    stderr.writeln('Coverage baseline not found: $baselinePath');
    exitCode = 1;
    return;
  }
  final lcovFile = File(lcovPath);
  if (!lcovFile.existsSync()) {
    stderr.writeln('Coverage report not found: $lcovPath');
    stderr.writeln('Run `flutter test --coverage` first.');
    exitCode = 1;
    return;
  }

  final baseline = json.decode(baselineFile.readAsStringSync());
  if (baseline is! Map<String, dynamic>) {
    stderr.writeln('Coverage baseline must be a JSON object.');
    exitCode = 1;
    return;
  }

  final minimumTotal = _readPercent(
    baseline,
    'minimumTotalLineCoveragePercent',
  );
  final criticalMinimum = _readPercent(
    baseline,
    'criticalModuleMinimumLineCoveragePercent',
  );
  final criticalPrefixes = _readStringList(baseline['criticalPathPrefixes']);
  final records = _parseLcov(lcovFile.readAsLinesSync());

  final totalFound = records.fold<int>(0, (sum, record) => sum + record.found);
  final totalHit = records.fold<int>(0, (sum, record) => sum + record.hit);
  final totalPercent = _coveragePercent(totalHit, totalFound);
  final flooredTotal = totalPercent.floor();

  stdout.writeln(
    'Total line coverage: ${totalPercent.toStringAsFixed(2)}% '
    '($totalHit/$totalFound), required >= ${minimumTotal.toStringAsFixed(0)}%',
  );

  var failed = flooredTotal < minimumTotal;
  for (final record in records) {
    if (!criticalPrefixes.any(record.path.startsWith)) {
      continue;
    }
    final percent = _coveragePercent(record.hit, record.found);
    stdout.writeln(
      'Critical module ${record.path}: ${percent.toStringAsFixed(2)}% '
      '(${record.hit}/${record.found}), required >= '
      '${criticalMinimum.toStringAsFixed(0)}%',
    );
    if (percent < criticalMinimum) {
      failed = true;
    }
  }

  if (failed) {
    stderr.writeln('Coverage check failed.');
    exitCode = 1;
  }
}

num _readPercent(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is num) return value;
  throw FormatException('Coverage baseline `$key` must be numeric.');
}

List<String> _readStringList(Object? value) {
  if (value == null) return const <String>[];
  if (value is List) {
    return value.whereType<String>().toList(growable: false);
  }
  throw const FormatException(
    'Coverage baseline `criticalPathPrefixes` must be a string array.',
  );
}

List<_CoverageRecord> _parseLcov(List<String> lines) {
  final records = <_CoverageRecord>[];
  String? path;
  var found = 0;
  var hit = 0;
  for (final line in lines) {
    if (line.startsWith('SF:')) {
      path = line.substring(3).replaceAll(r'\', '/');
      found = 0;
      hit = 0;
    } else if (line.startsWith('LF:')) {
      found = int.parse(line.substring(3));
    } else if (line.startsWith('LH:')) {
      hit = int.parse(line.substring(3));
    } else if (line == 'end_of_record' && path != null) {
      records.add(_CoverageRecord(path: path, found: found, hit: hit));
      path = null;
    }
  }
  if (records.isEmpty) {
    throw const FormatException('Coverage report contains no records.');
  }
  return records;
}

double _coveragePercent(int hit, int found) {
  if (found == 0) return 100;
  return math.max(0, math.min(100, hit * 100 / found));
}

class _CoverageRecord {
  const _CoverageRecord({
    required this.path,
    required this.found,
    required this.hit,
  });

  final String path;
  final int found;
  final int hit;
}
