import 'dart:async';
import 'dart:convert';

import 'package:xml/xml.dart';

import 'jid.dart';
import 'sasl.dart';
import 'transport.dart';
import 'xml.dart';

const _nsStream = 'http://etherx.jabber.org/streams';
const _nsClient = 'jabber:client';
const _nsTls = 'urn:ietf:params:xml:ns:xmpp-tls';
const _nsSasl = 'urn:ietf:params:xml:ns:xmpp-sasl';
const _nsBind = 'urn:ietf:params:xml:ns:xmpp-bind';

enum TlsMode { none, starttls, direct }

enum XmppState {
  offline,
  connecting,
  open,
  authenticating,
  bound,
  online,
  closing,
  disconnected,
}

class XmppException implements Exception {
  final String message;
  XmppException(this.message);
  @override
  String toString() => 'XmppException: $message';
}

/// A `<stream:error>` from the server. Stream errors are unrecoverable.
class StreamErrorException extends XmppException {
  StreamErrorException(super.message);
}

/// Drives one XMPP session over a [Transport]: opens the stream, negotiates
/// features (STARTTLS, SASL, resource binding) and reaches [XmppState.online].
class XmppConnection {
  final Transport transport;
  final String domain;
  final String username;
  final String password;
  final TlsMode tls;
  final String? resource;
  final Duration timeout;

  Jid? jid;

  final _states = StreamController<XmppState>.broadcast();
  final _stanzas = StreamController<XmlElement>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _parser = XmlStreamParser();
  final _inbox = _Inbox();

  XmppState _state = XmppState.offline;
  bool _online = false;

  /// True once [close] was called by the user (vs. an unexpected drop).
  /// Auto-reconnect logic uses this to decide whether to retry.
  bool userClosed = false;

  XmppConnection({
    required this.transport,
    required this.domain,
    required this.username,
    required this.password,
    this.tls = TlsMode.starttls,
    this.resource,
    this.timeout = const Duration(seconds: 10),
  });

  Stream<XmppState> get states => _states.stream;
  Stream<XmlElement> get stanzas => _stanzas.stream;
  Stream<Object> get errors => _errors.stream;
  XmppState get state => _state;

  /// Runs the full negotiation; resolves with the bound full [Jid] when online.
  Future<Jid> connect() async {
    transport.incoming.transform(utf8.decoder).listen(_parser.feed);
    unawaited(transport.done.then((_) => _onDisconnected()));
    _parser.stanzas.listen(_onElement);
    _setState(XmppState.connecting);
    await _negotiate();
    return jid!;
  }

  Future<void> send(XmlElement element) async =>
      transport.write(element.toXmlString());

  Future<void> close() async {
    userClosed = true;
    _setState(XmppState.closing);
    try {
      transport.write('</stream:stream>');
    } catch (_) {}
    await transport.close();
    _setState(XmppState.disconnected);
  }

  // --- negotiation ---

  Future<void> _negotiate() async {
    var secured = tls == TlsMode.direct;
    var authenticated = false;

    while (true) {
      _openStream();
      final features = await _read();

      if (!secured &&
          tls == TlsMode.starttls &&
          _child(features, 'starttls') != null) {
        transport.write(xml('starttls', attrs: {'xmlns': _nsTls}).toXmlString());
        final proceed = await _read();
        if (proceed.name.local != 'proceed') {
          throw XmppException('expected <proceed>, got <${proceed.name.local}>');
        }
        await transport.upgradeTls(domain);
        secured = true;
        continue;
      }

      if (!authenticated) {
        _setState(XmppState.authenticating);
        await _authenticate(features);
        authenticated = true;
        continue;
      }

      _setState(XmppState.bound);
      await _bindResource();
      _online = true;
      _setState(XmppState.online);
      return;
    }
  }

  void _openStream() {
    _parser.reset();
    transport.write("<?xml version='1.0'?>"
        "<stream:stream xmlns='$_nsClient' "
        "xmlns:stream='$_nsStream' version='1.0' to='$domain'>");
    _setState(XmppState.open);
  }

