import 'dart:async';
import 'dart:convert';

import 'package:xml/xml.dart';

import 'errors.dart';
import 'jid.dart';
import 'sasl.dart';
import 'stream_management.dart';
import 'transport.dart';
import 'xml.dart';

const _nsStream = 'http://etherx.jabber.org/streams';
const _nsClient = 'jabber:client';
const _nsTls = 'urn:ietf:params:xml:ns:xmpp-tls';
const _nsSasl = 'urn:ietf:params:xml:ns:xmpp-sasl';
const _nsBind = 'urn:ietf:params:xml:ns:xmpp-bind';

/// How to secure the TCP connection.
enum TlsMode {
  /// No encryption. Only for trusted/local testing.
  none,

  /// Require STARTTLS on the plaintext port; fail if the server does not offer
  /// it. This is the safe default for port 5222.
  starttls,

  /// Use STARTTLS if offered, otherwise continue in plaintext. Weaker — only
  /// when you knowingly accept unencrypted fallback.
  opportunistic,

  /// Direct TLS from the first byte (e.g. port 5223).
  direct,
}

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

/// Drives one XMPP session over a [Transport]: opens the stream, negotiates
/// features (STARTTLS, SASL, resource binding, XEP-0198) and reaches
/// [XmppState.online]. Negotiation failures surface as typed [XmppException]s
/// and tear the connection down deterministically.
class XmppConnection {
  final Transport transport;
  final String domain;
  final String username;
  final String password;
  final TlsMode tls;
  final String? resource;
  final Duration timeout;

  /// XEP-0198 state, shared across reconnects for session resumption. Null
  /// disables Stream Management.
  final StreamManagement? sm;

  /// How often to send a liveness `<r/>` once SM is enabled. Null disables it.
  final Duration? ackInterval;

  /// If a liveness `<r/>` goes unanswered this long, the connection is dropped.
  final Duration ackTimeout;

  Jid? jid;

  final _states = StreamController<XmppState>.broadcast();
  final _stanzas = StreamController<XmlElement>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _parser = XmlStreamParser();
  final _inbox = _Inbox();

  StreamSubscription<String>? _byteSub;
  StreamSubscription<XmlElement>? _stanzaSub;
  StreamSubscription<Object>? _parserErrSub;

  XmppState _state = XmppState.offline;
  bool _online = false;
  Timer? _ackTimer;
  Timer? _ackTimeoutTimer;

  /// True once [close] was called by the user (vs. an unexpected drop).
  bool userClosed = false;

  XmppConnection({
    required this.transport,
    required this.domain,
    required this.username,
    required this.password,
    this.tls = TlsMode.starttls,
    this.resource,
    this.timeout = const Duration(seconds: 10),
    this.sm,
    this.ackInterval = const Duration(seconds: 30),
    this.ackTimeout = const Duration(seconds: 20),
  });

  Stream<XmppState> get states => _states.stream;
  Stream<XmlElement> get stanzas => _stanzas.stream;

  /// Errors that occur after the connection is live (stream errors, SM
  /// violations, parse failures). Negotiation errors are thrown from [connect].
  Stream<Object> get errors => _errors.stream;
  XmppState get state => _state;

  /// Runs the full negotiation; resolves with the bound full [Jid] when online.
  /// On failure the transport, parser and listeners are torn down before the
  /// error is rethrown.
  Future<Jid> connect() async {
    _byteSub = transport.incoming
        .transform(utf8.decoder)
        .listen(_parser.feed, onError: _onStreamError);
    _stanzaSub = _parser.stanzas.listen(_onElement);
    _parserErrSub = _parser.errors.listen(_onStreamError);
    unawaited(transport.done.then((_) => _onDisconnected()));
    _setState(XmppState.connecting);
    try {
      await _negotiate();
    } catch (_) {
      await _teardown();
      _setState(XmppState.disconnected);
      rethrow;
    }
    return jid!;
  }

