// Examples print to stdout for demonstration.
// ignore_for_file: avoid_print

import 'package:xmpp_dart/xmpp_dart.dart';

/// Connects, sends initial presence, prints incoming stanzas.
///
/// Run: dart example/xmpp_dart_example.dart
Future<void> main() async {
  final client = XmppClient(
    host: 'example.com',
    domain: 'example.com',
    username: 'alice',
    password: 'secret',
  );

  client.states.listen((s) => print('state: $s'));
  client.stanzas.listen((s) => print('recv: ${s.toXmlString()}'));

  await client.connect();
  print('online as ${client.jid}');

  await client.send(xml('presence'));

  await client.send(xml('message',
      attrs: {'to': 'bob@example.com', 'type': 'chat'},
      children: [xml('body', text: 'hello from dart')]));

  // Keep running to receive messages; Ctrl-C to quit.
  await Future<void>.delayed(const Duration(seconds: 30));
  await client.close();
}
