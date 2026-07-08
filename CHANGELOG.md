# Changelog

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
