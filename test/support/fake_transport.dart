import 'dart:async';
import 'dart:convert';

import 'package:xmpp_dart/src/transport.dart';

/// In-memory [Transport] for tests. Push server bytes with [deliver]; inspect
/// what the client sent via [writes].
class FakeTransport implements Transport {
  final _incoming = StreamController<List<int>>();
  final List<String> writes = [];
  final _done = Completer<void>();
  bool tlsUpgraded = false;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  void write(String data) => writes.add(data);

  @override
  Future<void> upgradeTls(String host) async => tlsUpgraded = true;

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
    if (!_incoming.isClosed) await _incoming.close();
  }

  @override
  Future<void> get done => _done.future;

  /// Simulates bytes arriving from the server.
  void deliver(String xml) => _incoming.add(utf8.encode(xml));

  /// Simulates the socket dropping unexpectedly.
  void drop() {
    if (!_done.isCompleted) _done.complete();
  }

  String get lastWrite => writes.last;
}

/// Drains pending microtasks/events so async negotiation steps advance.
Future<void> pump([int ticks = 4]) async {
  for (var i = 0; i < ticks; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
