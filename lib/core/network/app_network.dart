import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../platform/network_platform_service.dart';
import 'dns_server_resolver.dart';
import 'network_route_settings.dart';
import 'network_socket.dart';

/// One loopback transport for Dart and FFmpeg/libmpv. CONNECT copies encrypted
/// bytes, so origin certificates and TLS host names remain the client's job.
class AppNetwork extends HttpOverrides {
  AppNetwork({
    Future<String> Function(Uri)? resolveSystemProxy,
    Future<void> Function(NetworkRouteSettings, String?)? applyNativeRoute,
  }) : _resolveSystemProxy =
           resolveSystemProxy ?? NetworkPlatformService().resolveSystemProxy,
       _applyNativeRoute =
           applyNativeRoute ?? NetworkPlatformService().applyNetworkRoute;

  static final instance = AppNetwork();
  final Future<String> Function(Uri) _resolveSystemProxy;
  final Future<void> Function(NetworkRouteSettings, String?) _applyNativeRoute;
  ServerSocket? _server;
  Future<void>? _starting;
  HttpOverrides? _previousOverrides;
  bool _installed = false;
  NetworkRouteSettings _settings = const NetworkRouteSettings();
  String? _password;
  final _sockets = <Socket>{};

  String get proxyUrl {
    final server = _server;
    if (server == null) throw StateError('Application network has not started');
    return 'http://127.0.0.1:${server.port}';
  }

  Future<void> ensureStarted() => _starting ??= _start();

