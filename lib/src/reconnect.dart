import 'dart:async';

import 'errors.dart';

/// Retries a connect operation with exponential backoff.
///
/// The connect callback, the retry policy, and the sleep function are injected
/// so the schedule and classification can be tested without real delays or
/// sockets.
class Reconnect {
  final Future<void> Function() connect;
  final Duration base;
  final Duration max;

  /// Whether to retry after [error]. Defaults to retrying everything except
  /// permanent failures (auth, TLS, protocol) — see [isPermanentError].
  final bool Function(Object error) retryIf;

  /// Give up after this many failed attempts (null = unlimited).
  final int? maxAttempts;

  final Future<void> Function(Duration) _sleep;

  int attempts = 0;
  bool _stopped = false;

  Reconnect(
    this.connect, {
    this.base = const Duration(seconds: 1),
    this.max = const Duration(seconds: 60),
    bool Function(Object error)? retryIf,
    this.maxAttempts,
    Future<void> Function(Duration)? sleep,
  }) : retryIf = retryIf ?? _defaultRetryIf,
       _sleep = sleep ?? _realSleep;

  static bool _defaultRetryIf(Object error) => !isPermanentError(error);
  static Future<void> _realSleep(Duration d) => Future<void>.delayed(d);

  /// Delay before retry [attempt] (1-based): `base * 2^(attempt-1)`, capped.
  Duration backoff(int attempt) {
    final ms = base.inMilliseconds * (1 << (attempt - 1));
    final capped = ms < max.inMilliseconds ? ms : max.inMilliseconds;
    return Duration(milliseconds: capped);
  }

  /// Calls [connect] until it succeeds or [stop] is called. Rethrows the last
  /// error when it is not retryable or [maxAttempts] is exhausted.
  Future<void> run() async {
    while (!_stopped) {
      try {
        await connect();
        return;
      } catch (error) {
        attempts++;
        if (!retryIf(error)) rethrow;
        if (maxAttempts != null && attempts >= maxAttempts!) rethrow;
        if (_stopped) return;
        await _sleep(backoff(attempts));
      }
    }
  }

  void stop() => _stopped = true;
}