  Future<void> _authenticate(XmlElement features) async {
    final offered = _child(features, 'mechanisms')
            ?.childElements
            .where((e) => e.name.local == 'mechanism')
            .map((e) => e.innerText)
            .toList() ??
        const <String>[];

    final mech = selectMechanism(offered, username, password);
    if (mech == null) {
      throw SaslException('no supported SASL mechanism in $offered');
    }

    final init = mech.initial();
    transport.write(xml('auth', attrs: {
      'xmlns': _nsSasl,
      'mechanism': mech.name,
    }, text: init == null ? null : _b64(init)).toXmlString());

    while (true) {
      final el = await _read();
      switch (el.name.local) {
        case 'challenge':
          final resp = mech.response(_unb64(el.innerText));
          transport.write(
              xml('response', attrs: {'xmlns': _nsSasl}, text: _b64(resp))
                  .toXmlString());
        case 'success':
          final data = el.innerText.trim();
          mech.onSuccess(data.isEmpty ? null : _unb64(data));
          return;
        case 'failure':
          throw SaslException(el.toXmlString());
        default:
          throw SaslException('unexpected SASL element <${el.name.local}>');
      }
    }
  }

  Future<void> _bindResource() async {
    final bind = xml('bind', attrs: {'xmlns': _nsBind}, children: [
      if (resource != null) xml('resource', text: resource!),
    ]);
    transport.write(
        xml('iq', attrs: {'type': 'set', 'id': 'bind'}, children: [bind])
            .toXmlString());

    final res = await _read();
    if (res.getAttribute('type') == 'error') {
      throw XmppException('resource binding failed: ${res.toXmlString()}');
    }
    final jidText = _child(_child(res, 'bind') ?? res, 'jid')?.innerText;
    if (jidText == null) {
      throw XmppException('bind result missing <jid>: ${res.toXmlString()}');
    }
    jid = Jid.parse(jidText);
  }

  // --- element routing ---

  void _onElement(XmlElement el) {
    if (el.name.qualified == 'stream:error') {
      final err = StreamErrorException(el.toXmlString());
      if (_online) {
        _errors.add(err);
        unawaited(close());
      } else {
        _inbox.fail(err);
      }
      return;
    }
    if (_online) {
      _stanzas.add(el);
    } else {
      _inbox.add(el);
    }
  }

  Future<XmlElement> _read() => _inbox.next(timeout);

  void _onDisconnected() {
    _online = false;
    if (_state != XmppState.disconnected) {
      _setState(XmppState.disconnected);
    }
  }

  void _setState(XmppState s) {
    if (_state == s) return;
    _state = s;
    _states.add(s);
  }

  static String _b64(String s) => base64.encode(utf8.encode(s));
  static String _unb64(String s) => utf8.decode(base64.decode(s));

  static XmlElement? _child(XmlElement parent, String local) {
    for (final e in parent.childElements) {
      if (e.name.local == local) return e;
    }
    return null;
  }
}

/// A one-slot async mailbox: negotiation steps `await next()` for the next
/// element; incoming elements either satisfy a waiter or queue up.
class _Inbox {
  final _queue = <XmlElement>[];
  Completer<XmlElement>? _waiter;
  Object? _error;

  void add(XmlElement e) {
    final w = _waiter;
    if (w != null) {
      _waiter = null;
      w.complete(e);
    } else {
      _queue.add(e);
    }
  }

  void fail(Object err) {
    final w = _waiter;
    if (w != null) {
      _waiter = null;
      w.completeError(err);
    } else {
      _error = err;
    }
  }

  Future<XmlElement> next(Duration timeout) {
    if (_queue.isNotEmpty) return Future.value(_queue.removeAt(0));
    if (_error != null) {
      final e = _error!;
      _error = null;
      return Future.error(e);
    }
    final c = Completer<XmlElement>();
    _waiter = c;
    return c.future.timeout(timeout);
  }
}
