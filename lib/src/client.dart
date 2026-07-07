import 'dart:async';

import 'package:xml/xml.dart';

import 'connection.dart';
import 'iq.dart';
import 'jid.dart';
import 'transport.dart';

/// High-level XMPP client over TCP. Constructs the transport, runs the
/// connection state machine, and exposes stanza send/receive plus IQ calls.
///
/// ```dart
/// final client = XmppClient(
///   host: 'example.com', domain: 'example.com',
///   username: 'alice', password: 'secret', tls: TlsMode.starttls);
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

  final _states = StreamController<XmppState>.broadcast();
  final _stanzas = StreamController<XmlElement>.broadcast();

  XmppConnection? _conn;
  IqCaller? _iq;

  XmppClient({
    required this.host,
    required this.domain,
    required this.username,
    required this.password,
    this.port,
    this.tls = TlsMode.starttls,
    this.resource,
  });

  Stream<XmppState> get states => _states.stream;
  Stream<XmlElement> get stanzas => _stanzas.stream;
  Jid? get jid => _conn?.jid;

  /// Opens the connection and completes once online.
  Future<void> connect() async {
    final p = port ?? (tls == TlsMode.direct ? 5223 : 5222);
    final transport =
        await TcpTransport.connect(host, p, secure: tls == TlsMode.direct);
    final conn = XmppConnection(
      transport: transport,
      domain: domain,
      username: username,
      password: password,
      tls: tls,
      resource: resource,
    );
    _conn = conn;
    conn.states.listen(_states.add);
    conn.stanzas.listen(_stanzas.add);
    _iq = IqCaller(conn.stanzas, conn.send);
    await conn.connect();
  }

  /// Sends a stanza.
  Future<void> send(XmlElement element) =>
      _conn?.send(element) ?? Future.error(StateError('not connected'));

  /// Sends an IQ and awaits its matching-`id` response.
  Future<XmlElement> iq(XmlElement element) =>
      _iq?.request(element) ?? Future.error(StateError('not connected'));

  Future<void> close() async {
    await _conn?.close();
    await _iq?.dispose();
    await _states.close();
    await _stanzas.close();
  }
}
