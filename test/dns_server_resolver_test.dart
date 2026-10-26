import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:doujin_audio/core/network/app_network.dart';
import 'package:doujin_audio/core/network/dns_server_resolver.dart';
import 'package:doujin_audio/core/network/network_route_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'publishes the successful family before the other family replies',
    () async {
      final releaseIpv6 = Completer<void>();
      final dns = await _DnsFixture.start((_, type) async {
        if (type == 28) await releaseIpv6.future;
        return type == 1 ? [127, 0, 0, 1] : [...List.filled(15, 0), 1];
      });
      addTearDown(dns.close);
      final resolver = dns.resolver();
      addTearDown(resolver.close);
      final iterator = StreamIterator(
        resolver.lookupAddresses('example.invalid'),
      );
      addTearDown(iterator.cancel);
      expect(
        await iterator.moveNext().timeout(const Duration(seconds: 1)),
        isTrue,
      );
      expect(iterator.current.address, '127.0.0.1');
      expect(releaseIpv6.isCompleted, isFalse);
      releaseIpv6.complete();
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current.address, '::1');
      expect(await iterator.moveNext(), isFalse);
    },
  );

  test(
    'coalesces concurrent queries and reuses normalized TTL cache',
    () async {
      final release = Completer<void>();
      final dns = await _DnsFixture.start((_, type) async {
        await release.future;
        return type == 1 ? [127, 0, 0, 1] : [...List.filled(15, 0), 1];
      });
      addTearDown(dns.close);
      final resolver = dns.resolver();
      addTearDown(resolver.close);
      final first = resolver.lookup('Example.INVALID');
      final second = resolver.lookup('example.invalid.');
      release.complete();
      expect(await first, hasLength(2));
      expect(await second, hasLength(2));
      expect(await resolver.lookup('example.invalid'), hasLength(2));
      expect(dns.queries, {'example.invalid/1': 1, 'example.invalid/28': 1});
    },
  );

  test(
    'expires answers at their DNS TTL and does not cache zero TTL',
    () async {
      var now = DateTime.utc(2026);
      final dns = await _DnsFixture.start(
        (_, type) async =>
            type == 1 ? [127, 0, 0, 1] : [...List.filled(15, 0), 1],
      );
      addTearDown(dns.close);
      dns.ttl = 2;
      final resolver = dns.resolver(now: () => now);
      addTearDown(resolver.close);
      await resolver.lookup('example.invalid');
      now = now.add(const Duration(seconds: 1));
      await resolver.lookup('example.invalid');
      expect(dns.queries['example.invalid/1'], 1);
      now = now.add(const Duration(seconds: 1));
      dns.ttl = 0;
      await resolver.lookup('example.invalid');
      await resolver.lookup('example.invalid');
      expect(dns.queries['example.invalid/1'], 3);
      expect(dns.queries['example.invalid/28'], 3);
    },
  );

  test(
    'bounds cached address families and evicts the oldest entries',
    () async {
      final dns = await _DnsFixture.start(
        (_, type) async =>
            type == 1 ? [127, 0, 0, 1] : [...List.filled(15, 0), 1],
      );
      addTearDown(dns.close);
      final resolver = dns.resolver(cacheCapacity: 4);
      addTearDown(resolver.close);
      for (var i = 0; i < 3; i++) {
        await resolver.lookup('host-$i.invalid');
      }
      await resolver.lookup('host-0.invalid');
      expect(dns.queries['host-0.invalid/1'], 2);
      expect(dns.queries['host-0.invalid/28'], 2);
      await resolver.lookup('host-2.invalid');
      expect(dns.queries['host-2.invalid/1'], 1);
    },
  );

  test(
    'closing aborts pending queries without waiting for the DNS timeout',
    () async {
      final received = Completer<void>();
      final dns = await _DnsFixture.start((_, _) async {
        if (!received.isCompleted) received.complete();
        return null;
      });
      addTearDown(dns.close);
      final resolver = dns.resolver();
      final lookup = resolver.lookup('localhost');
      final failed = expectLater(lookup, throwsA(isA<SocketException>()));
      await received.future;
      resolver.close();
      await failed.timeout(const Duration(seconds: 1));
      await expectLater(
        resolver.lookup('127.0.0.1'),
        throwsA(isA<SocketException>()),
      );
    },
  );

  test(
    'direct routes start with the ready family and isolate cache on reconfigure',
    () async {
      final releaseIpv6 = Completer<void>();
      final dns = await _DnsFixture.start((_, type) async {
        if (type == 28) {
          await releaseIpv6.future;
          return null;
        }
        return [127, 0, 0, 1];
      });
      addTearDown(dns.close);
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      origin.listen((request) async {
        request.response.write('ok');
        await request.response.close();
      });
      var createdResolvers = 0;
      final network = AppNetwork(
        resolveSystemProxy: (_) async => 'DIRECT',
        applyNativeRoute: (_, _) async {},
        createDnsResolver: (_) {
          createdResolvers++;
          return dns.resolver();
        },
      );
      addTearDown(network.close);
      const route = NetworkRouteSettings(customDnsServer: '127.0.0.1');
      await network.configure(route, null);
      final client = _RealHttp().client();
      addTearDown(() => client.close(force: true));
      final proxy = Uri.parse(network.proxyUrl);
      client.findProxy = (_) => 'PROXY ${proxy.host}:${proxy.port}';
      Future<String> request() async {
        final response = await (await client.getUrl(
          Uri.parse('http://example.invalid:${origin.port}/'),
        )).close();
        expect(response.statusCode, 200);
        return utf8.decodeStream(response);
      }

      expect(await request().timeout(const Duration(seconds: 1)), 'ok');
      expect(releaseIpv6.isCompleted, isFalse);
      await network.configure(route, null);
      expect(await request(), 'ok');
      expect(createdResolvers, 1);
      expect(dns.queries['example.invalid/1'], 1);
      await network.configure(
        route.copyWith(customDnsServer: '127.0.0.2'),
        null,
      );
      expect(await request(), 'ok');
      expect(createdResolvers, 2);
      expect(dns.queries['example.invalid/1'], 2);
      releaseIpv6.complete();
    },
  );

  test(
    'direct routes retain delayed IPv4 fallback after IPv6 connect fails',
    () async {
      final releaseIpv4 = Completer<void>();
      final dns = await _DnsFixture.start((_, type) async {
        if (type == 1) {
          await releaseIpv4.future;
          return [127, 0, 0, 1];
        }
        return [...List.filled(15, 0), 1];
      });
      addTearDown(dns.close);
      // Only IPv4 is listening at this port, so the first IPv6 attempt fails.
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      origin.listen((request) async {
        request.response.write('fallback');
        await request.response.close();
      });
      final network = AppNetwork(
        resolveSystemProxy: (_) async => 'DIRECT',
        applyNativeRoute: (_, _) async {},
        createDnsResolver: (_) => dns.resolver(),
        startSocketConnect: (address, port) async {
          final task = await Socket.startConnect(address, port);
          if (address.type == InternetAddressType.IPv6) {
            unawaited(
              task.socket.then<void>(
                (_) {},
                onError: (Object _) {
                  releaseIpv4.complete();
                },
              ),
            );
          }
          return task;
        },
      );
      addTearDown(network.close);
      await network.configure(
        const NetworkRouteSettings(customDnsServer: '127.0.0.1'),
        null,
      );
      final client = _RealHttp().client();
      addTearDown(() => client.close(force: true));
      final proxy = Uri.parse(network.proxyUrl);
      client.findProxy = (_) => 'PROXY ${proxy.host}:${proxy.port}';
      final response = (await client.getUrl(
        Uri.parse('http://fallback.invalid:${origin.port}/'),
      )).close();
      expect(await utf8.decodeStream(await response), 'fallback');
      expect(releaseIpv4.isCompleted, isTrue);
    },
  );

  test(
    'a hanging first address cannot block the ready family and is cancelled',
    () async {
      final ipv6Started = Completer<void>();
      final hanging = Completer<Socket>();
      var cancelled = false;
      final dns = await _DnsFixture.start((_, type) async {
        if (type == 1) {
          await ipv6Started.future;
          return [127, 0, 0, 1];
        }
        return [...List.filled(15, 0), 1];
      });
      addTearDown(dns.close);
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      origin.listen((request) async {
        request.response.write('second address');
        await request.response.close();
      });
      final network = AppNetwork(
        resolveSystemProxy: (_) async => 'DIRECT',
        applyNativeRoute: (_, _) async {},
        createDnsResolver: (_) => dns.resolver(),
        startSocketConnect: (address, port) async {
          if (address.type == InternetAddressType.IPv6) {
            ipv6Started.complete();
            return ConnectionTask.fromSocket(hanging.future, () {
              cancelled = true;
              if (!hanging.isCompleted) {
                hanging.completeError(
                  const SocketException('Cancelled test attempt'),
                );
              }
            });
          }
          return Socket.startConnect(address, port);
        },
      );
      addTearDown(network.close);
      await network.configure(
        const NetworkRouteSettings(customDnsServer: '127.0.0.1'),
        null,
      );
      final client = _RealHttp().client();
      addTearDown(() => client.close(force: true));
      final proxy = Uri.parse(network.proxyUrl);
      client.findProxy = (_) => 'PROXY ${proxy.host}:${proxy.port}';
      final response = await (await client.getUrl(
        Uri.parse('http://fallback.invalid:${origin.port}/'),
      )).close().timeout(const Duration(seconds: 2));
      expect(await utf8.decodeStream(response), 'second address');
      expect(cancelled, isTrue);
    },
  );
}

