# Changelog

## Unreleased

- Match XML protocol elements by resolved namespace URI and local name rather
  than literal `xmlns` attributes or prefix spelling. STARTTLS, SASL, resource
  binding, stream management, stream errors, and IQ handlers now accept legal
  default, prefixed, and inherited namespace declarations while rejecting
  unrelated namespaces.

## 0.1.3

- Fix stream parser leaving `XmlElement.namespaceUri` null on received stanzas.
  `XmlStreamParser` now enables `withNamespace` on `package:xml`'s event decoder
  so default and prefixed xmlns declarations resolve the same way as
  `XmlDocument.parse`.

## 0.1.2

- Fix unhandled `StreamSink is closed` when sending an IQ over a closed socket:
  `IqCaller` / `IqResponder` now take `FutureOr<void> Function(XmlElement)` and
  await async send callbacks (e.g. `XmppConnection.send`) instead of discarding
  the Future.

## 0.1.1

- Fix STARTTLS handshake failure caused by canceling the plaintext socket
  subscription before calling `SecureSocket.secure`.
- Add optional `onBadCertificate` to `TcpTransport.connect` for development
  servers with self-signed certificates.

## 0.1.0

Initial release. A lightweight TCP XMPP client.

- TCP transport with STARTTLS (required), opportunistic, and direct TLS modes.
- SASL PLAIN and SCRAM-SHA-1 authentication.
- Stream negotiation state machine and resource binding.
- Send/receive stanzas; IQ request/response caller and inbound IQ responder
  with automatic XEP-0199 ping replies.
- XEP-0198 Stream Management, including session resumption across reconnects
  (replays unacknowledged stanzas).
- DNS SRV resolution (`_xmpps-client`/`_xmpp-client`) with an injectable
  resolver and a plaintext fallback.
- Auto-reconnect with exponential backoff and permanent/transient failure
  classification.
- `see-other-host` stream-error redirects (bounded).
- Structured error hierarchy with an `isPermanent` classification and a
  client-level diagnostics stream.
