import 'dart:async';
import 'dart:io';

/// A bidirectional byte stream to the server. The network seam: the connection
/// state machine talks only to this interface, so tests can drive it with a
/// scripted fake instead of a real socket.
abstract class Transport {
  /// Raw bytes received from the peer. Stable across a TLS upgrade.
  Stream<List<int>> get incoming;

  /// Sends a string (UTF-8 encoded on the wire).
  void write(String data);

  /// Upgrades the current plaintext connection to TLS (STARTTLS).
  Future<void> upgradeTls(String host);

  /// Closes the underlying connection.
  Future<void> close();

  /// Completes when the connection is closed (by either side).
  Future<void> get done;
}

/// [Transport] over a real TCP socket, with optional TLS.
class TcpTransport implements Transport {
  TcpTransport._(this._socket, {this._onBadCertificate}) {
    _listen();
  }

  Socket _socket;
  StreamSubscription<List<int>>? _sub;
  final _incoming = StreamController<List<int>>();
  final _done = Completer<void>();
  final bool Function(X509Certificate certificate)? _onBadCertificate;

  /// Opens a socket. [secure] uses direct TLS (e.g. port 5223); otherwise a
  /// plaintext socket that may later be upgraded with [upgradeTls].
  ///
  /// [onBadCertificate] is forwarded to [SecureSocket.connect] / [upgradeTls]
  /// for self-signed or private-CA servers (development only).
  static Future<TcpTransport> connect(
    String host,
    int port, {
    bool secure = false,
    bool Function(X509Certificate certificate)? onBadCertificate,
  }) async {
    // ignore: close_sinks -- socket lifetime owned by [TcpTransport.close].
    final socket = secure
        ? await SecureSocket.connect(host, port, onBadCertificate: onBadCertificate)
        : await Socket.connect(host, port);
    return TcpTransport._(socket, onBadCertificate: onBadCertificate);
  }

  void _listen() {
    _sub = _socket.listen(
      _incoming.add,
      onError: _incoming.addError,
      onDone: () {
        if (!_done.isCompleted) _done.complete();
      },
      cancelOnError: false,
    );
  }

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  void write(String data) => _socket.write(data);

  @override
  Future<void> upgradeTls(String host) async {
    // SecureSocket.secure requires an active subscription on the plaintext
    // socket; canceling first causes the peer to drop the TLS handshake.
    final oldSub = _sub;
    _sub = null;
    _socket = await SecureSocket.secure(_socket, host: host, onBadCertificate: _onBadCertificate);
    await oldSub?.cancel();
    _listen();
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    await _socket.close();
    if (!_incoming.isClosed) await _incoming.close();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}
