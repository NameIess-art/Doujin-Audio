import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Awaits a cancellable socket connection and destroys any socket that races
/// past [cancel] after [timeout] fires.
Future<Socket> awaitCancellableSocket(
  Future<Socket> socket, {
  required void Function() cancel,
  required Duration timeout,
  required String timeoutMessage,
}) => socket.timeout(
  timeout,
  onTimeout: () {
    cancel();
    unawaited(
      socket.then<void>(
        (lateSocket) => lateSocket.destroy(),
        onError: (Object _, StackTrace _) {},
      ),
    );
    throw TimeoutException(timeoutMessage, timeout);
  },
);

/// Keeps handshake bytes and payload in one subscription. TLS stays end-to-end
/// between the consumer and the origin, including through SOCKS tunnels.
class NetworkSocket {
  NetworkSocket(this.socket);

  static final Uint8List _emptyBytes = Uint8List(0);

  final Socket socket;
  // Cancelled by remaining's onCancel or destroy().
  // ignore: cancel_subscriptions
  StreamSubscription<Uint8List>? _subscription;
  final Queue<Uint8List> _bufferedChunks = Queue<Uint8List>();
  Completer<Uint8List?>? _chunkWaiter;
  Object? _streamError;
  StackTrace? _streamStackTrace;
  bool _streamDone = false;
  bool _subscriptionPaused = false;
  Uint8List _pending = _emptyBytes;
  int _offset = 0;

  void _pauseSubscription() {
    if (_subscription != null && !_subscriptionPaused) {
      _subscriptionPaused = true;
      _subscription!.pause();
    }
  }

  void _resumeSubscription() {
    if (_subscription != null && _subscriptionPaused) {
      _subscriptionPaused = false;
      _subscription!.resume();
    }
  }

