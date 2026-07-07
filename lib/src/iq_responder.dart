import 'dart:async';

import 'package:xml/xml.dart';

import 'xml.dart';

const _nsStanza = 'urn:ietf:params:xml:ns:xmpp-stanzas';

/// Handles an inbound IQ `get`/`set`. Return the result payload child (or null
/// for an empty `<iq type="result"/>`); throw [IqError] to reply with a stanza
/// error.
typedef IqHandler = FutureOr<XmlElement?> Function(
    XmlElement iq, XmlElement child);

/// A stanza error to return from an [IqHandler].
class IqError implements Exception {
  /// Error type: 'modify' | 'cancel' | 'auth' | 'wait'.
  final String type;

  /// Defined condition, e.g. 'item-not-found', 'forbidden', 'not-allowed'.
  final String condition;

  IqError(this.condition, {this.type = 'cancel'});

  @override
  String toString() => 'IqError($type/$condition)';
}

/// Answers inbound IQ queries (RFC 6120 requires every `get`/`set` be replied
/// to). Routes by `(type, child xmlns, child name)`; unmatched queries get
/// `service-unavailable`, malformed ones `bad-request`, and a throwing handler
/// `internal-server-error`.
///
/// Decoupled from the connection like [IqCaller]: give it the incoming stanza
/// stream and a send callback.
class IqResponder {
  final void Function(XmlElement) _send;
  final _routes = <String, IqHandler>{};
  late final StreamSubscription<XmlElement> _sub;

  IqResponder(Stream<XmlElement> incoming, this._send) {
    _sub = incoming.listen(_onStanza);
  }

  /// Registers a handler for `iq type="get"` with a child in [ns] named [name].
  void get(String ns, String name, IqHandler handler) =>
      _routes['get|$ns|$name'] = handler;

  /// Registers a handler for `iq type="set"` with a child in [ns] named [name].
  void set(String ns, String name, IqHandler handler) =>
      _routes['set|$ns|$name'] = handler;

  Future<void> _onStanza(XmlElement el) async {
    if (el.name.local != 'iq') return;
    final type = el.getAttribute('type');
    if (type != 'get' && type != 'set') return; // results handled elsewhere

    final children = el.childElements.toList();
    if (children.length != 1) {
      _send(_error(el, null, 'modify', 'bad-request'));
      return;
    }
    final child = children.first;
    final key = '$type|${child.getAttribute('xmlns') ?? ''}|${child.name.local}';
    final handler = _routes[key];
    if (handler == null) {
      _send(_error(el, child, 'cancel', 'service-unavailable'));
      return;
    }

    try {
      final result = await handler(el, child);
      _send(_result(el, result));
    } on IqError catch (e) {
      _send(_error(el, child, e.type, e.condition));
    } catch (_) {
      _send(_error(el, child, 'cancel', 'internal-server-error'));
    }
  }

  XmlElement _reply(XmlElement query, String type, List<XmlElement> children) {
    final from = query.getAttribute('from');
    final id = query.getAttribute('id');
    return xml('iq', attrs: {
      'type': type,
      'to': ?from,
      'id': ?id,
    }, children: children);
  }

  XmlElement _result(XmlElement query, XmlElement? payload) =>
      _reply(query, 'result', [?payload]);

  XmlElement _error(
    XmlElement query,
    XmlElement? child,
    String type,
    String condition,
  ) =>
      _reply(query, 'error', [
        ?child?.copy(),
        xml('error', attrs: {'type': type}, children: [
          xml(condition, attrs: {'xmlns': _nsStanza}),
        ]),
      ]);

  Future<void> dispose() => _sub.cancel();
}
