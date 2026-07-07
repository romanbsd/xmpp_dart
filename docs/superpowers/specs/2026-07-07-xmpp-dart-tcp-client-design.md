# xmpp_dart — Lightweight TCP XMPP Client (Design)

Date: 2026-07-07
Status: Approved

## Goal

A lightweight Dart port of [xmpp.js](https://github.com/xmppjs/xmpp.js) covering
the TCP client path only. Built test-first. No WebSocket transport.

## Scope

**In:**

- TCP connection with TLS: STARTTLS upgrade *and* direct-TLS (port 5223).
- SASL authentication: `PLAIN` and `SCRAM-SHA-1`.
- Stream negotiation: open stream, read stream features, STARTTLS, SASL,
  stream restart, resource binding, reach `online`.
- Send/receive stanzas.
- IQ request/response helper (send get/set, await response by id).
- Auto-reconnect with exponential backoff.

**Out (explicitly skipped for the lightweight port):**

- WebSocket transport.
- Stream management (XEP-0198).
- Plugin/middleware architecture (xmpp.js's generic middleware, stream-features
  registry, iq callee router). The negotiation flow is collapsed into a linear
  state machine instead.
- Roster / presence convenience helpers (user builds those stanzas manually).
- SASL2 / BIND2 / FAST, ANONYMOUS, SCRAM-SHA-256.

## Public API (idiomatic Dart)

```dart
final client = XmppClient(
  host: 'example.com',
  domain: 'example.com',
  username: 'alice',
  password: 'secret',
  tls: TlsMode.starttls,   // TlsMode.direct | TlsMode.none
  port: 5222,              // optional; defaults per tls mode
);

await client.connect();               // resolves when online; throws on failure
client.states.listen(print);          // Stream<XmppState>
client.stanzas.listen(handleStanza);  // Stream<XmlElement> (incoming stanzas)

final result = await client.iq(
  xml('iq', attrs: {'type': 'get', 'to': 'example.com'}, children: [
    xml('query', attrs: {'xmlns': 'jabber:iq:roster'}),
  ]),
);

await client.send(xml('message',
  attrs: {'to': 'bob@example.com', 'type': 'chat'},
  children: [xml('body', text: 'hi')]));

await client.close();
```

`client.jid` holds the bound full JID once online.

## Architecture

All internal units live under `lib/src/`. Public surface re-exported from
`lib/xmpp_dart.dart`.

### `jid.dart`

`Jid` value type. Parses `local@domain/resource` (all parts optional except
domain). Provides `bare()`, `resource`, `domain`, `local`, `==`/`hashCode`,
`toString()`.

### `xml/xml_stream.dart`

Streaming XML layer built on `package:xml`'s `parseEvents`.

- `XmlStreamParser` consumes decoded string chunks via `feed(String)`.
- Emits:
  - `Stream<XmlElement> streamOpen` — fires once when the `<stream:stream ...>`
    opening tag is seen. The opening tag is consumed *without* its close (XMPP
    keeps the stream element open for the session lifetime). Carries its
    attributes.
  - `Stream<XmlElement> stanzas` — each top-level (depth-1) element is emitted
    as a complete `XmlElement` subtree once its end tag arrives. Elements split
    across chunk boundaries are reassembled.
  - `Stream<void> streamClose` — the `</stream:stream>` end tag.
- `reset()` discards parser state for a stream restart (post-STARTTLS,
  post-SASL).
- Depth tracking: the stream-open start event is depth 0; stanzas complete at
  depth returning to 1. A running builder accumulates events between depth-1
  boundaries into subtrees (`package:xml` `XmlNodeDecoder` / event-to-node
  assembly).

Also a small build helper:
`xml(String name, {Map<String,String>? attrs, List<XmlElement>? children, String? text}) -> XmlElement`.

### `transport.dart`

Abstract `Transport` — the network seam that makes the state machine testable
without sockets.

```dart
abstract class Transport {
  Stream<List<int>> get incoming;   // raw bytes from peer
  void write(String data);
  Future<void> upgradeTls(String host);  // STARTTLS: wrap current socket
  Future<void> close();
  Future<void> get done;            // completes when socket closes
}
```

- `TcpTransport` — `dart:io`. `TlsMode.none`/`starttls` open a plain `Socket`;
  `starttls` later calls `SecureSocket.secure(socket)`. `TlsMode.direct` opens
  with `SecureSocket.connect` (default port 5223).
- `FakeTransport` (test-only) — backed by `StreamController`s. Test scripts push
  server XML into `incoming`; the client's `write`s are captured for assertions.

### `sasl/`

- `sasl_mechanism.dart` — `abstract class SaslMechanism { String get name;
  String? initial(); String response(String challenge); }`.
- `plain.dart` — `PlainMechanism`: `initial()` returns
  base64(`\0username\0password`), no challenge step.
- `scram_sha1.dart` — `ScramSha1Mechanism`: client-nonce, parse server-first,
  compute salted password (PBKDF2-HMAC-SHA1), client/server proof per RFC 5802.
  Uses `crypto` package (`Hmac(sha1)`, `sha1`).

Mechanism selection: prefer `SCRAM-SHA-1`, else `PLAIN`, chosen from the server's
advertised `<mechanisms>`.

### `connection.dart`

`XmppConnection` — the linear negotiation state machine. Owns a `Transport`, an
`XmlStreamParser`, and a UTF-8 decoder over incoming bytes.

`connect()` sequence:

1. `connecting` → transport connects (or direct-TLS handshake).
2. `open` → write stream header `<?xml…?><stream:stream to=domain …>`; await
   `<stream:features>`.
3. If `<starttls>` present and TLS not yet active and mode is `starttls`: send
   `<starttls/>`, await `<proceed/>`, `transport.upgradeTls()`, `reset()` parser,
   restart at step 2.
4. `authenticating` → select mechanism, run SASL exchange
   (`<auth>`/`<challenge>`/`<response>`/`<success>`|`<failure>`). On `<failure>`
   throw `SaslException`. On success, `reset()`, restart at step 2.
5. `bound` → resource-bind IQ set (`urn:ietf:params:xml:ns:xmpp-bind`), read
   assigned full JID.
6. `online` → resolve `connect()`; route subsequent stanzas to `stanzas`.

Exposes: `Stream<XmppState> states`, `Stream<XmlElement> stanzas`,
`Future<void> send(XmlElement)`, `Jid? jid`, `close()`.

Error handling:

- `<stream:error>` → emit `StreamErrorException` on an error path, then close
  (stream errors are unrecoverable per RFC 6120).
- SASL `<failure>` → `SaslException`.
- Parser not-well-formed → close with bad-format.
- Per-step timeout (default 2 s, configurable) → `TimeoutException`, close.

`XmppState` enum: `offline, connecting, open, authenticating, bound, online,
closing, disconnected`.

### `iq.dart`

`IqCaller` wraps a connection. `request(XmlElement iq) -> Future<XmlElement>`:
assigns a unique `id`, sends, completes when a matching-`id` `iq` of type
`result`/`error` arrives, with timeout. Errors complete with `IqException`.

### `reconnect.dart`

`ReconnectingClient` wraps `XmppConnection`. On unexpected `disconnected` (not a
user `close()`), retries `connect()` with exponential backoff
(base/max/jitter configurable). Stops on explicit close.

### `client.dart`

`XmppClient` — public entry. Constructs the transport (per `TlsMode`), the
connection, the IQ caller, and (optionally) reconnect wrapper; forwards
`connect/close/send/iq/stanzas/states/jid`.

## Data Flow

```
socket bytes ─▶ utf8 decode ─▶ XmlStreamParser.feed
                                   │
              streamOpen ─────────┤
              stanzas ────────────┼─▶ connection router
              streamClose ────────┘        │
                                    negotiation (states) ─▶ online
                                    post-online stanza ─▶ stanzas stream
                                                      └─▶ IqCaller (id match)
outgoing: send(XmlElement) ─▶ element.toXmlString ─▶ transport.write
```

## Testing (TDD)

Every unit gets tests before implementation. `FakeTransport` drives the whole
negotiation deterministically with no network.

- **jid_test** — parse full/bare/domain-only, resource with `/`, `bare()`,
  equality.
- **xml_stream_test** — single stanza; stanza split across two `feed` chunks;
  multiple stanzas in one chunk; stream-open header attrs; `reset()` mid-stream;
  nested children preserved.
- **sasl_plain_test** — known base64 vector.
- **sasl_scram_sha1_test** — RFC 5802 §5 vector (`user` / `pencil`,
  fixed client nonce) → assert client-final proof and server-signature verify.
- **connection_test** — full happy path (features → starttls → restart →
  scram → restart → bind → online) via scripted `FakeTransport`, asserting the
  bytes the client writes at each step and the `states` sequence; plus
  auth-failure path (`<failure>` → `SaslException`) and `<stream:error>` path.
- **iq_test** — request resolves on matching id; ignores other ids; timeout;
  error-type response → `IqException`.
- **reconnect_test** — simulated drop triggers a reconnect attempt; backoff
  grows; explicit close stops retries.
- **integration_test** — real server (env-gated: `XMPP_HOST` etc.), skipped by
  default.

## Dependencies

- `package:xml` (already present) — element model + streaming events.
- `crypto` (new) — SHA1 / HMAC-SHA1 for SCRAM.
- `dart:io`, `dart:convert` — sockets, base64, utf8.
- `package:test`, `lints` (dev, present).

## Non-Goals / Future

WebSocket, stream management, SCRAM-SHA-256, SASL2/BIND2/FAST, roster/presence
helpers, service discovery / SRV resolution. Left as follow-up; the transport
and mechanism abstractions leave room for them.
