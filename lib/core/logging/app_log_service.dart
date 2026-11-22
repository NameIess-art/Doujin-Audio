import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

abstract final class AppLogService {
  static const _logFileName = 'doujin_audio.log';
  static const _maxLogBytes = 1024 * 1024;
  static const _sensitiveKey =
      r'(?:token|password|passwd|authorization|api[_-]?key|access[_-]?token|refresh[_-]?token)';
  static final _httpUrl = RegExp(r'https?://[^\s]+');
  static final _bearerToken = RegExp(
    r'\bBearer\s+[A-Za-z0-9._~+/=-]+',
    caseSensitive: false,
  );
  static final _doubleQuotedKeyValue = RegExp(
    '"($_sensitiveKey)"(\\s*:\\s*)"(?:\\\\.|[^"\\\\])*"',
    caseSensitive: false,
  );
  static final _singleQuotedKeyValue = RegExp(
    "'($_sensitiveKey)'(\\s*:\\s*)'(?:\\\\.|[^'\\\\])*'",
    caseSensitive: false,
  );
  static final _doubleQuotedValue = RegExp(
    '$_sensitiveKey(\\s*[:=]\\s*)"(?:\\\\.|[^"\\\\])*"',
    caseSensitive: false,
  );
  static final _singleQuotedValue = RegExp(
    "$_sensitiveKey(\\s*[:=]\\s*)'(?:\\\\.|[^'\\\\])*'",
    caseSensitive: false,
  );
  static final _unquotedValue = RegExp(
    '\\b($_sensitiveKey)\\b(\\s*[:=]\\s*)(?!["\\\'])'
    '([^,;&\\r\\n}]*?)'
    '(?=\\s+\\b$_sensitiveKey\\b\\s*[:=]|[,;&\\r\\n}]|\$)',
    caseSensitive: false,
  );

  static IOSink? _sink;
  static DebugPrintCallback? _previousDebugPrint;
  static bool _initialized = false;
  static Future<void>? _initializing;
  static String? _logDirectoryPath;
  static int _bytesSinceRotation = 0;
  static bool _rotationScheduled = false;
  static Future<void> _rotationTask = Future<void>.value();
  static final List<String> _pendingWrites = <String>[];

  static String? get logDirectoryPath => _logDirectoryPath;
  static bool get _performanceLoggingEnabled => kDebugMode || kProfileMode;

  static Future<void> initialize({
    @visibleForTesting
    Future<Directory> Function()? supportDirectoryProvider,
  }) {
    if (_initialized) return Future<void>.value();
    return _initializing ??= _initializeInternal(
      supportDirectoryProvider: supportDirectoryProvider,
    );
  }

  static Future<void> ensureInitialized() => initialize();

