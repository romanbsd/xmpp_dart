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
///
/// [send] may be sync or async (`FutureOr`). Callers that pass
/// `XmppConnection.send` (a `Future<void> Function`) must have that Future
/// awaited — otherwise a closed-socket write becomes an unhandled async error
/// and the IQ future hangs until timeout.
class IqCaller {
  final FutureOr<void> Function(XmlElement) _send;
  final Duration timeout;
  final _pending = <String, Completer<XmlElement>>{};
  late final StreamSubscription<XmlElement> _sub;
  int _seq = 0;
  bool _disposed = false;

  IqCaller(Stream<XmlElement> incoming, this._send, {this.timeout = const Duration(seconds: 30)}) {
    _sub = incoming.listen(_onStanza);
  }

  /// Sends [iq] (assigning an `id` if absent) and returns its response. A
  /// `type="error"` response completes with [IqException]; no response within
  /// [timeout] completes with [TimeoutException]. A send failure, a duplicate
  /// in-flight `id`, or [dispose] completes the future with an error rather
  /// than hanging.
  Future<XmlElement> request(XmlElement iq) async {
    if (_disposed) {
      throw StateError('IqCaller disposed');
    }
    var id = iq.getAttribute('id');
    if (id == null) {
      id = 'iq-${_seq++}';
      iq.setAttribute('id', id);
    } else if (_pending.containsKey(id)) {
      throw IqException('duplicate in-flight IQ id "$id"');
    }

    final completer = Completer<XmlElement>();
    _pending[id] = completer;
    try {
      await _send(iq);
    } catch (e, st) {
      _pending.remove(id);
      Error.throwWithStackTrace(e, st);
    }
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('IQ $id timed out');
      },
    );
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

  /// Cancels the subscription and fails any still-pending requests.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('IqCaller disposed'));
      }
    }
    _pending.clear();
    await _sub.cancel();
  }
}
