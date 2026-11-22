import 'dart:async';
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
  NetworkSocket(this.socket) : _input = StreamIterator(socket);

  final Socket socket;
  final StreamIterator<Uint8List> _input;
  Uint8List _pending = Uint8List(0);
  int _offset = 0;

  Future<List<int>> readBytes(int count) async {
    final result = <int>[];
    while (result.length < count) {
      if (_offset == _pending.length) {
        if (!await _input.moveNext()) {
          throw const SocketException('Connection closed during handshake');
        }
        _pending = _input.current;
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
        if (!await _input.moveNext()) {
          throw const SocketException('Connection closed during handshake');
        }
        _pending = _input.current;
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

  Stream<List<int>> get remaining async* {
    if (_offset < _pending.length) {
      yield _pending.sublist(_offset);
      _offset = _pending.length;
    }
    while (await _input.moveNext()) {
      yield _input.current;
    }
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

  void destroy() => socket.destroy();
}
