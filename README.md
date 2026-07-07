# xmpp_dart

A lightweight Dart port of [xmpp.js](https://github.com/xmppjs/xmpp.js) — TCP
client only. Connects, secures (STARTTLS or direct TLS), authenticates
(SASL PLAIN / SCRAM-SHA-1), binds a resource, and lets you send/receive stanzas.

Not (yet) implemented: WebSocket transport, stream management, SCRAM-SHA-256,
roster/presence helpers.

## Usage

```dart
import 'package:xmpp_dart/xmpp_dart.dart';

final client = XmppClient(
  host: 'example.com',
  domain: 'example.com',
  username: 'alice',
  password: 'secret',
  tls: TlsMode.starttls,       // TlsMode.direct (port 5223) | TlsMode.none
);

await client.connect();        // completes when online
print('online as ${client.jid}');

client.stanzas.listen((s) => print('recv: ${s.toXmlString()}'));

await client.send(xml('presence'));
await client.send(xml('message',
    attrs: {'to': 'bob@example.com', 'type': 'chat'},
    children: [xml('body', text: 'hi')]));

// IQ request/response
final roster = await client.iq(xml('iq', attrs: {'type': 'get'}, children: [
  xml('query', attrs: {'xmlns': 'jabber:iq:roster'}),
]));

await client.close();
```

## Testing

```bash
dart test                       # unit tests (no network)
dart test --tags integration    # real server, needs XMPP_HOST/USER/PASS env vars
```

The `Transport` abstraction is the test seam: unit tests drive the full
negotiation with a scripted in-memory transport, no sockets involved.

## Design

See [`docs/superpowers/specs/2026-07-07-xmpp-dart-tcp-client-design.md`](docs/superpowers/specs/2026-07-07-xmpp-dart-tcp-client-design.md).
