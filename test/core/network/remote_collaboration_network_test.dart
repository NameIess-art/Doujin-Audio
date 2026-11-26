import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:doujin_audio/core/media/playback_media_reference.dart';
import 'package:doujin_audio/core/network/app_network.dart';
import 'package:doujin_audio/core/network/network_route_settings.dart';
import 'package:doujin_audio/core/network/remote_source_headers.dart';
import 'package:doujin_audio/core/network/webdav_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isLocalOrPrivateNetworkHost & AppNetwork LAN bypass', () {
    test('classifies loopback, RFC1918, CGNAT, link-local, IPv6 ULA, and .local', () {
      expect(isLocalOrPrivateNetworkHost('localhost'), isTrue);
      expect(isLocalOrPrivateNetworkHost('sub.localhost'), isTrue);
      expect(isLocalOrPrivateNetworkHost('synology-nas.local'), isTrue);
      expect(isLocalOrPrivateNetworkHost('127.0.0.1'), isTrue);
      expect(isLocalOrPrivateNetworkHost('10.0.0.12'), isTrue);
      expect(isLocalOrPrivateNetworkHost('172.16.0.1'), isTrue);
      expect(isLocalOrPrivateNetworkHost('172.31.255.254'), isTrue);
      expect(isLocalOrPrivateNetworkHost('192.168.50.10'), isTrue);
      expect(isLocalOrPrivateNetworkHost('100.64.12.34'), isTrue);
      expect(isLocalOrPrivateNetworkHost('169.254.10.20'), isTrue);
      expect(isLocalOrPrivateNetworkHost('[::1]'), isTrue);
      expect(isLocalOrPrivateNetworkHost('[fd12:3456:789a::1]'), isTrue);
      expect(isLocalOrPrivateNetworkHost('[fe80::1%eth0]'), isTrue);
      expect(isLocalOrPrivateNetworkHost('[::ffff:192.168.1.9]'), isTrue);

      expect(isLocalOrPrivateNetworkHost('8.8.8.8'), isFalse);
      expect(isLocalOrPrivateNetworkHost('172.32.0.1'), isFalse);
      expect(isLocalOrPrivateNetworkHost('100.128.0.1'), isFalse);
      expect(isLocalOrPrivateNetworkHost('api.asmr.one'), isFalse);
    });

    test('AppNetwork connects directly to loopback/LAN targets when proxy is unreachable', () async {
      final lanServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => lanServer.close(force: true));
      lanServer.listen((request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('lan-direct-ok');
        await request.response.close();
      });

      final deadProxySocket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final deadProxyPort = deadProxySocket.port;
      await deadProxySocket.close();

      var systemProxyQueries = 0;
      final network = AppNetwork(
        resolveSystemProxy: (_) async {
          systemProxyQueries++;
          return 'PROXY 127.0.0.1:$deadProxyPort';
        },
        applyNativeRoute: (_, _) async {},
      );
      addTearDown(network.close);

      for (final mode in <AppProxyMode>[
        AppProxyMode.system,
        AppProxyMode.http,
        AppProxyMode.socks5,
      ]) {
        await network.configure(
          NetworkRouteSettings(
            proxyMode: mode,
            proxyHost: '127.0.0.1',
            proxyPort: deadProxyPort,
            customDnsServer: '192.0.2.53',
          ),
          null,
        );
        final client = network.createHttpClient(null);
        try {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${lanServer.port}/api/v1/info'),
          );
          final response = await request.close();
          final body = await response.transform(utf8.decoder).join();
          expect(response.statusCode, HttpStatus.ok, reason: mode.name);
          expect(body, 'lan-direct-ok', reason: mode.name);
        } finally {
          client.close(force: true);
        }
      }
      expect(systemProxyQueries, 0);
    });
  });

  group('RemoteSourceHeaderRegistry scoping', () {
    tearDown(() {
      RemoteSourceHeaderRegistry.instance.clear();
    });

    test('injects credentials only for matching scheme, host, port, and path prefix', () {
      final registry = RemoteSourceHeaderRegistry();
      registry.upsertRule(
        RemoteSourceHeaderRule.basicAuth(
          id: 'nas-1',
          baseUri: Uri.parse('http://192.168.1.20:5005/Audio%20Library/'),
          username: 'listener',
          password: 'secret',
        ),
      );

      final inside = registry.headersForUri(
        Uri.parse('http://192.168.1.20:5005/Audio%20Library/RJ123456/01.flac'),
      );
      expect(inside[HttpHeaders.authorizationHeader], startsWith('Basic '));

      // Sibling prefix, different port, different scheme, or different host must not receive credentials.
      expect(
        registry.headersForUri(
          Uri.parse('http://192.168.1.20:5005/Audio%20Library2/01.flac'),
        ),
        isEmpty,
      );
      expect(
        registry.headersForUri(
          Uri.parse('http://192.168.1.20:8080/Audio%20Library/01.flac'),
        ),
        isEmpty,
      );
      expect(
        registry.headersForUri(
          Uri.parse('https://192.168.1.20:5005/Audio%20Library/01.flac'),
        ),
        isEmpty,
      );
      expect(
        registry.headersForUri(
          Uri.parse('http://192.168.1.99:5005/Audio%20Library/01.flac'),
        ),
        isEmpty,
      );
    });

    test('PlaybackMediaReference.parse attaches registered headers for remote source URLs', () {
      RemoteSourceHeaderRegistry.instance.upsertRule(
        RemoteSourceHeaderRule.bearerToken(
          id: 'lan-1',
          baseUri: Uri.parse('http://192.168.1.10:42891'),
          token: '654321',
        ),
      );
      final ref = PlaybackMediaReference.parse(
        'http://192.168.1.10:42891/api/v1/files/f123',
      );
      expect(ref.httpHeaders[HttpHeaders.authorizationHeader], 'Bearer 654321');
    });
  });

  group('WebDavClient XML parsing & HTTP operations', () {
    test('parseWebDavMultistatus handles Synology/alist/Nextcloud namespaces and CJK paths', () {
      const xml = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/%E9%9F%B3%E5%A3%B0/</D:href>
    <D:propstat>
      <D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/%E9%9F%B3%E5%A3%B0/%5BCircle%5D%20RJ123456%20%E8%80%B3%E8%88%90/</D:href>
    <D:propstat>
      <D:prop>
        <D:resourcetype><D:collection/></D:resourcetype>
        <D:getlastmodified>Mon, 23 Nov 2026 12:00:00 GMT</D:getlastmodified>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/%E9%9F%B3%E5%A3%B0/track%2001.flac</D:href>
    <D:propstat>
      <D:prop>
        <D:resourcetype/>
        <D:getcontentlength>1048576</D:getcontentlength>
        <D:getetag>"etag-abc"</D:getetag>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>''';

      final requestUri = Uri.parse('http://nas.local:5005/dav/%E9%9F%B3%E5%A3%B0/');
      final entries = parseWebDavMultistatus(
        xml,
        requestUri: requestUri,
      );
      expect(entries, hasLength(2));
      expect(entries[0].isDirectory, isTrue);
      expect(entries[0].name, '[Circle] RJ123456 耳舐');
      expect(entries[1].isDirectory, isFalse);
      expect(entries[1].name, 'track 01.flac');
      expect(entries[1].contentLength, 1048576);
      expect(entries[1].etag, '"etag-abc"');
    });

    test('parseWebDavMultistatus encodes unescaped special characters without double-encoding percent escapes', () {
      const xml = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/work/%5BCV%5D%20%7BBonus%7D%20track%20%231.mp3</D:href>
    <D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/work/[CV] {Bonus} #2 音声.mp4</D:href>
    <D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>''';
      final requestUri = Uri.parse('http://nas.local:5005/dav/work/');
      final entries = parseWebDavMultistatus(xml, requestUri: requestUri);
      expect(entries, hasLength(2));
      expect(entries[0].name, '[CV] {Bonus} track #1.mp3');
      expect(
        entries[0].uri.toString(),
        'http://nas.local:5005/dav/work/%5BCV%5D%20%7BBonus%7D%20track%20%231.mp3',
      );
      expect(entries[1].name, '[CV] {Bonus} #2 音声.mp4');
      expect(entries[1].uri.toString(), contains('%7BBonus%7D'));
      expect(entries[1].uri.toString(), contains('%232'));
    });

    test('WebDavClient performs MKCOL, PROPFIND, atomic PUT+MOVE, and fallback PUT', () async {
      final storage = <String, Uint8List>{};
      final directories = <String>{'/', '/sync/'};
      var rejectMove = false;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        final auth = req.headers.value(HttpHeaders.authorizationHeader);
        if (auth != 'Basic ${base64.encode(utf8.encode('user:pass'))}') {
          req.response.statusCode = HttpStatus.unauthorized;
          await req.response.close();
          return;
        }
        final decodedPath = Uri.decodeFull(req.uri.path);
        switch (req.method) {
          case 'MKCOL':
            final dir = decodedPath.endsWith('/') ? decodedPath : '$decodedPath/';
            directories.add(dir);
            req.response.statusCode = HttpStatus.created;
            await req.response.close();
          case 'PUT':
            final bytes = BytesBuilder();
            await for (final chunk in req) {
              bytes.add(chunk);
            }
            storage[decodedPath] = bytes.takeBytes();
            req.response.statusCode = HttpStatus.created;
            await req.response.close();
          case 'MOVE':
            if (rejectMove) {
              req.response.statusCode = HttpStatus.notImplemented;
              await req.response.close();
              return;
            }
            final destHeader = req.headers.value('Destination')!;
            final destPath = Uri.decodeFull(Uri.parse(destHeader).path);
            storage[destPath] = storage.remove(decodedPath)!;
            req.response.statusCode = HttpStatus.noContent;
            await req.response.close();
          case 'DELETE':
            storage.remove(decodedPath);
            req.response.statusCode = HttpStatus.noContent;
            await req.response.close();
          case 'GET':
            final payload = storage[decodedPath];
            if (payload == null) {
              req.response.statusCode = HttpStatus.notFound;
            } else {
              req.response.statusCode = HttpStatus.ok;
              req.response.add(payload);
            }
            await req.response.close();
          case 'PROPFIND':
            final dirCheck = decodedPath.endsWith('/')
                ? decodedPath
                : '$decodedPath/';
            if (!directories.contains(dirCheck) &&
                !storage.containsKey(decodedPath)) {
              req.response.statusCode = HttpStatus.notFound;
              await req.response.close();
              return;
            }
            final xmlBuf = StringBuffer(
              '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">',
            );
            xmlBuf.write(
              '<d:response><d:href>${req.uri.path}</d:href>'
              '<d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>'
              '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
            );
            for (final entry in storage.entries) {
              if (entry.key.startsWith(decodedPath) && entry.key != decodedPath) {
                final rel = entry.key.substring(decodedPath.length);
                if (!rel.contains('/')) {
                  xmlBuf.write(
                    '<d:response><d:href>${req.uri.path}${Uri.encodeComponent(rel)}</d:href>'
                    '<d:propstat><d:prop><d:resourcetype/>'
                    '<d:getcontentlength>${entry.value.length}</d:getcontentlength>'
                    '<d:getetag>"v1"</d:getetag></d:prop>'
                    '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
                  );
                }
              }
            }
            xmlBuf.write('</d:multistatus>');
            req.response.statusCode = HttpStatus.multiStatus;
            req.response.write(xmlBuf.toString());
            await req.response.close();
          default:
            req.response.statusCode = HttpStatus.methodNotAllowed;
            await req.response.close();
        }
      });

      final client = WebDavClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}/sync/'),
        username: 'user',
        password: 'pass',
      );
      addTearDown(client.close);

      final devicesUri = client.resolveRelativePath('devices', isDirectory: true);
      await client.ensureDirectory(devicesUri);
      expect(directories.contains('/sync/devices/'), isTrue);

      final shardUri = client.resolveRelativePath('devices/dev-a.dasync');
      await client.putBytesAtomic(shardUri, Uint8List.fromList(<int>[1, 2, 3, 4]));
      expect(storage['/sync/devices/dev-a.dasync'], <int>[1, 2, 3, 4]);
      expect(storage.keys.any((k) => k.endsWith('.part')), isFalse);

      // Verify fallback direct PUT when server does not implement MOVE.
      rejectMove = true;
      await client.putBytesAtomic(shardUri, Uint8List.fromList(<int>[9, 8, 7]));
      expect(storage['/sync/devices/dev-a.dasync'], <int>[9, 8, 7]);
      expect(storage.keys.any((k) => k.endsWith('.part')), isFalse);

      final listed = await client.listDirectory(devicesUri);
      expect(listed.single.name, 'dev-a.dasync');
      expect(await client.getBytes(shardUri), <int>[9, 8, 7]);
    });
  });
}
