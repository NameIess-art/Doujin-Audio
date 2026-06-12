import 'dart:async';
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

  static String? get logDirectoryPath => _logDirectoryPath;

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
    _sink?.writeln('$timestamp [$level] ${sanitize(message)}');
  }

  @visibleForTesting
  static String sanitize(String message) {
    var sanitized = message.replaceAll(
      RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      'Bearer [REDACTED]',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'''\b(token|password|passwd|authorization|api[_-]?key|access[_-]?token|refresh[_-]?token)\b(\s*[:=]\s*|"\s*:\s*")([^,\s&}"']+)''',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}${match.group(2)}[REDACTED]',
    );
    sanitized = sanitized.replaceAllMapped(RegExp(r'https?://[^\s]+'), (match) {
      final value = match.group(0)!;
      final uri = Uri.tryParse(value);
      if (uri == null || !uri.hasQuery) return value;
      return uri.replace(query: '').toString();
    });
    return sanitized;
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
