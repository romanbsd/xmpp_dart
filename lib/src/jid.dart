/// An XMPP address: `local@domain/resource`. Only [domain] is required.
///
/// This is a value type — two JIDs with the same parts are equal.
///
/// NOTE: parsing is intentionally minimal — it splits on `@` and `/` only. It
/// does NOT perform RFC 7622 preparation/normalization (PRECIS/stringprep),
/// XEP-0106 JID escaping, or validation of length/allowed characters. Two JIDs
/// that a compliant server considers equal (e.g. differing only by case or
/// Unicode normalization) may compare unequal here. Callers that mix
/// user-supplied JIDs into security decisions should normalize upstream.
class Jid {
  final String? local;
  final String domain;
  final String? resource;

  const Jid(this.local, this.domain, this.resource);

  /// Parses `[local@]domain[/resource]`. The resource may itself contain `/`.
  factory Jid.parse(String input) {
    String? local;
    String? resource;
    var rest = input;

    final slash = rest.indexOf('/');
    if (slash >= 0) {
      resource = rest.substring(slash + 1);
      rest = rest.substring(0, slash);
    }

    final at = rest.indexOf('@');
    if (at >= 0) {
      local = rest.substring(0, at);
      rest = rest.substring(at + 1);
    }

    return Jid(local, rest, resource);
  }

  /// The bare JID: same [local] and [domain], no [resource].
  Jid bare() => Jid(local, domain, null);

  @override
  String toString() {
    final b = StringBuffer();
    if (local != null) b.write('$local@');
    b.write(domain);
    if (resource != null) b.write('/$resource');
    return b.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is Jid && other.local == local && other.domain == domain && other.resource == resource;

  @override
  int get hashCode => Object.hash(local, domain, resource);
}
