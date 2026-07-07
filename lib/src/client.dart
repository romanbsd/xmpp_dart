import 'dart:async';

import 'package:xml/xml.dart';

import 'connection.dart';
import 'iq.dart';
import 'iq_responder.dart';
import 'jid.dart';
import 'reconnect.dart';
import 'stream_management.dart';
import 'transport.dart';

const _nsPing = 'urn:xmpp:ping';

/// Builds a [Transport] for a host/port. Injectable so tests (and custom
/// transports) can replace the default TCP socket.
typedef TransportFactory = Future<Transport> Function(
  String host,
  int port, {
  bool secure,
});

/// High-level XMPP client over TCP. Constructs the transport, runs the
/// connection state machine, and exposes stanza send/receive plus IQ calls.
///
/// With [streamManagement] and [autoReconnect] enabled it transparently resumes
/// the session (XEP-0198) after a drop, replaying unacknowledged stanzas.
///
/// ```dart
/// final client = XmppClient(
///   host: 'example.com', domain: 'example.com',
///   username: 'alice', password: 'secret', tls: TlsMode.starttls,
///   streamManagement: true, autoReconnect: true);
/// await client.connect();
/// client.stanzas.listen(handle);
/// await client.send(xml('presence'));
/// ```
class XmppClient {
  final String host;
  final String domain;
  final String username;
  final String password;
  final int? port;
  final TlsMode tls;
  final String? resource;
  final bool streamManagement;
  final bool autoReconnect;
  final Duration reconnectBase;
  final Duration reconnectMax;

  final TransportFactory _transportFactory;

  final _states = StreamController<XmppState>.broadcast();
  final _stanzas = StreamController<XmlElement>.broadcast();

  StreamManagement? _sm;
  XmppConnection? _conn;
  IqCaller? _iq;
  IqResponder? _iqResponder;
  final _iqGetHandlers = <(String, String, IqHandler)>[];
  final _iqSetHandlers = <(String, String, IqHandler)>[];
  StreamSubscription<XmppState>? _stateSub;
  StreamSubscription<XmlElement>? _stanzaSub;
  bool _closing = false;
  bool _reconnecting = false;

  XmppClient({
    required this.host,
    required this.domain,
    required this.username,
    required this.password,
    this.port,
    this.tls = TlsMode.starttls,
    this.resource,
    this.streamManagement = false,
    this.autoReconnect = false,
    this.reconnectBase = const Duration(seconds: 1),
    this.reconnectMax = const Duration(seconds: 60),
    TransportFactory? transportFactory,
  }) : _transportFactory = transportFactory ?? _defaultTransport;

  static Future<Transport> _defaultTransport(
    String host,
    int port, {
    bool secure = false,
  }) =>
      TcpTransport.connect(host, port, secure: secure);

  Stream<XmppState> get states => _states.stream;
  Stream<XmlElement> get stanzas => _stanzas.stream;

  /// The acknowledged-stanza stream (XEP-0198), when Stream Management is on.
  Stream<XmlElement> get acks =>
      _sm?.acks ?? const Stream<XmlElement>.empty();

  Jid? get jid => _conn?.jid;

  /// Opens the connection and completes once online. A failure here surfaces to
  /// the caller; only drops *after* a successful connect trigger auto-reconnect.
  Future<void> connect() async {
    if (streamManagement) _sm ??= StreamManagement();
    await _open();
  }

  Future<void> _open() async {
    final p = port ?? (tls == TlsMode.direct ? 5223 : 5222);
    final transport =
        await _transportFactory(host, p, secure: tls == TlsMode.direct);
    final conn = XmppConnection(
      transport: transport,
      domain: domain,
      username: username,
      password: password,
      tls: tls,
      resource: resource,
      sm: _sm,
    );
    _conn = conn;
    await _stateSub?.cancel();
    await _stanzaSub?.cancel();
    _stateSub = conn.states.listen(_onState);
    _stanzaSub = conn.stanzas.listen(_stanzas.add);
    await _iq?.dispose();
    _iq = IqCaller(conn.stanzas, conn.send);
    await _iqResponder?.dispose();
    _iqResponder = IqResponder(conn.stanzas, conn.send)
      ..get(_nsPing, 'ping', (_, _) => null); // XEP-0199 auto-reply
    for (final (ns, name, h) in _iqGetHandlers) {
      _iqResponder!.get(ns, name, h);
    }
    for (final (ns, name, h) in _iqSetHandlers) {
      _iqResponder!.set(ns, name, h);
    }
    await conn.connect();
  }

  void _onState(XmppState s) {
    _states.add(s);
    if (s == XmppState.disconnected &&
        autoReconnect &&
        !_closing &&
        !_reconnecting) {
      unawaited(_reconnect());
    }
  }

  Future<void> _reconnect() async {
    _reconnecting = true;
    try {
      await Reconnect(_open, base: reconnectBase, max: reconnectMax).run();
    } finally {
      _reconnecting = false;
    }
  }

  /// Sends a stanza.
  Future<void> send(XmlElement element) =>
      _conn?.send(element) ?? Future.error(StateError('not connected'));

  /// Sends an IQ and awaits its matching-`id` response.
  Future<XmlElement> iq(XmlElement element) =>
      _iq?.request(element) ?? Future.error(StateError('not connected'));

  /// Registers a handler for inbound `iq type="get"` with a child in [ns]
  /// named [name]. Persists across reconnects. Register before [connect] (or
  /// any time — it applies on the next connection too).
  void onIqGet(String ns, String name, IqHandler handler) {
    _iqGetHandlers.add((ns, name, handler));
    _iqResponder?.get(ns, name, handler);
  }

  /// Registers a handler for inbound `iq type="set"`. See [onIqGet].
  void onIqSet(String ns, String name, IqHandler handler) {
    _iqSetHandlers.add((ns, name, handler));
    _iqResponder?.set(ns, name, handler);
  }

  Future<void> close() async {
    _closing = true;
    await _conn?.close();
    await _iq?.dispose();
    await _iqResponder?.dispose();
    await _sm?.dispose();
    await _stateSub?.cancel();
    await _stanzaSub?.cancel();
    await _states.close();
    await _stanzas.close();
  }
}
