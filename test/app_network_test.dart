import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:doujin_audio/core/network/app_network.dart';
import 'package:doujin_audio/core/network/dns_server_resolver.dart';
import 'package:doujin_audio/core/network/network_route_settings.dart';
import 'package:doujin_audio/core/network/network_socket.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {
  HttpClient client() => super.createHttpClient(null);
}

void main() {
  late AppNetwork network;
  final clients = <HttpClient>[];

  setUp(() async {
    network = AppNetwork(
      resolveSystemProxy: (_) async => 'DIRECT',
      applyNativeRoute: (_, _) async {},
    );
    await network.ensureStarted();
  });
  tearDown(() async {
    for (final client in clients) {
      client.close(force: true);
    }
    clients.clear();
    await network.close();
  });

  HttpClient proxiedClient() {
    final proxy = Uri.parse(network.proxyUrl);
    final client = _RealHttp().client()
      ..findProxy = ((_) => 'PROXY ${proxy.host}:${proxy.port}')
      ..connectionTimeout = const Duration(seconds: 3);
    clients.add(client);
    return client;
  }

  test(
    'system proxy reuses URL lookups until expiry or route changes',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => upstream.close(force: true));
      upstream.listen((request) => request.response.close());
      final firstLookup = Completer<void>();
      final releaseLookup = Completer<void>();
      final calls = <Uri>[];
      var elapsed = Duration.zero;
      await network.close();
      network = AppNetwork(
        resolveSystemProxy: (uri) async {
          calls.add(uri);
          if (calls.length == 1) firstLookup.complete();
          await releaseLookup.future;
          return 'PROXY 127.0.0.1:${upstream.port}';
        },
        applyNativeRoute: (_, _) async {},
        monotonicElapsed: () => elapsed,
      );
      await network.ensureStarted();
      final client = proxiedClient();
      Future<void> get(Uri url) async {
        final request = await client.getUrl(url);
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);
        await response.drain<void>();
      }

      final first = Uri.parse('http://example.invalid/first');
      final second = first.replace(path: '/second');
      final burst = Future.wait(List.generate(8, (_) => get(first)));
      await firstLookup.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      releaseLookup.complete();
      await burst;
      await get(first);
      await get(second);
      expect(calls, [first, second]);

      elapsed = const Duration(seconds: 4);
      await get(first);
      expect(calls, [first, second, first]);

      await network.configure(const NetworkRouteSettings(), null);
      await get(first);
      expect(calls, [first, second, first, first]);
    },
  );

  test('a failed system proxy lookup is retryable before the TTL', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));
    upstream.listen((request) => request.response.close());
    var lookups = 0;
    await network.close();
    network = AppNetwork(
      resolveSystemProxy: (_) async {
        if (++lookups == 1) throw const SocketException('Proxy lookup failed');
        return 'PROXY 127.0.0.1:${upstream.port}';
      },
      monotonicElapsed: () => Duration.zero,
    );
    await network.ensureStarted();
    final client = proxiedClient();
    final url = Uri.parse('http://example.invalid/retry');
    for (final status in [HttpStatus.badGateway, HttpStatus.ok]) {
      final response = await (await client.getUrl(url)).close();
      expect(response.statusCode, status);
      await response.drain<void>();
    }
    expect(lookups, 2);
  });

  Future<NetworkSocket> connectTunnel(String target) async {
    final proxy = Uri.parse(network.proxyUrl);
    final socket = NetworkSocket(await Socket.connect(proxy.host, proxy.port));
    socket.socket.add(
      ascii.encode('CONNECT $target HTTP/1.1\r\nHost: $target\r\n\r\n'),
    );
    expect(await socket.readHeader(), startsWith('HTTP/1.1 200'));
    return socket;
  }

  test('HTTP forwarding preserves POST body and response status', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => origin.close(force: true));
    origin.listen((request) async {
      expect(request.uri.path, '/submit');
      expect(await utf8.decodeStream(request), 'payload');
      expect(request.headers.value('proxy-authorization'), isNull);
      request.response.statusCode = 201;
      request.response.write('created');
      await request.response.close();
    });
    final request = await proxiedClient().postUrl(
      Uri.parse('http://127.0.0.1:${origin.port}/submit'),
    );
    request.write('payload');
    final response = await request.close();
    expect(response.statusCode, 201);
    expect(await utf8.decodeStream(response), 'created');
  });

  test('HTTP upstream gets authentication and unresolved target', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));
    upstream.listen((request) async {
      expect(request.uri.host, 'unresolvable.invalid');
      expect(
        request.headers.value('proxy-authorization'),
        'Basic ${base64.encode(utf8.encode('name:secret'))}',
      );
      request.response.write('proxied');
      await request.response.close();
    });
    await network.configure(
      NetworkRouteSettings(
        proxyMode: AppProxyMode.http,
        proxyHost: '127.0.0.1',
        proxyPort: upstream.port,
        proxyAuthenticationEnabled: true,
        proxyUsername: 'name',
        proxyPasswordConfigured: true,
        customDnsServer: '192.0.2.1',
      ),
      'secret',
    );
    final response = await (await proxiedClient().getUrl(
      Uri.parse('http://unresolvable.invalid/test'),
    )).close();
    expect(await utf8.decodeStream(response), 'proxied');
  });

  test(
    'SOCKS5 authentication and domain target work through a real tunnel',
    () async {
      final socks = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(socks.close);
      final checked = Completer<void>();
      socks.listen((socket) async {
        final connection = NetworkSocket(socket);
        try {
          expect(await connection.readBytes(3), [5, 1, 2]);
          socket.add([5, 2]);
          expect(await connection.readBytes(2), [1, 4]);
          expect(utf8.decode(await connection.readBytes(4)), 'name');
          expect(await connection.readBytes(1), [6]);
          expect(utf8.decode(await connection.readBytes(6)), 'secret');
          socket.add([1, 0]);
          expect(await connection.readBytes(4), [5, 1, 0, 3]);
          final length = (await connection.readBytes(1)).single;
          expect(
            utf8.decode(await connection.readBytes(length)),
            'unresolvable.invalid',
          );
          expect(await connection.readBytes(2), [0, 80]);
          socket.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 80]);
          expect(
            await connection.readHeader(),
            startsWith('GET /resource HTTP/1.1'),
          );
          socket.add(
            ascii.encode(
              'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok',
            ),
          );
          await socket.flush();
          socket.destroy();
          checked.complete();
        } catch (error, stack) {
          checked.completeError(error, stack);
          socket.destroy();
        }
      });
      await network.configure(
        NetworkRouteSettings(
          proxyMode: AppProxyMode.socks5,
          proxyHost: '127.0.0.1',
          proxyPort: socks.port,
          proxyAuthenticationEnabled: true,
          proxyUsername: 'name',
          proxyPasswordConfigured: true,
          customDnsServer: '192.0.2.1',
        ),
        'secret',
      );
      final response = await (await proxiedClient().getUrl(
        Uri.parse('http://unresolvable.invalid/resource'),
      )).close();
      expect(await utf8.decodeStream(response), 'ok');
      await checked.future;
    },
  );

  test(
    'NetworkSocket.readHeader scans across chunk boundaries and preserves body',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final clientFuture = Socket.connect(InternetAddress.loopbackIPv4, server.port);
      final accepted = await server.first;
      final client = await clientFuture;
      addTearDown(accepted.destroy);
      addTearDown(client.destroy);
      final wrapped = NetworkSocket(accepted);

      client.add(ascii.encode('HTTP/1.1 200 OK\r\nX-Test: a\r'));
      await client.flush();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      client.add(ascii.encode('\r\n'));
      await client.flush();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      client.add(ascii.encode('\r\nBODY'));
      await client.flush();
      await client.close();

      expect(await wrapped.readHeader(), 'HTTP/1.1 200 OK\r\nX-Test: a\r\r\n\r\n');
      final bodyBytes = await wrapped.remaining.expand((chunk) => chunk).toList();
      expect(ascii.decode(bodyBytes), 'BODY');
    },
  );

  test(
    'NetworkSocket.readHeader enforces 64 KiB cap and detects truncated handshake',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final acceptedSockets = <Socket>[];
      final acceptedQueue = StreamIterator(server);
      addTearDown(() async {
        await acceptedQueue.cancel();
        for (final s in acceptedSockets) {
          s.destroy();
        }
      });

      // Oversized header > 64 KiB throws HttpException.
      final oversizedClient = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      addTearDown(oversizedClient.destroy);
      expect(await acceptedQueue.moveNext(), isTrue);
      final oversizedServer = acceptedQueue.current;
      acceptedSockets.add(oversizedServer);
      oversizedClient.add(Uint8List(65537)..fillRange(0, 65537, 65));
      await oversizedClient.flush();
      await expectLater(
        NetworkSocket(oversizedServer).readHeader(),
        throwsA(isA<HttpException>()),
      );

      // Connection closed before \r\n\r\n throws SocketException.
      final truncatedClient = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      addTearDown(truncatedClient.destroy);
      expect(await acceptedQueue.moveNext(), isTrue);
      final truncatedServer = acceptedQueue.current;
      acceptedSockets.add(truncatedServer);
      truncatedClient.add(ascii.encode('HTTP/1.1 200 OK\r\n'));
      await truncatedClient.close();
      await expectLater(
        NetworkSocket(truncatedServer).readHeader(),
        throwsA(isA<SocketException>()),
      );
    },
  );

  test('system SOCKS proxy never receives saved manual credentials', () async {
    final socks = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(socks.close);
    await network.close();
    network = AppNetwork(
      resolveSystemProxy: (_) async => 'SOCKS5 127.0.0.1:${socks.port}',
      applyNativeRoute: (_, _) async {},
    );
    await network.ensureStarted();
    final checked = Completer<void>();
    socks.listen((socket) async {
      final connection = NetworkSocket(socket);
      try {
        expect(await connection.readBytes(3), [5, 1, 0]);
        socket.add([5, 0]);
        expect(await connection.readBytes(4), [5, 1, 0, 3]);
        final length = (await connection.readBytes(1)).single;
        await connection.readBytes(length + 2);
        socket.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 80]);
        await connection.readHeader();
        socket.add(
          ascii.encode(
            'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok',
          ),
        );
        await socket.flush();
        checked.complete();
      } catch (error, stack) {
        checked.completeError(error, stack);
      } finally {
        socket.destroy();
      }
    });
    await network.configure(
      const NetworkRouteSettings(
        proxyAuthenticationEnabled: true,
        proxyUsername: 'saved-user',
        proxyPasswordConfigured: true,
      ),
      'saved-password',
    );
    final response = await (await proxiedClient().getUrl(
      Uri.parse('http://unresolvable.invalid/'),
    )).close();
    expect(await utf8.decodeStream(response), 'ok');
    await checked.future;
  });

  test(
    'route changes keep an established CONNECT alive and affect new connections',
    () async {
      final origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(origin.close);
      origin.listen((socket) {
        socket.listen(socket.add);
      });
      final tunnel = await connectTunnel('127.0.0.1:${origin.port}');
      addTearDown(tunnel.destroy);
      await network.configure(
        const NetworkRouteSettings(
          proxyMode: AppProxyMode.http,
          proxyHost: '127.0.0.1',
          proxyPort: 1,
        ),
        null,
      );
      tunnel.socket.add([1, 2, 3, 4]);
      expect(await tunnel.readBytes(4), [1, 2, 3, 4]);
      final proxy = Uri.parse(network.proxyUrl);
      final second = NetworkSocket(
        await Socket.connect(proxy.host, proxy.port),
      );
      addTearDown(second.destroy);
      second.socket.add(
        ascii.encode(
          'CONNECT unresolvable.invalid:${origin.port} HTTP/1.1\r\n\r\n',
        ),
      );
      expect(await second.readHeader(), startsWith('HTTP/1.1 502'));
    },
  );

  test(
    'missing restored proxy credentials block requests without blocking configuration',
    () async {
      await network.configure(
        const NetworkRouteSettings(
          proxyMode: AppProxyMode.http,
          proxyHost: '127.0.0.1',
          proxyPort: 1,
          proxyAuthenticationEnabled: true,
          proxyUsername: 'name',
        ),
        null,
      );
      final response = await (await proxiedClient().getUrl(
        Uri.parse('http://unresolvable.invalid/'),
      )).close();
      expect(response.statusCode, 502);
      await response.drain<void>();
    },
  );

  test(
    'DNS uses A and AAAA and retries truncated UDP responses over TCP',
    () async {
      final tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final udp = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        tcp.port,
      );
      addTearDown(tcp.close);
      addTearDown(udp.close);
      var tcpQueries = 0;
      Uint8List reply(List<int> query, bool truncated) {
        final type = query[query.length - 3];
        return Uint8List.fromList([
          ...query.take(2),
          0x81 | (truncated ? 2 : 0),
          0x80,
          0,
          1,
          0,
          truncated ? 0 : 1,
          0,
          0,
          0,
          0,
          ...query.skip(12),
          if (!truncated) ...[
            0xc0,
            12,
            0,
            type,
            0,
            1,
            0,
            0,
            0,
            30,
            0,
            type == 1 ? 4 : 16,
            if (type == 1) ...[127, 0, 0, 8] else ...[...List.filled(15, 0), 1],
          ],
        ]);
      }

      udp.listen((event) {
        if (event != RawSocketEvent.read) return;
        final query = udp.receive();
        if (query != null) {
          udp.send(reply(query.data, true), query.address, query.port);
        }
      });
      tcp.listen((socket) async {
        final connection = NetworkSocket(socket);
        final prefix = await connection.readBytes(2);
        final query = await connection.readBytes(prefix[0] * 256 + prefix[1]);
        tcpQueries++;
        final response = reply(query, false);
        socket.add([response.length >> 8, response.length & 255, ...response]);
        await socket.flush();
        socket.destroy();
      });
      final addresses = await DnsServerResolver(
        InternetAddress.loopbackIPv4,
        port: tcp.port,
      ).lookup('test.invalid');
      expect(
        addresses.map((address) => address.address),
        containsAll(['127.0.0.8', '::1']),
      );
      expect(tcpQueries, 2);
    },
  );

  test('overlapping configure calls apply in order', () async {
    final firstGate = Completer<void>();
    final applied = <String>[];
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => origin.close(force: true));
    origin.listen((request) async {
      request.response.write('direct-second');
      await request.response.close();
    });
    await network.close();
    network = AppNetwork(
      resolveSystemProxy: (_) async => 'DIRECT',
      applyNativeRoute: (settings, _) async {
        applied.add('${settings.proxyMode.name}:${settings.proxyPort}');
        if (settings.proxyMode == AppProxyMode.http) {
          await firstGate.future;
        }
      },
    );

    final first = network.configure(
      const NetworkRouteSettings(
        proxyMode: AppProxyMode.http,
        proxyHost: '127.0.0.1',
        proxyPort: 1,
      ),
      null,
    );
    final second = network.configure(const NetworkRouteSettings(), null);
    await Future<void>.delayed(Duration.zero);
    expect(applied, ['http:1']);
    firstGate.complete();
    await Future.wait([first, second]);

    expect(applied, ['http:1', 'system:0']);
    final response = await (await proxiedClient().getUrl(
      Uri.parse('http://127.0.0.1:${origin.port}/'),
    )).close();
    expect(await utf8.decodeStream(response), 'direct-second');
  });

  test(
    'reconfiguring custom DNS keeps an in-flight proxy lookup alive until connect finishes',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      origin.listen((request) async {
        request.response.write('resolved');
        await request.response.close();
      });
      final dnsSocket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(dnsSocket.close);
      dnsSocket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final packet = dnsSocket.receive();
        if (packet == null) return;
        final query = packet.data;
        final type = query[query.length - 3];
        final response = Uint8List.fromList([
          ...query.take(2),
          0x81,
          0x80,
          0,
          1,
          0,
          type == 1 ? 1 : 0,
          0,
          0,
          0,
          0,
          ...query.skip(12),
          if (type == 1) ...[0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 127, 0, 0, 1],
        ]);
        dnsSocket.send(response, packet.address, packet.port);
      });

      final proxyLookupStarted = Completer<void>();
      final releaseProxyLookup = Completer<void>();
      final resolvers = <DnsServerResolver>[];
      await network.close();
      network = AppNetwork(
        resolveSystemProxy: (_) async {
          if (!proxyLookupStarted.isCompleted) {
            proxyLookupStarted.complete();
          }
          await releaseProxyLookup.future;
          return 'DIRECT';
        },
        applyNativeRoute: (_, _) async {},
        createDnsResolver: (server) {
          final resolver = DnsServerResolver(server, port: dnsSocket.port);
          resolvers.add(resolver);
          return resolver;
        },
      );
      await network.configure(
        const NetworkRouteSettings(customDnsServer: '127.0.0.1'),
        null,
      );

      final responseFuture = proxiedClient()
          .getUrl(Uri.parse('http://example.invalid:${origin.port}/'))
          .then((request) => request.close());
      await proxyLookupStarted.future;

      await network.configure(
        const NetworkRouteSettings(customDnsServer: '127.0.0.2'),
        null,
      );
      expect(resolvers, hasLength(2));

      releaseProxyLookup.complete();
      final response = await responseFuture;
      expect(await utf8.decodeStream(response), 'resolved');
      await expectLater(
        resolvers.first.lookup('localhost'),
        throwsA(isA<SocketException>()),
      );
    },
  );

  test('system SOCKS policy preserves an explicit HTTP-default port', () async {
    await network.close();
    const proxyHost = 'system-proxy.invalid';
    final ports = <int>[];
    network = AppNetwork(
      resolveSystemProxy: (_) async => 'SOCKS $proxyHost:80',
    );
    final originalZone = Zone.current;
    await IOOverrides.runZoned(
      () async {
        await network.ensureStarted();
        final response = await (await proxiedClient().getUrl(
          Uri.parse('http://unresolvable.invalid/'),
        )).close();
        expect(response.statusCode, HttpStatus.badGateway);
        await response.drain<void>();
      },
      socketConnect: (host, port, {sourceAddress, sourcePort = 0, timeout}) {
        if (host == proxyHost) {
          ports.add(port);
          return Future<Socket>.error(const SocketException('test proxy'));
        }
        return originalZone.run(
          () => Socket.connect(
            host,
            port,
            sourceAddress: sourceAddress,
            sourcePort: sourcePort,
            timeout: timeout,
          ),
        );
      },
    );
    expect(ports, [80]);
  });

  test(
    'system proxy policy handles trailing semicolons and scheme-prefixed hosts',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => upstream.close(force: true));
      upstream.listen((request) async {
        request.response.write('policy-ok');
        await request.response.close();
      });
      await network.close();
      network = AppNetwork(
        resolveSystemProxy: (_) async =>
            'PROXY http://127.0.0.1:${upstream.port}; ; DIRECT;',
        applyNativeRoute: (_, _) async {},
      );
      await network.ensureStarted();

      final response = await (await proxiedClient().getUrl(
        Uri.parse('http://unresolvable.invalid/'),
      )).close();
      expect(await utf8.decodeStream(response), 'policy-ok');
    },
  );

  test(
    'fromJson and AppNetwork.configure normalize bracketed and padded custom DNS servers',
    () async {
      final parsed = NetworkRouteSettings.fromJson(<String, Object?>{
        'customDnsServer': ' [2001:4860:4860::8888] ',
      });
      expect(parsed.customDnsServer, '2001:4860:4860::8888');

      NetworkRouteSettings? appliedSettings;
      InternetAddress? resolverAddress;
      await network.close();
      network = AppNetwork(
        resolveSystemProxy: (_) async => 'DIRECT',
        applyNativeRoute: (settings, _) async {
          appliedSettings = settings;
        },
        createDnsResolver: (address) {
          resolverAddress = address;
          return DnsServerResolver(address);
        },
      );
      await network.ensureStarted();

      await network.configure(
        const NetworkRouteSettings(customDnsServer: ' [::1] '),
        null,
      );

      expect(resolverAddress, InternetAddress('::1'));
      expect(appliedSettings?.customDnsServer, '::1');
    },
  );
}
