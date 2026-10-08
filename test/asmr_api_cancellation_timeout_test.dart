import 'dart:async';
import 'dart:io';

import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
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
