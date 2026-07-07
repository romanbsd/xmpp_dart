/// Error hierarchy for xmpp_dart.
///
/// Every failure carries [isPermanent]: whether reconnecting could ever fix it.
/// Auth failures, TLS failures and protocol violations are permanent; socket
/// drops and timeouts are transient.
library;

abstract class XmppException implements Exception {
  final String message;
  XmppException(this.message);

  /// True when retrying the connection cannot resolve this failure.
  bool get isPermanent;

  @override
  String toString() => '$runtimeType: $message';
}

/// Stream conditions (RFC 6120 §4.9.3) that a reconnect may recover from.
const _transientStreamConditions = {
  'system-shutdown',
  'reset',
  'resource-constraint',
  'connection-timeout',
  'see-other-host',
};

/// A `<stream:error>` from the server. Most are unrecoverable; a few
/// (e.g. `system-shutdown`) are transient — see [isPermanent].
class StreamErrorException extends XmppException {
  /// The defined condition child, e.g. `host-unknown`, `system-shutdown`.
  final String? condition;
  StreamErrorException(super.message, {this.condition});

  @override
  bool get isPermanent => !_transientStreamConditions.contains(condition);
}

/// Authentication failed (bad credentials, no shared mechanism). Permanent.
class SaslException extends XmppException {
  SaslException(super.message);
  @override
  bool get isPermanent => true;
}

/// A TLS/STARTTLS failure (not offered when required, handshake failure).
/// Permanent — a config or trust problem won't fix itself on retry.
class TlsException extends XmppException {
  TlsException(super.message);
  @override
  bool get isPermanent => true;
}

/// The peer violated the expected negotiation protocol (unexpected element,
/// missing data, malformed sequence). Permanent.
class NegotiationException extends XmppException {
  NegotiationException(super.message);
  @override
  bool get isPermanent => true;
}

/// A XEP-0198 protocol violation (non-monotonic or out-of-range ack counter,
/// malformed `<resumed/>`). Permanent.
class StreamManagementException extends XmppException {
  StreamManagementException(super.message);
  @override
  bool get isPermanent => true;
}

/// The incoming byte/XML stream could not be parsed. Permanent for the current
/// stream (the connection is torn down).
class XmlParseException extends XmppException {
  XmlParseException(super.message);
  @override
  bool get isPermanent => true;
}

/// Auto-reconnect gave up (a permanent failure, or [cause] was not retryable).
class ReconnectException extends XmppException {
  final Object cause;
  ReconnectException(this.cause) : super('reconnect aborted: $cause');
  @override
  bool get isPermanent => true;
}

/// Classifier used by [Reconnect]: permanent errors abort the retry loop;
/// everything else (timeouts, socket errors) is treated as transient.
bool isPermanentError(Object error) =>
    error is XmppException && error.isPermanent;