  static Future<void> _initializeInternal({
    Future<Directory> Function()? supportDirectoryProvider,
  }) async {
    _previousDebugPrint = debugPrint;

    try {
      final supportDir =
          await (supportDirectoryProvider ?? getApplicationSupportDirectory)();
      final logDir = Directory(path.join(supportDir.path, 'logs'));
      await logDir.create(recursive: true);
      _logDirectoryPath = logDir.path;

      final logFile = File(path.join(logDir.path, _logFileName));
      _bytesSinceRotation = await _rotateIfNeeded(logFile);
      final sink = logFile.openWrite(mode: FileMode.append);
      _sink = sink;
      _drainPendingWrites(sink);
      _write('INFO', 'logging_started directory=${logDir.path}');
    } catch (error, stackTrace) {
      _previousDebugPrint?.call(
        'AppLogService.initialize failed: $error\n$stackTrace',
      );
    } finally {
      debugPrint = _debugPrint;
      _initialized = true;
      _initializing = null;
    }
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

  static T measureSync<T>(
    String event,
    T Function() action, {
    Map<String, Object?> details = const <String, Object?>{},
  }) {
    if (!_performanceLoggingEnabled) return action();
    final stopwatch = Stopwatch()..start();
    try {
      return developer.Timeline.timeSync(event, action, arguments: details);
    } finally {
      stopwatch.stop();
      _write(
        'PERF',
        '$event elapsedUs=${stopwatch.elapsedMicroseconds}${_formatDetails(details)}',
      );
    }
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

  static Future<int> _rotateIfNeeded(File logFile) async {
    if (!await logFile.exists()) return 0;
    final length = await logFile.length();
    if (length <= _maxLogBytes) return length;

    final rotatedFile = File('${logFile.path}.1');
    if (await rotatedFile.exists()) {
      await rotatedFile.delete();
    }
    await logFile.rename(rotatedFile.path);
    return 0;
  }

  static void _write(String level, String message) {
    final timestamp = DateTime.now().toIso8601String();
    final line = '$timestamp [$level] ${sanitize(message)}';
    final sink = _sink;
    if (sink == null) {
      if (_pendingWrites.length < 128) _pendingWrites.add(line);
      return;
    }
    _writeLine(sink, line);
    if (_bytesSinceRotation > _maxLogBytes && !_rotationScheduled) {
      _rotationScheduled = true;
      _rotationTask = _rotationTask.then((_) => _rotateRuntime());
    }
  }

  static void _writeLine(IOSink sink, String line) {
    final bytes = utf8.encode('$line\n');
    sink.add(bytes);
    _bytesSinceRotation += bytes.length;
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
      final existingBytes = await _rotateIfNeeded(logFile);
      final nextSink = logFile.openWrite(mode: FileMode.append);
      _bytesSinceRotation = existingBytes;
      _sink = nextSink;
      _drainPendingWrites(nextSink);
    } catch (error, stackTrace) {
      _previousDebugPrint?.call(
        'AppLogService runtime rotation failed: $error\n$stackTrace',
      );
      if (_sink == null && _logDirectoryPath != null) {
        final logFile = File(path.join(_logDirectoryPath!, _logFileName));
        _bytesSinceRotation = 0;
        _sink = logFile.openWrite(mode: FileMode.append);
      }
    } finally {
      _rotationScheduled = false;
    }
  }

  static void _drainPendingWrites(IOSink sink) {
    for (final line in _pendingWrites) {
      _writeLine(sink, line);
    }
    _pendingWrites.clear();
  }

  static String sanitize(String message) {
    if (message.isEmpty) return message;
    final hasUrl = message.contains('://');
    final hasDelimiter = hasUrl || message.contains(':') || message.contains('=');
    if (!hasDelimiter && !message.contains('b') && !message.contains('B')) {
      return message;
    }
    final lower = message.toLowerCase();
    final hasBearer = lower.contains('bearer');
    final hasSensitiveKey =
        hasDelimiter &&
        (lower.contains('token') ||
            lower.contains('passw') ||
            lower.contains('authorization') ||
            lower.contains('api'));
    if (!hasUrl && !hasBearer && !hasSensitiveKey) {
      return message;
    }
    var sanitized = message;
    if (hasUrl) {
      sanitized = sanitized.replaceAllMapped(_httpUrl, (match) {
        final value = match.group(0)!;
        final uri = Uri.tryParse(value);
        if (uri == null || !uri.hasQuery) return value;
        return uri.replace(query: '').toString();
      });
    }
    if (hasBearer) {
      sanitized = sanitized.replaceAll(_bearerToken, 'Bearer [REDACTED]');
    }
    if (hasSensitiveKey) {
      final hasDoubleQuote = sanitized.contains('"');
      final hasSingleQuote = sanitized.contains("'");
      if (hasDoubleQuote) {
        sanitized = sanitized.replaceAllMapped(
          _doubleQuotedKeyValue,
          (match) => '"${match.group(1)}"${match.group(2)}"[REDACTED]"',
        );
        sanitized = sanitized.replaceAllMapped(_doubleQuotedValue, (match) {
          final prefix = match
              .group(0)!
              .substring(0, match.group(0)!.indexOf('"') + 1);
          return '$prefix[REDACTED]"';
        });
      }
      if (hasSingleQuote) {
        sanitized = sanitized.replaceAllMapped(
          _singleQuotedKeyValue,
          (match) => "'${match.group(1)}'${match.group(2)}'[REDACTED]'",
        );
        sanitized = sanitized.replaceAllMapped(_singleQuotedValue, (match) {
          final prefix = match
              .group(0)!
              .substring(0, match.group(0)!.indexOf("'") + 1);
          return "$prefix[REDACTED]'";
        });
      }
      sanitized = sanitized.replaceAllMapped(
        _unquotedValue,
        (match) => '${match.group(1)}${match.group(2)}[REDACTED]',
      );
    }
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
    await _initializing;
    await _rotationTask;
    final sink = _sink;
    _sink = null;
    await sink?.flush();
    await sink?.close();
  }

  @visibleForTesting
  static Future<void> resetForTest() async {
    await dispose();
    if (_previousDebugPrint != null) {
      debugPrint = _previousDebugPrint!;
      _previousDebugPrint = null;
    }
    _initialized = false;
    _initializing = null;
    _logDirectoryPath = null;
    _bytesSinceRotation = 0;
    _rotationScheduled = false;
    _rotationTask = Future<void>.value();
    _pendingWrites.clear();
  }
}
