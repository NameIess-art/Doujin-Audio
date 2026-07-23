import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

abstract final class AppLogService {
  static const _logFileName = 'nameless_audio.log';
  static const _maxLogBytes = 1024 * 1024;

  static IOSink? _sink;
  static DebugPrintCallback? _previousDebugPrint;
  static bool _initialized = false;
  static String? _logDirectoryPath;
  static int _bytesSinceRotation = 0;
  static bool _rotationScheduled = false;
  static Future<void> _rotationTask = Future<void>.value();
  static final List<String> _pendingWrites = <String>[];

  static String? get logDirectoryPath => _logDirectoryPath;
  static bool get _performanceLoggingEnabled => kDebugMode || kProfileMode;

  static Future<void> initialize() async {
    if (_initialized) return;
    _previousDebugPrint = debugPrint;

    try {
      final supportDir = await getApplicationSupportDirectory();
      final logDir = Directory(path.join(supportDir.path, 'logs'));
      await logDir.create(recursive: true);
      _logDirectoryPath = logDir.path;

      final logFile = File(path.join(logDir.path, _logFileName));
      await _rotateIfNeeded(logFile);
      _sink = logFile.openWrite(mode: FileMode.append);
      _bytesSinceRotation = await logFile.length();
      _write('INFO', 'logging_started directory=${logDir.path}');
    } catch (error, stackTrace) {
      _previousDebugPrint?.call(
        'AppLogService.initialize failed: $error\n$stackTrace',
      );
    }

    debugPrint = _debugPrint;
    _initialized = true;
  }

