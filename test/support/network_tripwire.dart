import 'dart:io';

/// Records this isolate's attempts to reach the network through the calls
/// Dart lets a test intercept, and refuses them (#7 criterion 2). Armed, it
/// replaces the process-wide [HttpOverrides] and [IOOverrides], so these land
/// in [attempts] and fail with a [SocketException] rather than going out:
///
///   * an `HttpClient` created, which HTTPS and `WebSocket.connect` are both
///     built on;
///   * `Socket.connect` and `Socket.startConnect`;
///   * `ServerSocket.bind`.
///
/// What it cannot see, because Dart has no override for them: a direct
/// `SecureSocket`, `RawSocket`, `RawServerSocket`, `SecureServerSocket` or
/// `RawDatagramSocket`, and a DNS lookup. Nor can it see another isolate (the
/// core runs in its own) or the platform side of a plugin. Two things cover
/// the gap: the import-boundary test holds `lib/` and the core to no
/// `dart:io` at all, and on a device integration_test/offline_results.sh
/// turns airplane mode on, so anything that bypasses this still fails.
class NetworkTripwire {
  final attempts = <String>[];

  HttpOverrides? _http;
  IOOverrides? _io;
  bool _armed = false;

  void arm() {
    if (_armed) throw StateError('already armed');
    _http = HttpOverrides.current;
    _io = IOOverrides.current;
    HttpOverrides.global = _Http(this);
    IOOverrides.global = _Io(this);
    _armed = true;
  }

  void disarm() {
    if (!_armed) return;
    HttpOverrides.global = _http;
    IOOverrides.global = _io;
    _armed = false;
  }

  Never _trip(String what) {
    attempts.add(what);
    throw SocketException('network tripwire: $what');
  }
}

class _Http extends HttpOverrides {
  _Http(this._wire);
  final NetworkTripwire _wire;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _wire._trip('HttpClient created');
}

final class _Io extends IOOverrides {
  _Io(this._wire);
  final NetworkTripwire _wire;

  @override
  Future<Socket> socketConnect(dynamic host, int port,
          {dynamic sourceAddress, int sourcePort = 0, Duration? timeout}) =>
      Future.sync(() => _wire._trip('socket to $host:$port'));

  @override
  Future<ConnectionTask<Socket>> socketStartConnect(dynamic host, int port,
          {dynamic sourceAddress, int sourcePort = 0}) =>
      Future.sync(() => _wire._trip('socket to $host:$port'));

  @override
  Future<ServerSocket> serverSocketBind(dynamic address, int port,
          {int backlog = 0, bool v6Only = false, bool shared = false}) =>
      Future.sync(() => _wire._trip('server socket on $address:$port'));
}