  Future<void> send(XmlElement element) async {
    transport.write(element.toXmlString());
    if (sm != null && sm!.enabled && StreamManagement.isStanza(element)) {
      sm!.trackOutbound(element);
      // Prompt the server to acknowledge what it has received so far.
      transport.write(sm!.requestElement().toXmlString());
    }
  }

  Future<void> close() async {
    userClosed = true;
    _cancelAckTimers();
    _setState(XmppState.closing);
    try {
      if (sm != null && sm!.enabled) {
        transport.write(sm!.ackElement().toXmlString());
      }
      transport.write('</stream:stream>');
    } catch (_) {}
    sm?.onDisconnect();
    await _teardown();
    _setState(XmppState.disconnected);
  }

  /// Cancels listeners/timers, closes the parser and transport. Idempotent.
  Future<void> _teardown() async {
    _cancelAckTimers();
    await _byteSub?.cancel();
    await _stanzaSub?.cancel();
    await _parserErrSub?.cancel();
    _byteSub = null;
    _stanzaSub = null;
    _parserErrSub = null;
    _parser.close();
    try {
      await transport.close();
    } catch (_) {}
  }

  // --- negotiation ---

  Future<void> _negotiate() async {
    var secured = tls == TlsMode.direct;
    var authenticated = false;

    while (true) {
      _openStream();
      final features = await _read();

      if (!secured &&
          (tls == TlsMode.starttls || tls == TlsMode.opportunistic)) {
        if (_child(features, 'starttls', ns: _nsTls) != null) {
          await _startTls();
          secured = true;
          continue;
        }
        if (tls == TlsMode.starttls) {
          throw TlsException(
              'STARTTLS required but the server did not offer it');
        }
        // opportunistic: fall through, unencrypted.
      }

      if (!authenticated) {
        _setState(XmppState.authenticating);
        await _authenticate(features);
        authenticated = true;
        continue;
      }

      // Resume a previous SM session if we have one.
      if (sm != null && sm!.resumable && await _tryResume()) {
        _goOnline();
        return;
      }

      _setState(XmppState.bound);
      await _bindResource();
      await _tryEnableSm(features);
      _goOnline();
      return;
    }
  }

  void _goOnline() {
    _online = true;
    _setState(XmppState.online);
    _scheduleAckRequest();
  }

  Future<void> _startTls() async {
    transport.write(xml('starttls', attrs: {'xmlns': _nsTls}).toXmlString());
    final proceed = await _read();
    if (proceed.name.local != 'proceed' ||
        proceed.getAttribute('xmlns') != _nsTls) {
      throw NegotiationException(
          'expected <proceed/>, got <${proceed.name.local}>');
    }
    try {
      await transport.upgradeTls(domain);
    } catch (e) {
      throw TlsException('TLS handshake failed: $e');
    }
  }

  /// Sends `<resume>` and handles the reply. Returns true if the session was
  /// resumed (bind is then skipped); false if the server rejected it.
  Future<bool> _tryResume() async {
    transport.write(sm!.resumeElement().toXmlString());
    final reply = await _read();
    if (reply.getAttribute('xmlns') != StreamManagement.ns) {
      throw NegotiationException(
          'unexpected resume reply <${reply.name.local}>');
    }
    switch (reply.name.local) {
      case 'resumed':
        for (final stanza in sm!.onResumed(reply)) {
          transport.write(stanza.toXmlString());
        }
        jid = sm!.jid;
        return true;
      case 'failed':
        sm!.onFailedResume();
        return false;
      default:
        throw NegotiationException(
            'unexpected resume reply <${reply.name.local}>');
    }
  }

  /// After binding, enables SM if the server advertised it. Failure is
  /// non-fatal — the session simply runs without SM.
  Future<void> _tryEnableSm(XmlElement features) async {
    if (sm == null || _child(features, 'sm', ns: StreamManagement.ns) == null) {
      return;
    }
    transport.write(sm!.enableElement().toXmlString());
    final reply = await _read();
    if (reply.getAttribute('xmlns') == StreamManagement.ns &&
        reply.name.local == 'enabled') {
      sm!.onEnabled(reply);
      sm!.jid = jid;
    }
    // <failed/> or anything else: leave SM disabled.
  }

