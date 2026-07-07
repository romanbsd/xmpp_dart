import 'package:test/test.dart';
import 'package:xmpp_dart/src/reconnect.dart';

void main() {
  test('retries until connect succeeds, with growing backoff', () async {
    var calls = 0;
    final delays = <Duration>[];

    final r = Reconnect(
      () async {
        calls++;
        if (calls < 3) throw Exception('fail $calls');
      },
      base: const Duration(seconds: 1),
      sleep: (d) async => delays.add(d),
    );

    await r.run();

    expect(calls, 3); // 2 failures + 1 success
    expect(r.attempts, 2);
    expect(delays, [
      const Duration(seconds: 1),
      const Duration(seconds: 2),
    ]);
  });

  test('backoff caps at max', () {
    final r = Reconnect(
      () async {},
      base: const Duration(seconds: 1),
      max: const Duration(seconds: 5),
    );
    expect(r.backoff(1), const Duration(seconds: 1));
    expect(r.backoff(2), const Duration(seconds: 2));
    expect(r.backoff(3), const Duration(seconds: 4));
    expect(r.backoff(4), const Duration(seconds: 5)); // capped
    expect(r.backoff(10), const Duration(seconds: 5));
  });

  test('stop() halts retries', () async {
    var calls = 0;
    final r = Reconnect(
      () async {
        calls++;
        throw Exception('always fails');
      },
      sleep: (d) async {},
    );

    // Stop after the first failure.
    r.stop();
    await r.run();
    expect(calls, lessThanOrEqualTo(1));
  });
}
