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
    DnsServerResolver Function(InternetAddress)? createDnsResolver,
    Future<ConnectionTask<Socket>> Function(InternetAddress, int)?
    startSocketConnect,
    Duration Function()? monotonicElapsed,
  }) : _resolveSystemProxy =
           resolveSystemProxy ?? NetworkPlatformService().resolveSystemProxy,
       _applyNativeRoute =
           applyNativeRoute ?? NetworkPlatformService().applyNetworkRoute,
       _createDnsResolver = createDnsResolver ?? DnsServerResolver.new,
       _startSocketConnect = startSocketConnect ?? Socket.startConnect,
       _elapsed = monotonicElapsed ?? (() => _clock.elapsed);

  static final instance = AppNetwork();
  static final _clock = Stopwatch()..start();
  static const _systemProxyCacheTtl = Duration(seconds: 4);
  static const _systemProxyCacheLimit = 128;
  final Future<String> Function(Uri) _resolveSystemProxy;
  final Future<void> Function(NetworkRouteSettings, String?) _applyNativeRoute;
  final DnsServerResolver Function(InternetAddress) _createDnsResolver;
  final Future<ConnectionTask<Socket>> Function(InternetAddress, int)
  _startSocketConnect;
  final Duration Function() _elapsed;
  final _pendingSystemProxyRoutes = <Uri, Future<List<_ProxyRoute>>>{};
  final _cachedSystemProxyRoutes =
      <Uri, ({List<_ProxyRoute> routes, Duration expiresAt})>{};
  final _connectionAttempts = <ConnectionTask<Socket>>{};
  final _connecting = <Completer<Socket>>{};
  final _retiredDnsResolvers = <_ManagedDnsResolver>{};
  _ManagedDnsResolver? _dnsResolver;
  ServerSocket? _server;
  Future<void>? _starting;
  Future<void> _configureTail = Future<void>.value();
  int _lifecycleGeneration = 0;
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
  ) {
    // A restored device may have preferences but no device-bound password.
    // Keep that route blocked until credentials are supplied, without making
    // the settings page itself inaccessible during startup.
    settings.validate(requireCredentials: false);
    final normalizedDns = settings.customDnsServer.isEmpty
        ? ''
        : NetworkRouteSettings.normalizeDns(settings.customDnsServer)!;
    final normalizedSettings = normalizedDns == settings.customDnsServer
        ? settings
        : settings.copyWith(customDnsServer: normalizedDns);
    final generation = _lifecycleGeneration;
    final operation = _configureTail.then((_) async {
      if (generation != _lifecycleGeneration) return;
      await ensureStarted();
      if (generation != _lifecycleGeneration) return;
      // A native failure must not publish a route used only by Flutter.
      await _applyNativeRoute(normalizedSettings, password);
      if (generation != _lifecycleGeneration) return;
      if (_settings != normalizedSettings ||
          _password != password ||
          (_dnsResolver == null &&
              normalizedSettings.customDnsServer.isNotEmpty)) {
        // Retire the previous resolver without closing it mid-lookup; active
        // connections release their lease as soon as _connect finishes.
        final previous = _dnsResolver;
        _dnsResolver = normalizedSettings.customDnsServer.isEmpty
            ? null
            : _ManagedDnsResolver(
                _createDnsResolver(
                  InternetAddress(normalizedSettings.customDnsServer),
                ),
                onRetiredClosed: _retiredDnsResolvers.remove,
              );
        if (previous != null) {
          _retiredDnsResolvers.add(previous);
          previous.retire();
        }
      }
      _clearSystemProxyRoutes();
      _settings = normalizedSettings;
      _password = password;
    });
    _configureTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
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
    _lifecycleGeneration++;
    _clearSystemProxyRoutes();
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
    for (final connection in _connecting.toList()) {
      if (!connection.isCompleted) {
        connection.completeError(
          const SocketException('Application network is closed'),
        );
      }
    }
    for (final attempt in _connectionAttempts.toList()) {
      attempt.cancel();
    }
    _connectionAttempts.clear();
    _password = null;
    _dnsResolver?.closeNow();
    _dnsResolver = null;
    for (final retired in _retiredDnsResolvers.toList()) {
      retired.closeNow();
    }
    _retiredDnsResolvers.clear();
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
      final dnsLease = _dnsResolver;
      dnsLease?.acquire();
      _ProxyRoute? chosen;
      try {
        final localTarget =
            uri.host == 'localhost' ||
            InternetAddress.tryParse(uri.host)?.isLoopback == true;
        final routes = localTarget
            ? [const _ProxyRoute('DIRECT', '', 0)]
            : settings.proxyMode == AppProxyMode.system
            ? await _systemProxyRoutes(uri)
            : [
                _ProxyRoute(
                  settings.proxyMode == AppProxyMode.http ? 'PROXY' : 'SOCKS5',
                  settings.proxyHost,
                  settings.proxyPort,
                ),
              ];
        Object? failure;
        for (final route in routes) {
          try {
            outgoing = await _connect(
              uri,
              route,
              settings,
              password,
              connect,
              dnsLease?.resolver,
            );
            chosen = route;
            break;
          } catch (error) {
            failure = error;
          }
        }
        if (outgoing == null || chosen == null) {
          // Re-resolve on the next request if a network change invalidated
          // this route before the short cache lifetime expired.
          if (identical(_cachedSystemProxyRoutes[uri]?.routes, routes)) {
            _cachedSystemProxyRoutes.remove(uri);
          }
          throw failure ?? const SocketException('No route');
        }
      } finally {
        dnsLease?.release();
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

  void _clearSystemProxyRoutes() {
    _pendingSystemProxyRoutes.clear();
    _cachedSystemProxyRoutes.clear();
  }

  Future<List<_ProxyRoute>> _systemProxyRoutes(Uri uri) {
    // PAC can route HTTP requests on the same origin differently by URL.
    // CONNECT provides only the HTTPS authority.
    final cached = _cachedSystemProxyRoutes[uri];
    if (cached != null && _elapsed() < cached.expiresAt) {
      return Future.value(cached.routes);
    }
    _cachedSystemProxyRoutes.remove(uri);
    final pending = _pendingSystemProxyRoutes[uri];
    if (pending != null) return pending;

    late final Future<List<_ProxyRoute>> lookup;
    lookup = Future.sync(() => _resolveSystemProxy(uri))
        .then((policy) {
          final routes = _parsePolicy(policy);
          if (routes.isEmpty) throw const HttpException('Empty proxy policy');
          // Reconfiguration or close may have started a new lookup meanwhile.
          if (identical(_pendingSystemProxyRoutes[uri], lookup)) {
            _cachedSystemProxyRoutes[uri] = (
              routes: routes,
              expiresAt: _elapsed() + _systemProxyCacheTtl,
            );
            if (_cachedSystemProxyRoutes.length > _systemProxyCacheLimit) {
              _cachedSystemProxyRoutes.remove(
                _cachedSystemProxyRoutes.keys.first,
              );
            }
          }
          return routes;
        })
        .whenComplete(() {
          if (identical(_pendingSystemProxyRoutes[uri], lookup)) {
            _pendingSystemProxyRoutes.remove(uri);
          }
        });
    _pendingSystemProxyRoutes[uri] = lookup;
    return lookup;
  }

  Future<NetworkSocket> _connect(
    Uri uri,
    _ProxyRoute route,
    NetworkRouteSettings settings,
    String? password,
    bool tunnel,
    DnsServerResolver? dnsResolver,
  ) async {
    Socket? socket;
    Completer<Socket>? pendingConnection;
    var expired = false;
    final timer = Timer(const Duration(seconds: 10), () {
      expired = true;
      socket?.destroy();
      if (pendingConnection?.isCompleted == false) {
        pendingConnection!.completeError(
          TimeoutException('Network route timed out'),
        );
      }
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
        final connected = Completer<Socket>();
        _connecting.add(connected);
        pendingConnection = connected;
        final addresses = <InternetAddress>[];
        final attempts = <ConnectionTask<Socket>>{};
        final activeFamilies = <InternetAddressType>{};
        Object? error;
        var active = 0;
        var dnsDone = false;
        Timer? stagger;
        late void Function(bool) pump;
        Future<void> attempt(InternetAddress address) async {
          ConnectionTask<Socket>? task;
          try {
            task = await _startSocketConnect(address, port);
            if (connected.isCompleted) {
              task.cancel();
              final abandoned = await task.socket;
              abandoned.destroy();
              return;
            }
            attempts.add(task);
            _connectionAttempts.add(task);
            final candidate = await task.socket.timeout(
              const Duration(seconds: 8),
              onTimeout: () {
                task!.cancel();
                throw TimeoutException('Address connection timed out');
              },
            );
            if (connected.isCompleted) {
              candidate.destroy();
            } else {
              connected.complete(candidate);
            }
          } catch (failure) {
            error = failure;
          } finally {
            attempts.remove(task);
            _connectionAttempts.remove(task);
            active--;
            activeFamilies.remove(address.type);
            pump(true);
          }
        }

        // A slow IPv6 connect must not hold an already-resolved IPv4 address
        // for eight seconds. Keep one cancellable attempt per family so a
        // batch of slow addresses cannot occupy both available slots.
        pump = (immediately) {
          if (connected.isCompleted) return;
          final next = addresses.indexWhere(
            (address) => !activeFamilies.contains(address.type),
          );
          if (next >= 0 && active < 2) {
            if (active > 0 && !immediately) {
              stagger ??= Timer(const Duration(milliseconds: 250), () {
                stagger = null;
                pump(true);
              });
              return;
            }
            stagger?.cancel();
            stagger = null;
            active++;
            final address = addresses.removeAt(next);
            activeFamilies.add(address.type);
            unawaited(attempt(address));
            pump(false);
          } else if (active == 0 && dnsDone) {
            connected.completeError(
              error ?? const SocketException('No DNS addresses'),
            );
          }
        };
        final subscription = dnsResolver!
            .lookupAddresses(host)
            .listen(
              (address) {
                addresses.add(address);
                pump(false);
              },
              onError: (Object failure) {
                error = failure;
                dnsDone = true;
                pump(true);
              },
              onDone: () {
                dnsDone = true;
                pump(false);
              },
            );
        try {
          socket = await connected.future;
        } finally {
          _connecting.remove(connected);
          stagger?.cancel();
          for (final task in attempts.toList()) {
            task.cancel();
          }
          await subscription.cancel();
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
      if (_server == null) {
        throw const SocketException('Application network is closed');
      }
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

  static final _explicitProxyPort = RegExp(r':([0-9]+)$');

  static List<_ProxyRoute> _parsePolicy(String policy) {
    final routes = <_ProxyRoute>[];
    for (final rawEntry in policy.split(';')) {
      final entry = rawEntry.trim();
      if (entry.isEmpty) continue;
      final parts = entry.split(RegExp(r'\s+'));
      final type = parts.first.toUpperCase();
      if (type == 'DIRECT' && parts.length == 1) {
        routes.add(const _ProxyRoute('DIRECT', '', 0));
      } else if (const {
            'PROXY',
            'HTTP',
            'HTTPS',
            'SOCKS',
            'SOCKS5',
          }.contains(type) &&
          parts.length == 2) {
        final target = parts[1];
        if (target.endsWith(':')) {
          throw const FormatException('Invalid system proxy address');
        }
        final address = Uri.tryParse(
          target.contains('://') ? target : 'http://$target',
        );
        if (address == null ||
            address.host.isEmpty ||
            address.userInfo.isNotEmpty ||
            address.path.isNotEmpty ||
            address.hasQuery ||
            address.hasFragment) {
          throw const FormatException('Invalid system proxy address');
        }
        // Uri may elide a port that matches the input scheme's default,
        // which can differ from the system policy's actual proxy type.
        final explicitPort = _explicitProxyPort.firstMatch(target)?.group(1);
        final port = explicitPort != null
            ? int.tryParse(explicitPort) ?? 0
            : switch (type) {
                'HTTPS' => 443,
                'SOCKS' || 'SOCKS5' => 1080,
                _ => 80,
              };
        if (port < 1 || port > 65535) {
          throw const FormatException('Invalid system proxy address');
        }
        routes.add(_ProxyRoute(type, address.host, port));
      } else {
        throw const FormatException('Unsupported system proxy policy');
      }
    }
    return routes;
  }
}

class _ManagedDnsResolver {
  _ManagedDnsResolver(this.resolver, {required this.onRetiredClosed});

  final DnsServerResolver resolver;
  final void Function(_ManagedDnsResolver) onRetiredClosed;
  int _activeUses = 0;
  bool _retired = false;
  bool _closed = false;

  void acquire() {
    _activeUses++;
  }

  void release() {
    if (_activeUses > 0) _activeUses--;
    if (_retired && _activeUses == 0) {
      closeNow();
    }
  }

  void retire() {
    _retired = true;
    if (_activeUses == 0) {
      closeNow();
    }
  }

  void closeNow() {
    if (_closed) return;
    _closed = true;
    _retired = true;
    onRetiredClosed(this);
    resolver.close();
  }
}

class _ProxyRoute {
  const _ProxyRoute(this.type, this.host, this.port);
  final String type;
  final String host;
  final int port;
  bool get isHttp => const {'PROXY', 'HTTP', 'HTTPS'}.contains(type);
}
