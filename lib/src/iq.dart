import 'dart:async';

import 'package:xml/xml.dart';

class IqException implements Exception {
  final String message;
  IqException(this.message);
  @override
  String toString() => 'IqException: $message';
}

/// Sends IQ stanzas and resolves each with its matching-`id` response.
///
/// Decoupled from the connection: give it the incoming stanza stream and a send
/// callback, so it can be tested without a socket.
class IqCaller {
  final void Function(XmlElement) _send;
  final Duration timeout;
  final _pending = <String, Completer<XmlElement>>{};
  late final StreamSubscription<XmlElement> _sub;
  int _seq = 0;

  IqCaller(
    Stream<XmlElement> incoming,
    this._send, {
    this.timeout = const Duration(seconds: 30),
  }) {
    _sub = incoming.listen(_onStanza);
  }

  /// Sends [iq] (assigning an `id` if absent) and returns its response. A
  /// `type="error"` response completes with [IqException]; no response within
  /// [timeout] completes with [TimeoutException].
  Future<XmlElement> request(XmlElement iq) {
    var id = iq.getAttribute('id');
    if (id == null) {
      id = 'iq-${_seq++}';
      iq.setAttribute('id', id);
    }
    final completer = Completer<XmlElement>();
    _pending[id] = completer;
    _send(iq);
    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw TimeoutException('IQ $id timed out');
    });
  }

  void _onStanza(XmlElement el) {
    if (el.name.local != 'iq') return;
    final id = el.getAttribute('id');
    if (id == null) return;
    final completer = _pending.remove(id);
    if (completer == null) return;
    if (el.getAttribute('type') == 'error') {
      completer.completeError(IqException(el.toXmlString()));
    } else {
      completer.complete(el);
    }
  }

  Future<void> dispose() => _sub.cancel();
}