  static void installFlutterErrorHandler() {
    final previousHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      _write('FLUTTER', details.exceptionAsString());
      final stack = details.stack;
      if (stack != null) {
        _write('STACK', stack.toString());
      }

      if (previousHandler != null) {
        previousHandler(details);
      } else {
        FlutterError.presentError(details);
      }
    };
  }

  static void installPlatformErrorHandler() {
    final previousHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stackTrace) {
      AppLogService.error(
        'platform_uncaught_error',
        error: error,
        stackTrace: stackTrace,
      );
      return previousHandler?.call(error, stackTrace) ?? false;
    };
  }

  static void info(String message) {
    _write('INFO', message);
  }

  static void warning(String message, {Object? error, StackTrace? stackTrace}) {
    _writeWithError('WARNING', message, error: error, stackTrace: stackTrace);
  }

  static void error(String message, {Object? error, StackTrace? stackTrace}) {
    _writeWithError('ERROR', message, error: error, stackTrace: stackTrace);
  }

  static Future<T> measureAsync<T>(
    String event,
    Future<T> Function() action, {
    Map<String, Object?> details = const <String, Object?>{},
  }) async {
    if (!_performanceLoggingEnabled) return action();
    final task = developer.TimelineTask()..start(event, arguments: details);
    final stopwatch = Stopwatch()..start();
    try {
      return await action();
    } finally {
      stopwatch.stop();
      final elapsedMs = stopwatch.elapsedMilliseconds;
      task.finish(arguments: <String, Object?>{'elapsedMs': elapsedMs});
      _write('PERF', '$event elapsedMs=$elapsedMs${_formatDetails(details)}');
    }
  }

  static T measureSync<T>(
    String event,
    T Function() action, {
    Map<String, Object?> details = const <String, Object?>{},
  }) {
    if (!_performanceLoggingEnabled) return action();
    final task = developer.TimelineTask()..start(event, arguments: details);
    final stopwatch = Stopwatch()..start();
    try {
      return action();
    } finally {
      stopwatch.stop();
      final elapsedMs = stopwatch.elapsedMilliseconds;
      task.finish(arguments: <String, Object?>{'elapsedMs': elapsedMs});
      _write('PERF', '$event elapsedMs=$elapsedMs${_formatDetails(details)}');
    }
  }

  static void logZoneError(Object error, StackTrace stackTrace) {
    AppLogService.error(
      'zone_uncaught_error',
      error: error,
      stackTrace: stackTrace,
    );
  }

  static void _debugPrint(String? message, {int? wrapWidth}) {
    if (message != null && message.isNotEmpty) {
      _write('DEBUG', message);
    }
    _previousDebugPrint?.call(message, wrapWidth: wrapWidth);
  }

  static Future<void> _rotateIfNeeded(File logFile) async {
    if (!await logFile.exists()) return;
    final length = await logFile.length();
    if (length <= _maxLogBytes) return;

    final rotatedFile = File('${logFile.path}.1');
    if (await rotatedFile.exists()) {
      await rotatedFile.delete();
    }
    await logFile.rename(rotatedFile.path);
  }

  static void _write(String level, String message) {
    final timestamp = DateTime.now().toIso8601String();
    final line = '$timestamp [$level] ${sanitize(message)}';
    final sink = _sink;
    if (sink == null) {
      if (_pendingWrites.length < 128) _pendingWrites.add(line);
      return;
    }
    sink.writeln(line);
    _bytesSinceRotation += utf8.encode('$line\n').length;
    if (_bytesSinceRotation > _maxLogBytes && !_rotationScheduled) {
      _rotationScheduled = true;
      _rotationTask = _rotationTask.then((_) => _rotateRuntime());
    }
  }

  static Future<void> _rotateRuntime() async {
    try {
      final directory = _logDirectoryPath;
      if (directory == null) return;
      final logFile = File(path.join(directory, _logFileName));
      final sink = _sink;
      _sink = null;
      await sink?.flush();
      await sink?.close();
      await _rotateIfNeeded(logFile);
      _sink = logFile.openWrite(mode: FileMode.append);
      _bytesSinceRotation = await logFile.length();
      final pending = List<String>.from(_pendingWrites);
      _pendingWrites.clear();
      for (final line in pending) {
        _sink!.writeln(line);
        _bytesSinceRotation += utf8.encode('$line\n').length;
      }
    } catch (error, stackTrace) {
      _previousDebugPrint?.call(
        'AppLogService runtime rotation failed: $error\n$stackTrace',
      );
      if (_sink == null && _logDirectoryPath != null) {
        final logFile = File(path.join(_logDirectoryPath!, _logFileName));
        _sink = logFile.openWrite(mode: FileMode.append);
      }
    } finally {
      _rotationScheduled = false;
    }
  }

  static String sanitize(String message) {
    var sanitized = message.replaceAllMapped(RegExp(r'https?://[^\s]+'), (
      match,
    ) {
      final value = match.group(0)!;
      final uri = Uri.tryParse(value);
      if (uri == null || !uri.hasQuery) return value;
      return uri.replace(query: '').toString();
    });
    sanitized = sanitized.replaceAll(
      RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      'Bearer [REDACTED]',
    );
    const sensitiveKey =
        r'(?:token|password|passwd|authorization|api[_-]?key|access[_-]?token|refresh[_-]?token)';
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        '"($sensitiveKey)"(\\s*:\\s*)"(?:\\\\.|[^"\\\\])*"',
        caseSensitive: false,
      ),
      (match) => '"${match.group(1)}"${match.group(2)}"[REDACTED]"',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        "'($sensitiveKey)'(\\s*:\\s*)'(?:\\\\.|[^'\\\\])*'",
        caseSensitive: false,
      ),
      (match) => "'${match.group(1)}'${match.group(2)}'[REDACTED]'",
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        '$sensitiveKey(\\s*[:=]\\s*)"(?:\\\\.|[^"\\\\])*"',
        caseSensitive: false,
      ),
      (match) {
        final prefix = match
            .group(0)!
            .substring(0, match.group(0)!.indexOf('"') + 1);
        return '$prefix[REDACTED]"';
      },
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        "$sensitiveKey(\\s*[:=]\\s*)'(?:\\\\.|[^'\\\\])*'",
        caseSensitive: false,
      ),
      (match) {
        final prefix = match
            .group(0)!
            .substring(0, match.group(0)!.indexOf("'") + 1);
        return "$prefix[REDACTED]'";
      },
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        '\\b($sensitiveKey)\\b(\\s*[:=]\\s*)(?!["\\\'])'
        '([^,;&\\r\\n}]*?)'
        '(?=\\s+\\b$sensitiveKey\\b\\s*[:=]|[,;&\\r\\n}]|\$)',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}${match.group(2)}[REDACTED]',
    );
    return sanitized;
  }

  static String _formatDetails(Map<String, Object?> details) {
    if (details.isEmpty) return '';
    final encoded = details.entries
        .where((entry) => entry.value != null)
        .map((entry) => '${entry.key}=${entry.value}')
        .join(' ');
    return encoded.isEmpty ? '' : ' $encoded';
  }

  static void _writeWithError(
    String level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    final details = StringBuffer(message);
    if (error != null) {
      details.write(' error=$error');
    }
    if (stackTrace != null) {
      details.write('\n$stackTrace');
    }
    _write(level, details.toString());
  }

  static Future<void> dispose() async {
    final sink = _sink;
    _sink = null;
    await sink?.flush();
    await sink?.close();
  }
}
