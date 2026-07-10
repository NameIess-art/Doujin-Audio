import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/asmr_api_service.dart';

void main() {
  test(
    'ASMR API requests include the language accepted by the gateway',
    () async {
      final language = Completer<String?>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        language.complete(
          request.headers.value(HttpHeaders.acceptLanguageHeader),
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{
            'works': const <Object?>[],
            'pagination': const <String, Object?>{
              'currentPage': 1,
              'pageSize': 1,
              'totalCount': 0,
            },
          }),
        );
        await request.response.close();
      });

      try {
        final service = AsmrApiService(
          baseUri: Uri.parse('http://${server.address.address}:${server.port}'),
        );

        await service.fetchWorks(order: 'release', sort: 'desc', pageSize: 1);

        expect(await language.future, 'zh-CN,zh;q=0.9,en;q=0.8');
      } finally {
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test('ASMR API errors do not expose an HTML rejection page', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.headers.contentType = ContentType.html;
      request.response.write('<!doctype html><html>gateway rejection</html>');
      await request.response.close();
    });

    try {
      final service = AsmrApiService(
        baseUri: Uri.parse('http://${server.address.address}:${server.port}'),
      );

      await expectLater(
        service.fetchWorks(order: 'release', sort: 'desc'),
        throwsA(
          isA<AsmrApiException>()
              .having((error) => error.statusCode, 'statusCode', 403)
              .having(
                (error) => error.message,
                'message',
                allOf(contains('(403)'), isNot(contains('<html>'))),
              ),
        ),
      );
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
