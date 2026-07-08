import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'errors.dart';

/// A SASL mechanism. Values passed in/out are the *decoded* SASL payloads;
/// the connection handles base64 on the wire.
abstract class SaslMechanism {
  String get name;

  /// The `<auth>` payload (client-first). `null` means empty.
  String? initial();

  /// Given a decoded `<challenge>`, returns the decoded `<response>`.
  String response(String challenge);

  /// Verifies the decoded `<success>` payload (if any). Throws on mismatch.
  void onSuccess(String? data) {}
}

/// SASL PLAIN (RFC 4616): `\0username\0password`, base64-encoded by the caller.
class PlainMechanism extends SaslMechanism {
  final String username;
  final String password;
  PlainMechanism(this.username, this.password);

  @override
  String get name => 'PLAIN';

  @override
  String? initial() => '\u0000$username\u0000$password';

  @override
  String response(String challenge) => throw SaslException('PLAIN expects no challenge');
}

/// SASL SCRAM-SHA-1 (RFC 5802). [nonce] is injectable for deterministic tests.
class ScramSha1Mechanism extends SaslMechanism {
  final String username;
  final String password;
  final String _clientNonce;

  String _clientFirstBare = '';
  String _serverFirst = '';
  List<int> _serverSignature = const [];

  ScramSha1Mechanism(this.username, this.password, {String? nonce}) : _clientNonce = nonce ?? _randomNonce();

  @override
  String get name => 'SCRAM-SHA-1';

  @override
  String? initial() {
    _clientFirstBare = 'n=${_saslName(username)},r=$_clientNonce';
    return 'n,,$_clientFirstBare';
  }

  @override
  String response(String challenge) {
    _serverFirst = challenge;
    final attrs = _parse(challenge);
    final combinedNonce = attrs['r']!;
    if (!combinedNonce.startsWith(_clientNonce)) {
      throw SaslException('server nonce does not extend client nonce');
    }
    final salt = base64.decode(attrs['s']!);
    final iterations = int.parse(attrs['i']!);

    final saltedPassword = _pbkdf2(utf8.encode(password), salt, iterations);
    final clientKey = _hmac(saltedPassword, utf8.encode('Client Key'));
    final storedKey = sha1.convert(clientKey).bytes;

    const channelBinding = 'c=biws'; // base64('n,,')
    final clientFinalNoProof = '$channelBinding,r=$combinedNonce';
    final authMessage = '$_clientFirstBare,$_serverFirst,$clientFinalNoProof';
    final authBytes = utf8.encode(authMessage);

    final clientSignature = _hmac(storedKey, authBytes);
    final clientProof = _xor(clientKey, clientSignature);

    final serverKey = _hmac(saltedPassword, utf8.encode('Server Key'));
    _serverSignature = _hmac(serverKey, authBytes);

    return '$clientFinalNoProof,p=${base64.encode(clientProof)}';
  }

  @override
  void onSuccess(String? data) {
    if (data == null) return;
    final v = _parse(data)['v'];
    if (v == null) return;
    if (base64.encode(_serverSignature) != v) {
      throw SaslException('server signature mismatch');
    }
  }

  static String _randomNonce() {
    final r = Random.secure();
    return base64.encode(List.generate(18, (_) => r.nextInt(256)));
  }

  // PBKDF2-HMAC-SHA1. SHA1 output (20 bytes) == desired key length, so a
  // single block suffices.
  static List<int> _pbkdf2(List<int> password, List<int> salt, int iterations) {
    var u = _hmac(password, [...salt, 0, 0, 0, 1]);
    final result = List<int>.of(u);
    for (var i = 1; i < iterations; i++) {
      u = _hmac(password, u);
      for (var j = 0; j < result.length; j++) {
        result[j] ^= u[j];
      }
    }
    return result;
  }

  static List<int> _hmac(List<int> key, List<int> data) => Hmac(sha1, key).convert(data).bytes;

  static List<int> _xor(List<int> a, List<int> b) => [for (var i = 0; i < a.length; i++) a[i] ^ b[i]];

  // RFC 5802: '=' and ',' in the username are escaped.
  static String _saslName(String s) => s.replaceAll('=', '=3D').replaceAll(',', '=2C');

  static Map<String, String> _parse(String msg) {
    final map = <String, String>{};
    for (final part in msg.split(',')) {
      final eq = part.indexOf('=');
      if (eq > 0) map[part.substring(0, eq)] = part.substring(eq + 1);
    }
    return map;
  }
}

/// Picks the strongest supported mechanism from those the server advertises.
SaslMechanism? selectMechanism(List<String> offered, String username, String password) {
  if (offered.contains('SCRAM-SHA-1')) {
    return ScramSha1Mechanism(username, password);
  }
  if (offered.contains('PLAIN')) {
    return PlainMechanism(username, password);
  }
  return null;
}
