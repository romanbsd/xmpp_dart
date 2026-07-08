# xmpp_dart

A lightweight Dart port of [xmpp.js](https://github.com/xmppjs/xmpp.js) — TCP
client only. Connects, secures (STARTTLS or direct TLS), authenticates
(SASL PLAIN / SCRAM-SHA-1), binds a resource, and lets you send/receive stanzas.

Resolves servers via DNS SRV (`_xmpps-client`/`_xmpp-client`) when `host` is
omitted, trying candidates in priority/weight order with a plaintext fallback to
`domain:5222`. Inject a custom `SrvResolver` (e.g. DNS-over-HTTPS) if needed.
Honors `<see-other-host/>` stream-error redirects (bounded to 5 hops), both
during negotiation and on a live connection.

Supports XEP-0198 Stream Management: stanza acknowledgement, liveness `<r/>`
checks, and session resumption (replays unacked stanzas after a reconnect) —
opt in with `streamManagement: true, autoReconnect: true`.

Not (yet) implemented: WebSocket transport, SCRAM-SHA-256, typed roster/presence
models (you work with raw XML instead).

## Usage

```dart
import 'package:xmpp_dart/xmpp_dart.dart';
import 'package:xml/xml.dart'; // XmlElement — stanzas and IQ responses

final client = XmppClient(
  domain: 'example.com',       // host omitted -> DNS SRV resolves it
  username: 'alice',
  password: 'secret',
  tls: TlsMode.starttls,       // required STARTTLS; also .opportunistic / .direct (5223) / .none
);
// Or pin the server explicitly (skips SRV):
//   host: 'xmpp.example.com', port: 5222, tls: TlsMode.starttls

client.states.listen((s) => print('state: $s')); // XmppState enum

await client.connect();        // completes when online
print('online as ${client.jid}'); // Jid — local@domain/resource

client.stanzas.listen((s) => print('recv: ${s.toXmlString()}'));

await client.send(xml('presence'));
await client.send(xml('message',
    attrs: {'to': 'bob@example.com', 'type': 'chat'},
    children: [xml('body', text: 'hi')]));

// IQ request/response — returns the full <iq type="result"> stanza
final rosterIq = await client.iq(xml('iq', attrs: {'type': 'get'}, children: [
  xml('query', attrs: {'xmlns': 'jabber:iq:roster'}),
]));

await client.close();
```

## API reference

Reference for code generation. The library is **XML-first**: stanzas are
[`XmlElement`](https://pub.dev/packages/xml) values built with `xml()` and
inspected with the `xml` package API. There are no typed `Roster`, `Message`, or
`Presence` classes — you parse XML yourself.

### Imports

```dart
import 'package:xmpp_dart/xmpp_dart.dart'; // all public types
import 'package:xml/xml.dart';             // XmlElement inspection
```

Public exports from `package:xmpp_dart/xmpp_dart.dart`:

| Symbol | Kind |
|--------|------|
| `XmppClient` | class — recommended entry point |
| `XmppConnection` | class — low-level connection state machine |
| `IqCaller`, `IqException` | class — IQ request/response pairing |
| `Jid` | class — XMPP address value type |
| `TlsMode`, `XmppState` | enum |
| `XmppException`, `StreamErrorException` | exception |
| `SaslMechanism`, `PlainMechanism`, `ScramSha1Mechanism`, `SaslException` | SASL (usually internal to connection) |
| `Transport`, `TcpTransport` | transport abstraction |
| `Reconnect` | exponential-backoff retry helper |
| `xml`, `XmlStreamParser` | XML builder and stream parser |

Dependencies: `xml` ^7, `crypto` ^3 (used internally for SCRAM-SHA-1).

### Architecture

```
XmppClient
  └─ TcpTransport.connect(host, port)
  └─ XmppConnection(transport, domain, username, password, …)
       └─ XmlStreamParser  (bytes → XmlElement stanzas)
       └─ SASL negotiation (PLAIN or SCRAM-SHA-1, auto-selected)
  └─ IqCaller(conn.stanzas, conn.send)  (IQ id matching)
```

Use **`XmppClient`** for normal apps. Use **`XmppConnection`** directly when you
need a custom `Transport` (tests, proxies). `XmppClient` exposes `states`,
`stanzas`, `acks`, and `errors` — the last carries typed [`XmppException`]s
(with `isPermanent`) plus `ReconnectException` when auto-reconnect gives up.

### `XmppClient`

High-level TCP client. Creates transport + connection internally.

```dart
XmppClient({
  required String host,       // TCP hostname (may differ from domain)
  required String domain,     // XMPP domain for stream 'to' and SASL
  required String username,   // localpart (without @domain)
  required String password,
  int? port,                  // default: 5222 (starttls/none) or 5223 (direct)
  TlsMode tls = TlsMode.starttls,
  String? resource,           // optional; server assigns one if omitted
})
```

| Member | Type | Description |
|--------|------|-------------|
| `states` | `Stream<XmppState>` | broadcast; emits on every state transition |
| `stanzas` | `Stream<XmlElement>` | broadcast; incoming stanzas once online |
| `jid` | `Jid?` | bound full JID after `connect()`; `null` before |
| `connect()` | `Future<void>` | negotiates TLS → SASL → bind; completes at `online` |
| `send(element)` | `Future<void>` | writes `element.toXmlString()` to server |
| `iq(element)` | `Future<XmlElement>` | sends IQ, awaits matching-`id` response |
| `close()` | `Future<void>` | sends `</stream:stream>`, closes socket and streams (**not reusable**) |

**`connect()` throws** (does not catch): `XmppException`, `SaslException`,
`StreamErrorException`, `TimeoutException` (negotiation timeout, default 10s on
`XmppConnection`).

**`send` / `iq` before connect** complete with `StateError('not connected')`.

Subscribe to `states` and `stanzas` **before** `connect()` so no events are
missed (streams are broadcast).

### `XmppConnection`

Low-level session driver. Same negotiation as `XmppClient` but you supply the
`Transport`.

```dart
XmppConnection({
  required Transport transport,
  required String domain,
  required String username,
  required String password,
  TlsMode tls = TlsMode.starttls,
  String? resource,
  Duration timeout = const Duration(seconds: 10), // per negotiation read
})
```

| Member | Type | Description |
|--------|------|-------------|
| `jid` | `Jid?` | set after resource binding |
| `state` | `XmppState` | current state (synchronous) |
| `userClosed` | `bool` | `true` after explicit `close()` |
| `states` | `Stream<XmppState>` | state transitions |
| `stanzas` | `Stream<XmlElement>` | incoming stanzas while online |
| `errors` | `Stream<Object>` | stream errors after online (triggers auto-close) |
| `connect()` | `Future<Jid>` | returns bound JID |
| `send(element)` | `Future<void>` | write stanza |
| `close()` | `Future<void>` | graceful shutdown |

Pair with `IqCaller` manually:

```dart
final conn = XmppConnection(transport: t, domain: 'ex', username: 'a', password: 'p');
final iq = IqCaller(conn.stanzas, conn.send);
await conn.connect();
final res = await iq.request(xml('iq', attrs: {'type': 'get'}, children: [...]));
await iq.dispose();
await conn.close();
```

### `TlsMode`

| Value | Port default | Behavior |
|-------|--------------|----------|
| `TlsMode.starttls` | 5222 | plaintext socket, **require** `<starttls>` upgrade (fails if the server doesn't offer it) |
| `TlsMode.opportunistic` | 5222 | upgrade via `<starttls>` if offered, else continue plaintext |
| `TlsMode.direct` | 5223 | `SecureSocket.connect` immediately |
| `TlsMode.none` | 5222 | no TLS (testing only) |

### `XmppState`

Lifecycle enum emitted on `states`:

```
offline → connecting → open → authenticating → bound → online
                                                          ↓
                                              closing → disconnected
```

| State | Meaning |
|-------|---------|
| `offline` | initial |
| `connecting` | TCP open, negotiation starting |
| `open` | `<stream:stream>` sent, reading features |
| `authenticating` | SASL in progress |
| `bound` | resource binding |
| `online` | ready for stanzas |
| `closing` | user called `close()` |
| `disconnected` | socket closed |

### `Jid`

Immutable value type: `local@domain/resource`.

```dart
const Jid(local, domain, resource)   // any part may be null except domain
Jid.parse('alice@example.com/phone') // factory
jid.bare()                           // drops resource → alice@example.com
jid.toString()                       // canonical string
jid.local, jid.domain, jid.resource  // fields
```

Parse rules: first `/` splits resource (resource may contain more `/`); `@`
splits local from domain.

### `xml()` — stanza builder

```dart
XmlElement xml(
  String name, {
  Map<String, String>? attrs,
  List<XmlElement>? children,
  String? text,
})
```

Produces an `XmlElement` with **unqualified** element names (no namespace prefix
on the tag). Put namespaces in `attrs: {'xmlns': '…'}` on the element that
needs them.

```dart
// <presence/>
xml('presence')

// <presence type="unavailable"/>
xml('presence', attrs: {'type': 'unavailable'})

// <message to="bob@ex" type="chat"><body>hi</body></message>
xml('message',
  attrs: {'to': 'bob@ex', 'type': 'chat'},
  children: [xml('body', text: 'hi')],
)

// <iq type="get" id="r1"><query xmlns="jabber:iq:roster"/></iq>
xml('iq', attrs: {'type': 'get', 'id': 'r1'}, children: [
  xml('query', attrs: {'xmlns': 'jabber:iq:roster'}),
])
```

**Do not** set `xmlns` on the stream root — the connection handles that.

Outgoing stanzas are serialized with `element.toXmlString()` (no XML declaration
prepended per stanza).

### `XmlElement` inspection (`package:xml`)

All incoming stanzas and IQ responses are `XmlElement`. Common methods:

| Method | Returns | Use |
|--------|---------|-----|
| `name.local` | `String` | tag name without prefix (`message`, `iq`, `presence`) |
| `getAttribute(name)` | `String?` | stanza attrs: `to`, `from`, `type`, `id` |
| `getElement(name)` | `XmlElement?` | first direct child by local name |
| `findElements(name)` | `Iterable<XmlElement>` | all descendants by local name |
| `childElements` | `Iterable<XmlElement>` | direct children |
| `innerText` | `String` | concatenated text content |
| `toXmlString()` | `String` | serialize (debugging) |
| `setAttribute(name, value)` | `void` | mutate (used by `IqCaller` for `id`) |

**Stanza routing** — branch on `stanza.name.local`:

```dart
client.stanzas.listen((stanza) {
  switch (stanza.name.local) {
    case 'message':
      final body = stanza.getElement('body')?.innerText;
      final from = stanza.getAttribute('from');
      // ...
    case 'presence':
      final type = stanza.getAttribute('type'); // unavailable, subscribe, …
      final from = Jid.parse(stanza.getAttribute('from')!);
      // ...
    case 'iq':
      // usually handled by IqCaller; unmatched IQs arrive here too
      break;
  }
});
```

### `client.iq` / `IqCaller`

```dart
Future<XmlElement> iq(XmlElement element)          // XmppClient
Future<XmlElement> request(XmlElement iq)          // IqCaller
```

Behavior:

1. If `iq` has no `id`, assigns `iq-0`, `iq-1`, …
2. Sends the stanza.
3. Waits for an `<iq>` with the same `id`.
4. `type="error"` → throws `IqException` (message is full XML string).
5. Any other type (`result`, etc.) → returns the full `<iq>` element.
6. No response within timeout → `TimeoutException` (default 30s on `IqCaller`).

The returned value is the **entire response stanza**, not just the payload child.
Extract payload with `getElement` / `findElements`:

```dart
final res = await client.iq(xml('iq', attrs: {'type': 'get'}, children: [
  xml('query', attrs: {'xmlns': 'jabber:iq:version'}),
]));
final query = res.getElement('query');
final name = query?.getElement('name')?.innerText;
```

IQ `type` on requests: `get` (read), `set` (write). Response types: `result`,
`error`.

### Common stanza recipes

Namespaces and attrs shown are what servers expect. Adjust `to` / `from` as needed.

**Initial presence** (go online):

```dart
await client.send(xml('presence'));
```

**Directed presence**:

```dart
await client.send(xml('presence', attrs: {'to': 'bob@example.com'}));
```

**Unavailable** (go offline):

```dart
await client.send(xml('presence', attrs: {'type': 'unavailable'}));
```

**Chat message**:

```dart
await client.send(xml('message',
  attrs: {'to': 'bob@example.com', 'type': 'chat'},
  children: [xml('body', text: 'hello')],
));
```

**Roster fetch** (`jabber:iq:roster`):

```dart
final rosterIq = await client.iq(xml('iq', attrs: {'type': 'get'}, children: [
  xml('query', attrs: {'xmlns': 'jabber:iq:roster'}),
]));
for (final item in rosterIq.findElements('item')) {
  final jid = Jid.parse(item.getAttribute('jid')!);
  final name = item.getAttribute('name');
  final subscription = item.getAttribute('subscription'); // both|to|from|none
}
```

**Roster add / subscribe**:

```dart
await client.iq(xml('iq', attrs: {'type': 'set'}, children: [
  xml('query', attrs: {'xmlns': 'jabber:iq:roster'}, children: [
    xml('item', attrs: {'jid': 'bob@example.com', 'name': 'Bob'}),
  ]),
]));
await client.send(xml('presence',
  attrs: {'to': 'bob@example.com', 'type': 'subscribe'}));
```

**Service discovery** (`http://jabber.org/protocol/disco#info`):

```dart
final disco = await client.iq(xml('iq',
  attrs: {'type': 'get', 'to': 'example.com'},
  children: [
    xml('query', attrs: {'xmlns': 'http://jabber.org/protocol/disco#info'}),
  ],
));
```

**Ping** (`urn:xmpp:ping`):

```dart
await client.iq(xml('iq',
  attrs: {'type': 'get', 'to': 'example.com'},
  children: [xml('ping', attrs: {'xmlns': 'urn:xmpp:ping'})],
));
```

**Version** (`jabber:iq:version`):

```dart
final ver = await client.iq(xml('iq', attrs: {'type': 'get'}, children: [
  xml('query', attrs: {'xmlns': 'jabber:iq:version'}),
]));
```

### `Reconnect`

Exponential-backoff retry wrapper. Does **not** own a client — you wire it.

**`XmppClient` is not reusable after `close()`** — it closes `states` and
`stanzas`. For reconnect, create a fresh client each attempt (or use
`XmppConnection` directly, which keeps its streams open across `close()`).

```dart
XmppClient? client;
final reconnect = Reconnect(() async {
  client = XmppClient(host: 'example.com', domain: 'example.com',
      username: 'alice', password: 'secret');
  client!.stanzas.listen(handleStanza); // subscribe before connect
  await client!.connect();
  await client!.send(xml('presence'));
}, base: const Duration(seconds: 1), max: const Duration(seconds: 60));

// on unexpected disconnect — only retry if user didn't call close():
client?.states.listen((s) {
  if (s == XmppState.disconnected) reconnect.run();
});

reconnect.stop(); // cancel pending retries
await client?.close(); // intentional shutdown — don't reconnect
```

| Member | Description |
|--------|-------------|
| `backoff(attempt)` | delay for attempt *n* (1-based): `base * 2^(n-1)`, capped at `max` |
| `run()` | calls `connect` until success or `stop()` |
| `stop()` | halt retries |
| `attempts` | failure count |

Check `XmppConnection.userClosed` (low-level) to avoid reconnecting after
intentional `close()`.

### `Transport` / `TcpTransport`

```dart
abstract class Transport {
  Stream<List<int>> get incoming;
  void write(String data);
  Future<void> upgradeTls(String host);
  Future<void> close();
  Future<void> get done;
}

// Real socket:
final t = await TcpTransport.connect('host', 5222, secure: false);
```

For unit tests, implement `Transport` or use a fake that records `writes` and
accepts scripted `incoming` bytes (see `test/support/fake_transport.dart`).

### `XmlStreamParser`

Low-level incremental parser for XMPP byte streams. Used internally by
`XmppConnection`; exposed for custom tooling.

```dart
final parser = XmlStreamParser();
parser.streamOpen.listen((el) => /* <stream:stream> attrs */);
parser.stanzas.listen((stanza) => /* complete top-level element */);
parser.streamClose.listen((_) => /* </stream:stream> */);
parser.feed(chunk);  // call with decoded UTF-8 strings, any chunk size
parser.reset();      // after STARTTLS or SASL stream restart
parser.close();
```

### Exceptions

| Type | When |
|------|------|
| `XmppException` | negotiation failure (bad bind, unexpected element, …) |
| `StreamErrorException` | server sent `<stream:error>` (unrecoverable) |
| `SaslException` | auth failure or unsupported mechanism |
| `IqException` | IQ response `type="error"` |
| `TimeoutException` | IQ or negotiation read timed out |
| `StateError` | `send`/`iq` on disconnected `XmppClient` |

`StreamErrorException` and `errors` stream (on `XmppConnection`) fire after the
session is already online; the connection auto-closes.

### SASL

Mechanism selection is automatic via `selectMechanism` (internal): prefers
**SCRAM-SHA-1** over **PLAIN** from server-offered list. `ScramSha1Mechanism`
and `PlainMechanism` are exported for testing; apps do not call them directly.

Username is the **localpart** only (not `user@domain`). Domain is the XMPP
service domain passed to `XmppClient.domain`.

### Agent checklist

When generating code against this library:

1. Import both `xmpp_dart` and `xml`.
2. Use `XmppClient` unless custom transport is required.
3. Subscribe to `stanzas` before `connect()`.
4. Build all stanzas with `xml()`; parse responses with `XmlElement` methods.
5. Use `client.iq()` for request/response; use `client.send()` for fire-and-forget
   (presence, messages).
6. `client.iq()` returns the full `<iq>` wrapper — drill into children.
7. Use `Jid.parse()` on `from`/`to` attributes; compare with `.bare()` for
   bare-JID matching.
8. Call `await client.send(xml('presence'))` after connect to appear online.
9. Call `await client.close()` on shutdown — creates a **new** `XmppClient` to reconnect.
10. Do **not** invent helper classes from this package — they do not exist.
11. Do **not** use WebSocket, stream management, or SCRAM-SHA-256 — not implemented.

## Answering inbound IQs

Register handlers for `iq get`/`set`; the reply (result or error) is built and
sent for you. `urn:xmpp:ping` is answered automatically.

```dart
client.onIqGet('jabber:iq:version', 'query', (iq, child) {
  return xml('query', attrs: {'xmlns': 'jabber:iq:version'}, children: [
    xml('name', text: 'my-bot'),
    xml('version', text: '1.0'),
  ]);
});

// Reject with a stanza error:
client.onIqSet('urn:example', 'cmd', (iq, child) {
  throw IqError('forbidden', type: 'auth');
});
```

Return `null` for an empty `<iq type="result"/>`. Unmatched queries get
`service-unavailable`, malformed ones `bad-request`. Handlers persist across
reconnects.

## Testing

```bash
dart test                       # unit tests (no network)
dart test --tags integration    # real server, needs XMPP_HOST/USER/PASS env vars
```

The `Transport` abstraction is the test seam: unit tests drive the full
negotiation with a scripted in-memory transport, no sockets involved.

## Design

See [`docs/superpowers/specs/2026-07-07-xmpp-dart-tcp-client-design.md`](docs/superpowers/specs/2026-07-07-xmpp-dart-tcp-client-design.md).
