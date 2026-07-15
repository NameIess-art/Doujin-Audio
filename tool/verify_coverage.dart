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
  final moduleMinimums = _readModuleMinimums(
    baseline,
    'moduleMinimumLineCoveragePercent',
  );
  final records = _parseLcov(lcovFile.readAsLinesSync());

  final totalFound = records.fold<int>(0, (sum, record) => sum + record.found);
  final totalHit = records.fold<int>(0, (sum, record) => sum + record.hit);
  final totalPercent = _coveragePercent(totalHit, totalFound);
  stdout.writeln(
    'Total line coverage: ${totalPercent.toStringAsFixed(2)}% '
    '($totalHit/$totalFound), required >= ${minimumTotal.toStringAsFixed(0)}%',
  );

  var failed = totalPercent < minimumTotal;
  for (final entry in moduleMinimums.entries) {
    final matchingRecords = records
        .where((record) => record.path.startsWith(entry.key))
        .toList(growable: false);
    if (matchingRecords.isEmpty) {
      stderr.writeln(
        'Coverage check failed: configured module prefix has no records: '
        '${entry.key}',
      );
      failed = true;
      continue;
    }
    final found = matchingRecords.fold<int>(
      0,
      (sum, record) => sum + record.found,
    );
    final hit = matchingRecords.fold<int>(0, (sum, record) => sum + record.hit);
    final percent = _coveragePercent(hit, found);
    stdout.writeln(
      'Module ${entry.key}: ${percent.toStringAsFixed(2)}% '
      '($hit/$found across ${matchingRecords.length} files), required >= '
      '${entry.value.toStringAsFixed(0)}%',
    );
    if (percent < entry.value) {
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
  if (value is num && value >= 0 && value <= 100) return value;
  throw FormatException(
    'Coverage baseline `$key` must be numeric and between 0 and 100.',
  );
}

Map<String, num> _readModuleMinimums(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! Map<String, dynamic> || value.isEmpty) {
    throw FormatException(
      'Coverage baseline `$key` must be a non-empty object.',
    );
  }
  return <String, num>{
    for (final entry in value.entries)
      if (entry.key.trim().isNotEmpty)
        entry.key.replaceAll(r'\', '/'): _readPercent(value, entry.key),
  };
}

List<_CoverageRecord> _parseLcov(List<String> lines) {
  final records = <_CoverageRecord>[];
  String? path;
  var found = 0;
  var hit = 0;
  for (final line in lines) {
    if (line.startsWith('SF:')) {
      path = _normalizeCoveragePath(line.substring(3));
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

String _normalizeCoveragePath(String value) {
  final normalized = value.replaceAll(r'\', '/');
  if (normalized.startsWith('lib/')) return normalized;
  final libIndex = normalized.lastIndexOf('/lib/');
  return libIndex == -1 ? normalized : normalized.substring(libIndex + 1);
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