  void _openStream() {
    _parser.reset();
    transport.write("<?xml version='1.0'?>"
        "<stream:stream xmlns='$_nsClient' "
        "xmlns:stream='$_nsStream' version='1.0' to='$domain'>");
    _setState(XmppState.open);
  }

  Future<void> _authenticate(XmlElement features) async {
    final offered = _child(features, 'mechanisms', ns: _nsSasl)
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
      if (el.getAttribute('xmlns') != _nsSasl) {
        throw NegotiationException(
            'unexpected element during SASL: <${el.name.local}>');
      }
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
          throw NegotiationException('unexpected SASL <${el.name.local}>');
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
      throw NegotiationException('resource binding failed: ${res.toXmlString()}');
    }
    final jidText = _child(_child(res, 'bind', ns: _nsBind) ?? res, 'jid')
        ?.innerText;
    if (jidText == null) {
      throw NegotiationException('bind result missing <jid>: ${res.toXmlString()}');
    }
    jid = Jid.parse(jidText);
  }

  // --- element routing ---

  void _onElement(XmlElement el) {
    if (el.name.qualified == 'stream:error') {
      final condition = el.childElements.isEmpty
          ? null
          : el.childElements.first.name.local;
      final err = StreamErrorException(el.toXmlString(), condition: condition);
      if (_online) {
        _errors.add(err);
        unawaited(close());
      } else {
        _inbox.fail(err);
      }
      return;
    }

    // XEP-0198 flow control (only meaningful once online with SM enabled).
    if (_online &&
        sm != null &&
        sm!.enabled &&
        el.getAttribute('xmlns') == StreamManagement.ns) {
      switch (el.name.local) {
        case 'r':
          transport.write(sm!.ackElement().toXmlString());
          return;
        case 'a':
          final h = int.tryParse(el.getAttribute('h') ?? '');
          if (h != null) {
            try {
              sm!.handleAck(h);
            } on StreamManagementException catch (e) {
              _errors.add(e);
              unawaited(close());
              return;
            }
          }
          _ackTimeoutTimer?.cancel();
          _scheduleAckRequest();
          return;
      }
    }

    if (_online) {
      sm?.countInbound(el);
      _stanzas.add(el);
    } else {
      _inbox.add(el);
    }
  }

  /// Routes a byte/parse-level stream error to the negotiation waiter (before
  /// online) or the [errors] stream + teardown (after online).
  void _onStreamError(Object error, [StackTrace? stackTrace]) {
    final err =
        error is XmppException ? error : XmlParseException('$error');
    if (_online) {
      _errors.add(err);
      unawaited(close());
    } else {
      _inbox.fail(err);
    }
  }

  Future<XmlElement> _read() => _inbox.next(timeout);

  // Periodically send <r/> and drop the connection if it goes unanswered, so
  // the reconnect layer can resume the session.
  void _scheduleAckRequest() {
    if (sm == null || !sm!.enabled || ackInterval == null) return;
    _ackTimer?.cancel();
    _ackTimer = Timer(ackInterval!, () {
      transport.write(sm!.requestElement().toXmlString());
      _ackTimeoutTimer?.cancel();
      _ackTimeoutTimer = Timer(ackTimeout, () => unawaited(transport.close()));
    });
  }

  void _cancelAckTimers() {
    _ackTimer?.cancel();
    _ackTimeoutTimer?.cancel();
  }

  void _onDisconnected() {
    _online = false;
    _cancelAckTimers();
    sm?.onDisconnect();
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

  static XmlElement? _child(XmlElement parent, String local, {String? ns}) {
    for (final e in parent.childElements) {
      if (e.name.local == local &&
          (ns == null || e.getAttribute('xmlns') == ns)) {
        return e;
      }
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
