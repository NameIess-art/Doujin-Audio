import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../errors/native_result.dart';
import '../logging/app_log_service.dart';
import 'platform_channels.dart';
import 'platform_method_client.dart';

class NotificationsPlatformService {
  NotificationsPlatformService({
    MethodChannel? channel,
    @visibleForTesting bool? isWindowsOverride,
    Duration timeout = const Duration(seconds: 5),
  }) : _client = PlatformMethodClient(
         channel ?? const MethodChannel(NotificationsChannel.name),
       ),
       _isWindowsOverride = isWindowsOverride,
       _timeout = timeout;

  final PlatformMethodClient _client;
  final bool? _isWindowsOverride;
  final Duration _timeout;
  String? _sentTaskbarCoverPath;
  int _syncRevision = 0;
  // The Windows runner consumes a fixed-size, opaque RGBA thumbnail.
  static const _taskbarWidth = 320;
  static const _taskbarHeight = 240;

  bool get _isWindows =>
      _isWindowsOverride ?? defaultTargetPlatform == TargetPlatform.windows;

  Future<NativeResult<void>> syncUnifiedPlaybackNotifications(
    Map<String, dynamic> payload,
  ) async {
    if (!_isWindows) return const NativeSuccess<void>();
    final revision = ++_syncRevision;
    Map<Object?, Object?>? selected;
    if (payload['items'] case final List<Object?> items) {
      for (final item in items.whereType<Map<Object?, Object?>>()) {
        selected ??= item;
        if (item['id'] == payload['mainSessionId']) {
          selected = item;
          break;
        }
      }
    }
    final artPath = selected?['artPath'];
    final coverPath = artPath is String && artPath.isNotEmpty ? artPath : null;
    final coverChanged = coverPath != _sentTaskbarCoverPath;
    final cover = coverChanged && coverPath != null
        ? await _readTaskbarCover(
            coverPath,
          ).timeout(_timeout, onTimeout: () => null)
        : null;
    if (revision != _syncRevision) return const NativeSuccess<void>();
    final result = await _invoke(
      NotificationsMethod.syncUnifiedPlaybackNotifications,
      arguments: {...payload, if (coverChanged) 'taskbarCover': cover},
      timeoutMessage: 'Notification sync timed out.',
    );
    if (result.isOk && revision == _syncRevision) {
      _sentTaskbarCoverPath = coverPath;
    }
    return result;
  }

  Future<NativeResult<void>> clearUnifiedPlaybackNotifications() {
    _syncRevision++;
    _sentTaskbarCoverPath = null;
    return _invoke(
      NotificationsMethod.clearUnifiedPlaybackNotifications,
      timeoutMessage: 'Notification clear timed out.',
    );
  }

  static Future<Uint8List?> _readTaskbarCover(String path) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(
        await File(path).readAsBytes(),
      );
      // Keep decoding on Flutter's image pipeline so taskbar artwork supports
      // the same formats as the card, including WebP on stock Windows installs.
      final ui.Image source;
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          final width = descriptor.width;
          final height = descriptor.height;
          final scale = math.min(
            1.0,
            math.min(
              1280 / math.max(width, height),
              math.max(_taskbarWidth / width, _taskbarHeight / height),
            ),
          );
          final codec = await descriptor.instantiateCodec(
            targetWidth: width >= height ? (width * scale).round() : null,
            targetHeight: height > width ? (height * scale).round() : null,
          );
          try {
            source = (await codec.getNextFrame()).image;
          } finally {
            codec.dispose();
          }
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final width = source.width.toDouble();
      final height = source.height.toDouble();
      final cropWidth = math.min(
        width,
        height * _taskbarWidth / _taskbarHeight,
      );
      final cropHeight = math.min(
        height,
        width * _taskbarHeight / _taskbarWidth,
      );
      canvas.drawColor(const ui.Color(0xff000000), ui.BlendMode.src);
      canvas.drawImageRect(
        source,
        ui.Rect.fromCenter(
          center: ui.Offset(width / 2, height / 2),
          width: cropWidth,
          height: cropHeight,
        ),
        ui.Rect.fromLTWH(
          0,
          0,
          _taskbarWidth.toDouble(),
          _taskbarHeight.toDouble(),
        ),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      final picture = recorder.endRecording();
      try {
        final image = await picture.toImage(_taskbarWidth, _taskbarHeight);
        try {
          return (await image.toByteData())?.buffer.asUint8List();
        } finally {
          image.dispose();
        }
      } finally {
        picture.dispose();
        source.dispose();
      }
    } on Exception catch (error) {
      AppLogService.warning('taskbar_cover_decode_failed', error: error);
      return null;
    }
  }

  Future<NativeResult<void>> _invoke(
    String method, {
    Map<String, dynamic>? arguments,
    required String timeoutMessage,
  }) async {
    if (!_isWindows) return const NativeSuccess<void>();
    final result = await _client
        .invoke<void>(method, arguments: arguments, decode: (_) {})
        .timeout(
          _timeout,
          onTimeout: () => NativeFailure<void>(
            timeoutMessage,
            code: NativeErrorCode.platformError,
          ),
        );
    if (result case NativeFailure<void>(
      :final code,
      :final message,
      :final details,
    )) {
      AppLogService.warning(
        'notifications_platform_method_failed method=$method code=$code',
        error: <String, Object?>{'message': message, 'details': details},
      );
    }
    return result;
  }
}
