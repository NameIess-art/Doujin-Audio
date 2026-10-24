import 'dart:io';

import 'package:flutter/services.dart';

import '../errors/native_result.dart';
import '../network/network_route_settings.dart';
import 'platform_method_client.dart';
import 'platform_channels.dart';

/// Platform policy only; route ownership stays in the settings repository.
class NetworkPlatformService {
  NetworkPlatformService({MethodChannel? channel})
    : _client = PlatformMethodClient(
        channel ?? const MethodChannel(NetworkChannel.name),
      );

  final PlatformMethodClient _client;

  Future<String> resolveSystemProxy(Uri uri) async {
    if (!Platform.isAndroid && !Platform.isWindows) return 'DIRECT';
    final result = await _client.invoke<String>(
      NetworkMethod.resolveSystemProxy,
      arguments: {'url': uri.toString()},
      decode: (value) {
        if (value is! String || value.isEmpty) {
          throw const FormatException('Missing system proxy policy');
        }
        return value;
      },
    );
    if (result case NativeSuccess<String>(value: final value?)) return value;
    throw StateError(result.errorOrNull ?? 'System proxy lookup failed');
  }

  Future<void> applyNetworkRoute(
    NetworkRouteSettings settings,
    String? password,
  ) async {
    if (!Platform.isAndroid) return;
    final result = await _client.invoke<void>(
      NetworkMethod.applyNetworkRoute,
      arguments: {...settings.toJson(), 'proxyPassword': password},
      decode: (_) {},
    );
    if (result.isFailure) {
      throw StateError(result.errorOrNull ?? 'Native network route failed');
    }
  }
}