  void _ensureSubscribed() {
    if (_subscription != null) {
      _resumeSubscription();
      return;
    }
    _subscription = socket.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );
  }

  void _onData(Uint8List chunk) {
    _pauseSubscription();
    final waiter = _chunkWaiter;
    if (waiter != null) {
      _chunkWaiter = null;
      waiter.complete(chunk);
    } else {
      _bufferedChunks.addLast(chunk);
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    final waiter = _chunkWaiter;
    if (waiter != null) {
      _chunkWaiter = null;
      waiter.completeError(error, stackTrace);
    } else {
      _streamError = error;
      _streamStackTrace = stackTrace;
    }
  }

  void _onDone() {
    _streamDone = true;
    final waiter = _chunkWaiter;
    if (waiter != null) {
      _chunkWaiter = null;
      waiter.complete(null);
    }
  }

  Future<Uint8List?> _readNextChunk() {
    if (_bufferedChunks.isNotEmpty) {
      return Future<Uint8List?>.value(_bufferedChunks.removeFirst());
    }
    if (_streamError != null) {
      final error = _streamError!;
      final stackTrace = _streamStackTrace;
      _streamError = null;
      _streamStackTrace = null;
      return Future<Uint8List?>.error(error, stackTrace);
    }
    if (_streamDone) {
      return Future<Uint8List?>.value();
    }
    final waiter = Completer<Uint8List?>();
    _chunkWaiter = waiter;
    _ensureSubscribed();
    return waiter.future;
  }

  Future<List<int>> readBytes(int count) async {
    final result = <int>[];
    while (result.length < count) {
      if (_offset == _pending.length) {
        final next = await _readNextChunk();
        if (next == null) {
          throw const SocketException('Connection closed during handshake');
        }
        _pending = next;
        _offset = 0;
      }
      final remaining = count - result.length;
      final available = _pending.length - _offset;
      final take = remaining < available ? remaining : available;
      result.addAll(_pending.sublist(_offset, _offset + take));
      _offset += take;
    }
    return result;
  }

  Future<String> readHeader() async {
    const maxBytes = 65536;
    final builder = BytesBuilder(copy: false);
    var matched = 0;
    while (builder.length < maxBytes) {
      if (_offset == _pending.length) {
        final next = await _readNextChunk();
        if (next == null) {
          throw const SocketException('Connection closed during handshake');
        }
        _pending = next;
        _offset = 0;
        if (_pending.isEmpty) continue;
      }
      final remainingBudget = maxBytes - builder.length;
      final available = _pending.length - _offset;
      final limit =
          _offset + (remainingBudget < available ? remainingBudget : available);
      var index = _offset;
      while (index < limit) {
        final byte = _pending[index++];
        if (matched == 0) {
          if (byte == 13) matched = 1;
        } else if (matched == 1) {
          matched = byte == 10 ? 2 : (byte == 13 ? 1 : 0);
        } else if (matched == 2) {
          matched = byte == 13 ? 3 : 0;
        } else {
          if (byte == 10) {
            matched = 4;
            break;
          }
          matched = byte == 13 ? 1 : 0;
        }
      }
      final start = _offset;
      _offset = index;
      if (start == 0 && index == _pending.length) {
        builder.add(_pending);
      } else {
        builder.add(Uint8List.sublistView(_pending, start, index));
      }
      if (matched == 4) {
        return latin1.decode(builder.takeBytes());
      }
    }
    throw const HttpException('HTTP header exceeds 64 KiB');
  }

  /// Forwards any leftover handshake bytes and then attaches the raw socket
  /// stream directly to the consumer without per-chunk async* overhead.
  Stream<List<int>> get remaining {
    if (_subscription == null && _offset == _pending.length) {
      return socket;
    }
    var handedOff = false;
    var cancelled = false;
    late final StreamController<Uint8List> controller;

    void drainAndAttach() {
      if (cancelled || controller.isClosed || !controller.hasListener) return;
      if (_offset < _pending.length) {
        if (controller.isPaused) return;
        final leftover = Uint8List.sublistView(_pending, _offset);
        _pending = _emptyBytes;
        _offset = 0;
        controller.add(leftover);
      }
      while (_bufferedChunks.isNotEmpty) {
        if (cancelled || controller.isClosed || controller.isPaused) return;
        controller.add(_bufferedChunks.removeFirst());
      }
      if (cancelled || controller.isClosed) return;
      if (_streamError != null) {
        final error = _streamError!;
        final stack = _streamStackTrace;
        _streamError = null;
        _streamStackTrace = null;
        controller.addError(error, stack);
      }
      if (_streamDone) {
        unawaited(controller.close());
        return;
      }
      if (controller.isPaused) return;
      handedOff = true;
      _subscription!
        ..onData(controller.add)
        ..onError(controller.addError)
        ..onDone(() => unawaited(controller.close()));
      _resumeSubscription();
    }

    controller = StreamController<Uint8List>(
      sync: true,
      onListen: () => scheduleMicrotask(drainAndAttach),
      onPause: _pauseSubscription,
      onResume: () {
        if (handedOff) {
          _resumeSubscription();
        } else {
          scheduleMicrotask(drainAndAttach);
        }
      },
      onCancel: () {
        cancelled = true;
        final subscription = _subscription;
        _subscription = null;
        _subscriptionPaused = false;
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  Future<void> socksConnect(
    String host,
    int port, {
    String? username,
    String? password,
  }) async {
    final authenticated = username != null && password != null;
    socket.add([5, 1, authenticated ? 2 : 0]);
    final greeting = await readBytes(2);
    if (greeting[0] != 5 || greeting[1] != (authenticated ? 2 : 0)) {
      throw const SocketException('SOCKS5 authentication method rejected');
    }
    if (authenticated) {
      final name = utf8.encode(username);
      final secret = utf8.encode(password);
      if (name.isEmpty || name.length > 255 || secret.length > 255) {
        throw const FormatException(
          'SOCKS5 credentials exceed protocol limits',
        );
      }
      socket.add([1, name.length, ...name, secret.length, ...secret]);
      final response = await readBytes(2);
      if (response[0] != 1 || response[1] != 0) {
        throw const SocketException('SOCKS5 authentication failed');
      }
    }
    final address = InternetAddress.tryParse(host);
    final name = utf8.encode(host);
    if (address == null && (name.isEmpty || name.length > 255)) {
      throw const FormatException('Invalid SOCKS5 target');
    }
    socket.add([
      5,
      1,
      0,
      if (address != null) ...[
        address.type == InternetAddressType.IPv4 ? 1 : 4,
        ...address.rawAddress,
      ] else ...[
        3,
        name.length,
        ...name,
      ],
      port >> 8,
      port & 255,
    ]);
    final response = await readBytes(4);
    if (response[0] != 5 || response[1] != 0 || response[2] != 0) {
      throw const SocketException('SOCKS5 connection rejected');
    }
    final length = switch (response[3]) {
      1 => 4,
      4 => 16,
      3 => (await readBytes(1)).single,
      _ => throw const SocketException('Invalid SOCKS5 address type'),
    };
    await readBytes(length + 2);
  }

  Future<void> httpConnect(
    String host,
    int port, {
    String? authorization,
  }) async {
    final authority = host.contains(':') ? '[$host]:$port' : '$host:$port';
    socket.add(
      latin1.encode(
        'CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n'
        '${authorization == null ? '' : 'Proxy-Authorization: $authorization\r\n'}\r\n',
      ),
    );
    final header = await readHeader();
    if (!RegExp(r'^HTTP/1\.[01] 200(?:\s|\r)').hasMatch(header)) {
      throw const SocketException('HTTP proxy tunnel rejected');
    }
  }

  void destroy() {
    final subscription = _subscription;
    _subscription = null;
    _subscriptionPaused = false;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
    socket.destroy();
  }
}