  Future<void> _start() async {
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      server.listen((socket) {
        _sockets.add(socket);
        unawaited(_handle(socket));
      });
    } catch (_) {
      _starting = null;
      rethrow;
    }
  }

  Future<void> install() async {
    await ensureStarted();
    if (_installed) return;
    _previousOverrides = HttpOverrides.current;
    HttpOverrides.global = this;
    _installed = true;
  }

  Future<void> configure(
    NetworkRouteSettings settings,
    String? password,
  ) async {
    // A restored device may have preferences but no device-bound password.
    // Keep that route blocked until credentials are supplied, without making
    // the settings page itself inaccessible during startup.
    settings.validate(requireCredentials: false);
    await ensureStarted();
    // A native failure must not publish a route used only by Flutter.
    await _applyNativeRoute(settings, password);
    _settings = settings;
    _password = password;
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client =
        _previousOverrides?.createHttpClient(context) ??
        super.createHttpClient(context);
    final proxy = Uri.parse(proxyUrl);
    client.findProxy = (uri) {
      final host = uri.host.toLowerCase();
      final address = InternetAddress.tryParse(host);
      if (host == 'localhost' || address?.isLoopback == true) return 'DIRECT';
      return 'PROXY ${proxy.host}:${proxy.port}';
    };
    return client;
  }

  Future<void> close() async {
    if (_installed) {
      HttpOverrides.global = _previousOverrides;
      _installed = false;
    }
    await _server?.close();
    _server = null;
    _starting = null;
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _sockets.clear();
    _password = null;
  }

  Future<void> _handle(Socket socket) async {
    NetworkSocket? outgoing;
    var forwarding = false;
    try {
      final incoming = NetworkSocket(socket);
      final header = await incoming.readHeader().timeout(
        const Duration(seconds: 15),
      );
      final lines = header.split('\r\n');
      final first = lines.first.split(' ');
      if (first.length != 3 || !first[2].startsWith('HTTP/1.')) {
        throw const HttpException('Invalid proxy request');
      }
      final connect = first[0] == 'CONNECT';
      final uri = connect
          ? Uri.parse('https://${first[1]}')
          : Uri.parse(first[1]);
      if (!const {'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.port < 1 ||
          uri.port > 65535) {
        throw const HttpException('Invalid proxy target');
      }
      if ((uri.host == 'localhost' ||
              InternetAddress.tryParse(uri.host)?.isLoopback == true) &&
          uri.port == _server?.port) {
        throw const HttpException('Recursive proxy target');
      }
      final settings = _settings;
      final password = _password;
      final localTarget =
          uri.host == 'localhost' ||
          InternetAddress.tryParse(uri.host)?.isLoopback == true;
      final routes = localTarget
          ? [const _ProxyRoute('DIRECT', '', 0)]
          : settings.proxyMode == AppProxyMode.system
          ? _parsePolicy(await _resolveSystemProxy(uri))
          : [
              _ProxyRoute(
                settings.proxyMode == AppProxyMode.http ? 'PROXY' : 'SOCKS5',
                settings.proxyHost,
                settings.proxyPort,
              ),
            ];
      if (routes.isEmpty) throw const HttpException('Empty proxy policy');
      Object? failure;
      _ProxyRoute? chosen;
      for (final route in routes) {
        try {
          outgoing = await _connect(uri, route, settings, password, connect);
          chosen = route;
          break;
        } catch (error) {
          failure = error;
        }
      }
      if (outgoing == null || chosen == null) {
        throw failure ?? const SocketException('No route');
      }
      if (connect) {
        socket.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
      } else {
        final upstreamHttp = chosen.isHttp;
        final target = upstreamHttp
            ? uri.toString()
            : '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
        final forwarded = <String>['${first[0]} $target ${first[2]}'];
        for (final line in lines.skip(1)) {
          if (line.isEmpty) continue;
          final key = line.split(':').first.toLowerCase();
          if (const {
            'connection',
            'proxy-connection',
            'proxy-authorization',
          }.contains(key)) {
            continue;
          }
          forwarded.add(line);
        }
        // Plain HTTP is uncommon here; close after its response rather than
        // interpreting another absolute request inside an origin connection.
        forwarded.add('Connection: close');
        final authorization = upstreamHttp
            ? _authorization(settings, password)
            : null;
        if (upstreamHttp && authorization != null) {
          forwarded.add('Proxy-Authorization: $authorization');
        }
        outgoing.socket.add(latin1.encode('${forwarded.join('\r\n')}\r\n\r\n'));
      }
      forwarding = true;
      await Future.wait([
        _copy(incoming, outgoing.socket),
        _copy(outgoing, socket),
      ], eagerError: true);
    } catch (_) {
      if (!forwarding) {
        try {
          socket.add(
            ascii.encode(
              'HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n',
            ),
          );
          await socket.flush();
        } on Object {
          // The consumer may have cancelled while DNS or the proxy was opening.
        }
      }
    } finally {
      if (outgoing != null) {
        _sockets.remove(outgoing.socket);
        outgoing.destroy();
      }
      _sockets.remove(socket);
      socket.destroy();
    }
  }

  Future<NetworkSocket> _connect(
    Uri uri,
    _ProxyRoute route,
    NetworkRouteSettings settings,
    String? password,
    bool tunnel,
  ) async {
    Socket? socket;
    var expired = false;
    final timer = Timer(const Duration(seconds: 10), () {
      expired = true;
      socket?.destroy();
    });
    try {
      if (route.type != 'DIRECT' &&
          settings.proxyMode != AppProxyMode.system &&
          settings.proxyAuthenticationEnabled &&
          (password == null || password.isEmpty)) {
        throw const SocketException('Proxy credentials are unavailable');
      }
      final host = route.type == 'DIRECT' ? uri.host : route.host;
      final port = route.type == 'DIRECT' ? uri.port : route.port;
      if (route.type == 'HTTPS') {
        socket = await SecureSocket.connect(
          host,
          port,
          timeout: const Duration(seconds: 8),
        );
      } else if (route.type == 'DIRECT' &&
          settings.customDnsServer.isNotEmpty) {
        final addresses = await DnsServerResolver(
          InternetAddress(settings.customDnsServer),
        ).lookup(host);
        Object? error;
        for (final address in addresses) {
          if (expired) throw TimeoutException('Network route timed out');
          try {
            socket = await Socket.connect(
              address,
              port,
              timeout: const Duration(seconds: 8),
            );
            break;
          } catch (failure) {
            error = failure;
          }
        }
        if (socket == null) {
          throw error ?? const SocketException('No DNS addresses');
        }
      } else {
        // Proxy bootstrap uses OS DNS. Target names stay unresolved for proxies.
        socket = await Socket.connect(
          host,
          port,
          timeout: const Duration(seconds: 8),
        );
      }
      if (expired) throw TimeoutException('Network route timed out');
      _sockets.add(socket);
      final connection = NetworkSocket(socket);
      if (route.type == 'SOCKS' || route.type == 'SOCKS5') {
        final authenticate =
            settings.proxyMode != AppProxyMode.system &&
            settings.proxyAuthenticationEnabled;
        await connection
            .socksConnect(
              uri.host,
              uri.port,
              username: authenticate ? settings.proxyUsername : null,
              password: authenticate ? password : null,
            )
            .timeout(const Duration(seconds: 8));
      } else if (route.isHttp && tunnel) {
        await connection
            .httpConnect(
              uri.host,
              uri.port,
              authorization: _authorization(settings, password),
            )
            .timeout(const Duration(seconds: 8));
      }
      return connection;
    } catch (_) {
      if (socket != null) _sockets.remove(socket);
      socket?.destroy();
      rethrow;
    } finally {
      timer.cancel();
    }
  }

  static Future<void> _copy(NetworkSocket source, Socket destination) async {
    await destination.addStream(source.remaining);
    await destination.flush();
    await destination.close();
  }

  static String? _authorization(
    NetworkRouteSettings settings,
    String? password,
  ) {
    if (settings.proxyMode == AppProxyMode.system ||
        !settings.proxyAuthenticationEnabled) {
      return null;
    }
    if (password == null || password.isEmpty) {
      throw const FormatException('Missing proxy password');
    }
    return 'Basic ${base64.encode(utf8.encode('${settings.proxyUsername}:$password'))}';
  }

  static List<_ProxyRoute> _parsePolicy(String policy) {
    final routes = <_ProxyRoute>[];
    for (final entry in policy.split(';')) {
      final parts = entry.trim().split(RegExp(r'\s+'));
      final type = parts.first.toUpperCase();
      if (type == 'DIRECT') {
        routes.add(const _ProxyRoute('DIRECT', '', 0));
      } else if (const {
            'PROXY',
            'HTTP',
            'HTTPS',
            'SOCKS',
            'SOCKS5',
          }.contains(type) &&
          parts.length == 2) {
        final address = Uri.tryParse('http://${parts[1]}');
        if (address == null ||
            address.host.isEmpty ||
            !address.hasPort ||
            address.port < 1 ||
            address.port > 65535) {
          throw const FormatException('Invalid system proxy address');
        }
        routes.add(_ProxyRoute(type, address.host, address.port));
      } else {
        throw const FormatException('Unsupported system proxy policy');
      }
    }
    return routes;
  }
}

class _ProxyRoute {
  const _ProxyRoute(this.type, this.host, this.port);
  final String type;
  final String host;
  final int port;
  bool get isHttp => const {'PROXY', 'HTTP', 'HTTPS'}.contains(type);
}