class _RealHttp extends HttpOverrides {
  HttpClient client() => super.createHttpClient(null);
}

class _DnsFixture {
  _DnsFixture(this.socket, this.answer);

  final RawDatagramSocket socket;
  final Future<List<int>?> Function(String, int) answer;
  final queries = <String, int>{};
  int ttl = 30;
  bool _closed = false;

  static Future<_DnsFixture> start(
    Future<List<int>?> Function(String, int) answer,
  ) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final fixture = _DnsFixture(socket, answer);
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = socket.receive()) != null) {
        unawaited(fixture._reply(packet!));
      }
    });
    return fixture;
  }

  DnsServerResolver resolver({
    DateTime Function()? now,
    int cacheCapacity = 256,
  }) => DnsServerResolver(
    InternetAddress.loopbackIPv4,
    port: socket.port,
    timeout: const Duration(seconds: 10),
    now: now,
    cacheCapacity: cacheCapacity,
  );

  Future<void> _reply(Datagram packet) async {
    final query = packet.data;
    final labels = <String>[];
    var offset = 12;
    while (query[offset] != 0) {
      final length = query[offset++];
      labels.add(ascii.decode(query.sublist(offset, offset + length)));
      offset += length;
    }
    final name = labels.join('.');
    final type = query[query.length - 3];
    queries.update('$name/$type', (count) => count + 1, ifAbsent: () => 1);
    final address = await answer(name, type);
    if (_closed || address == null) return;
    final response = Uint8List.fromList([
      ...query.take(2),
      0x81,
      0x80,
      0,
      1,
      0,
      1,
      0,
      0,
      0,
      0,
      ...query.skip(12),
      0xc0,
      12,
      0,
      type,
      0,
      1,
      (ttl >> 24) & 255,
      (ttl >> 16) & 255,
      (ttl >> 8) & 255,
      ttl & 255,
      0,
      address.length,
      ...address,
    ]);
    socket.send(response, packet.address, packet.port);
  }

  void close() {
    _closed = true;
    socket.close();
  }
}
