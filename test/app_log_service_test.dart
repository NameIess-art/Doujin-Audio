import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/logging/app_log_service.dart';
import 'package:path/path.dart' as path;

void main() {
  tearDown(() async {
    await AppLogService.resetForTest();
  });
  test('sanitizes credentials and authorization headers', () {
    final sanitized = AppLogService.sanitize(
      'token=secret password: hunter2 Authorization: Bearer abc.def.ghi',
    );

    expect(sanitized, isNot(contains('secret')));
    expect(sanitized, isNot(contains('hunter2')));
    expect(sanitized, isNot(contains('abc.def.ghi')));
    expect(sanitized, contains('[REDACTED]'));
  });

  test('removes URL query parameters while retaining endpoint path', () {
    final sanitized = AppLogService.sanitize(
      'request=https://example.com/api/search?q=private&token=secret',
    );

    expect(sanitized, contains('https://example.com/api/search'));
    expect(sanitized, isNot(contains('private')));
    expect(sanitized, isNot(contains('secret')));
  });

  test('redacts quoted and multi-word credential values', () {
    final sanitized = AppLogService.sanitize(
      'password="correct horse battery staple" '
      "refresh_token='first second' token=plain value; status=failed",
    );

    expect(sanitized, isNot(contains('correct horse battery staple')));
    expect(sanitized, isNot(contains('first second')));
    expect(sanitized, isNot(contains('plain value')));
    expect(sanitized, contains('status=failed'));
  });

  test('redacts escaped JSON secrets and multiple values on one line', () {
    final sanitized = AppLogService.sanitize(
      r'{"password":"two words with \"quotes\"","token":"abc def"} '
      'Authorization: Bearer header.secret',
    );

    expect(sanitized, isNot(contains('two words')));
    expect(sanitized, isNot(contains('abc def')));
    expect(sanitized, isNot(contains('header.secret')));
  });

  test('sanitizing an already redacted message is idempotent', () {
    const input = 'token=[REDACTED] password: [REDACTED]';

    expect(AppLogService.sanitize(AppLogService.sanitize(input)), input);
  });

  test('redacts apostrophes inside unquoted multi-word values', () {
    final sanitized = AppLogService.sanitize(
      "password=don't share this; token=visible-secret",
    );

    expect(sanitized, isNot(contains("don't share this")));
    expect(sanitized, isNot(contains('visible-secret')));
    expect(sanitized, 'password=[REDACTED]; token=[REDACTED]');
  });

  test('initialize creates and writes log file on fresh install', () async {
    final tempDir = await Directory.systemTemp.createTemp('app_log_fresh_');
    addTearDown(() async {
      await AppLogService.resetForTest();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    AppLogService.info('buffered_before_init');
    await AppLogService.initialize(supportDirectoryProvider: () async => tempDir);
    AppLogService.info('written_after_init');
    await AppLogService.dispose();

    final logFile = File(path.join(tempDir.path, 'logs', 'doujin_audio.log'));
    expect(AppLogService.logDirectoryPath, path.join(tempDir.path, 'logs'));
    expect(await logFile.exists(), isTrue);
    final contents = await logFile.readAsString();
    expect(contents, contains('buffered_before_init'));
    expect(contents, contains('logging_started'));
    expect(contents, contains('written_after_init'));
  });

  test('initialize and runtime rotation handle rotated files cleanly', () async {
    final tempDir = await Directory.systemTemp.createTemp('app_log_rotate_');
    addTearDown(() async {
      await AppLogService.resetForTest();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final logsDir = Directory(path.join(tempDir.path, 'logs'));
    await logsDir.create(recursive: true);
    final logFile = File(path.join(logsDir.path, 'doujin_audio.log'));
    final rotatedFile = File(path.join(logsDir.path, 'doujin_audio.log.1'));

    // Exceed 1 MiB before startup to trigger startup rotation.
    await logFile.writeAsString('A' * (1024 * 1024 + 64), flush: true);

    await AppLogService.initialize(supportDirectoryProvider: () async => tempDir);
    AppLogService.info('after_startup_rotation');
    await AppLogService.dispose();

    expect(await rotatedFile.exists(), isTrue);
    expect(await logFile.exists(), isTrue);
    expect(await logFile.readAsString(), contains('after_startup_rotation'));

    // Re-initialize and trigger runtime rotation.
    await AppLogService.resetForTest();
    await AppLogService.initialize(supportDirectoryProvider: () async => tempDir);
    final chunk = 'B' * 65536;
    for (var i = 0; i < 18; i++) {
      AppLogService.info('chunk_$i $chunk');
    }
    AppLogService.info('after_runtime_rotation');
    await AppLogService.dispose();

    expect(await rotatedFile.exists(), isTrue);
    expect(await logFile.exists(), isTrue);
    final activeText = await logFile.readAsString();
    final archivedText = await rotatedFile.readAsString();
    expect(activeText + archivedText, contains('after_runtime_rotation'));
  });
}
