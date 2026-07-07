import 'dart:async';

/// Retries a connect operation with exponential backoff.
///
/// The connect callback and the sleep function are injected so the backoff
/// schedule can be tested without real delays.
class Reconnect {
  final Future<void> Function() connect;
  final Duration base;
  final Duration max;
  final Future<void> Function(Duration) _sleep;

  int attempts = 0;
  bool _stopped = false;

  Reconnect(
    this.connect, {
    this.base = const Duration(seconds: 1),
    this.max = const Duration(seconds: 60),
    Future<void> Function(Duration)? sleep,
  }) : _sleep = sleep ?? _realSleep;

  static Future<void> _realSleep(Duration d) => Future<void>.delayed(d);

  /// Delay before retry [attempt] (1-based): `base * 2^(attempt-1)`, capped.
  Duration backoff(int attempt) {
    final ms = base.inMilliseconds * (1 << (attempt - 1));
    final capped = ms < max.inMilliseconds ? ms : max.inMilliseconds;
    return Duration(milliseconds: capped);
  }

  /// Calls [connect] until it succeeds or [stop] is called.
  Future<void> run() async {
    while (!_stopped) {
      try {
        await connect();
        return;
      } catch (_) {
        attempts++;
        if (_stopped) return;
        await _sleep(backoff(attempts));
      }
    }
  }

  void stop() => _stopped = true;
}
