import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/application/japanese_asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_media_sources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'header timeout retires its request before failover cancellation',
    (tester) async {
      final client = _FailoverClient();
      final service = AsmrApiService(httpClient: client);
      final token = AsmrRequestCancellationToken();
      final cancelled = expectLater(
        service.fetchWorks(
          order: 'release',
          sort: 'desc',
          cancellationToken: token,
        ),
        throwsA(isA<AsmrRequestCancelled>()),
      );
      await tester.pump();
      expect(client.requests, hasLength(1));
      await tester.pump(const Duration(seconds: 15));
      expect(client.requests, hasLength(2));
      expect(client.requests.first.aborted, isTrue);
      expect(client.requests.last.aborted, isFalse);
      token.cancel();
      await cancelled;
      expect(client.requests.last.aborted, isTrue);
      await tester.pump(const Duration(seconds: 15));
      expect(client.requests, hasLength(2));
      service.close();
    },
  );

  testWidgets(
    'openUrl timeout aborts a late connection from the retired attempt',
    (tester) async {
      final client = _FailoverClient(delayFirstOpen: true);
      final service = AsmrApiService(httpClient: client);
      final token = AsmrRequestCancellationToken();
      final cancelled = expectLater(
        service.fetchWorks(
          order: 'release',
          sort: 'desc',
          cancellationToken: token,
        ),
        throwsA(isA<AsmrRequestCancelled>()),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 15));
      expect(client.requests, hasLength(2));
      client.firstOpen.complete(client.requests.first);
      await tester.pump();
      expect(client.requests.first.aborted, isTrue);
      token.cancel();
      await cancelled;
      expect(client.requests.last.aborted, isTrue);
      await tester.pump(const Duration(seconds: 15));
      expect(client.requests, hasLength(2));
      service.close();
    },
  );

  test(
    'successful AsmrApiService request does not abort its completed HttpClientRequest',
    () async {
      final client = _RespondingClient(
        body: jsonEncode(<String, Object?>{
          'works': const <Object?>[],
          'pagination': <String, Object?>{
            'currentPage': 1,
            'pageSize': 40,
            'totalCount': 0,
          },
        }),
      );
      final service = AsmrApiService(httpClient: client);
      addTearDown(service.close);

      final page = await service.fetchWorks(order: 'release', sort: 'desc');
      expect(page.works, isEmpty);
      expect(client.requests, hasLength(1));
      expect(client.requests.single.aborted, isFalse);
    },
  );

  test(
    'AsmrApiService failover snapshots domains so concurrent setPreferredDomain cannot skip candidates',
    () async {
      late AsmrApiService service;
      final attemptedHosts = <String>[];
      var firstCall = true;
      final client = _RespondingClient(
        body: jsonEncode(<String, Object?>{
          'works': const <Object?>[],
          'pagination': <String, Object?>{
            'currentPage': 1,
            'pageSize': 40,
            'totalCount': 0,
          },
        }),
        onOpenUrl: (uri) {
          attemptedHosts.add(uri.origin);
          if (firstCall) {
            firstCall = false;
            // Reorder domains mid-failover; snapshot must still visit the rest cleanly.
            service.setPreferredDomain(asmrApiDomains.last);
            return Future<HttpClientRequest>.error(
              const SocketException('first candidate failed'),
            );
          }
          return null;
        },
      );
      service = AsmrApiService(httpClient: client);
      addTearDown(service.close);

      final page = await service.fetchWorks(order: 'release', sort: 'desc');
      expect(page.works, isEmpty);
      expect(attemptedHosts, hasLength(2));
      expect(attemptedHosts[0], isNot(attemptedHosts[1]));
    },
  );

  test(
    'JapaneseAsmrApiService configures connectionTimeout and does not abort completed requests',
    () async {
      final client = _RespondingClient(
        body: jsonEncode(<String, Object?>{'items': const <Object?>[], 'total': 0}),
      );
      final service = JapaneseAsmrApiService(httpClient: client);
      addTearDown(service.close);

      expect(client.connectionTimeout, isNotNull);
      final page = await service.searchWorks(keyword: 'test');
      expect(page.works, isEmpty);
      expect(client.requests, hasLength(1));
      expect(client.requests.single.aborted, isFalse);
    },
  );
}

class _FailoverClient extends Fake implements HttpClient {
  _FailoverClient({this.delayFirstOpen = false});

  final bool delayFirstOpen;
  final firstOpen = Completer<HttpClientRequest>();
  final requests = <_WaitingHeadersRequest>[];

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    final request = _WaitingHeadersRequest();
    requests.add(request);
    if (delayFirstOpen && requests.length == 1) return firstOpen.future;
    return Future.value(request);
  }

  @override
  void close({bool force = false}) {}
}

class _WaitingHeadersRequest extends Fake implements HttpClientRequest {
  final _headers = _RequestHeaders();
  final _response = Completer<HttpClientResponse>();
  bool _closed = false;
  bool aborted = false;

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<HttpClientResponse> close() {
    _closed = true;
    return _response.future;
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
    if (_closed && !_response.isCompleted) {
      _response.completeError(exception ?? const HttpException('aborted'));
    }
  }
}

class _RequestHeaders extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
}

class _RespondingClient extends Fake implements HttpClient {
  _RespondingClient({required this.body, this.onOpenUrl});

  final String body;
  final Future<HttpClientRequest>? Function(Uri uri)? onOpenUrl;
  final requests = <_RespondingRequest>[];

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    final override = onOpenUrl?.call(url);
    if (override != null) return override;
    final request = _RespondingRequest(body);
    requests.add(request);
    return Future<HttpClientRequest>.value(request);
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  void close({bool force = false}) {}
}

class _RespondingRequest extends Fake implements HttpClientRequest {
  _RespondingRequest(this._body);

  final String _body;
  final _headers = _RequestHeaders();
  bool aborted = false;

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<HttpClientResponse> close() =>
      Future<HttpClientResponse>.value(_RespondingResponse(_body));

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
  }
}

class _RespondingResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _RespondingResponse(this._body);

  final String _body;

  @override
  int get statusCode => HttpStatus.ok;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(utf8.encode(_body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
