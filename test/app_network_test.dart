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
}
