import 'package:test/test.dart';
import 'package:xmpp_dart/src/jid.dart';

void main() {
  test('parses full jid', () {
    final j = Jid.parse('alice@example.com/phone');
    expect(j.local, 'alice');
    expect(j.domain, 'example.com');
    expect(j.resource, 'phone');
    expect(j.toString(), 'alice@example.com/phone');
  });

  test('bare() drops resource', () {
    final j = Jid.parse('alice@example.com/phone').bare();
    expect(j.resource, isNull);
    expect(j.toString(), 'alice@example.com');
  });

  test('domain only', () {
    final j = Jid.parse('example.com');
    expect(j.local, isNull);
    expect(j.domain, 'example.com');
    expect(j.resource, isNull);
    expect(j.toString(), 'example.com');
  });

  test('domain with resource, no local', () {
    final j = Jid.parse('example.com/res');
    expect(j.local, isNull);
    expect(j.domain, 'example.com');
    expect(j.resource, 'res');
  });

  test('resource may contain slash', () {
    expect(Jid.parse('a@b/x/y').resource, 'x/y');
  });

  test('equality and hashCode', () {
    expect(Jid.parse('a@b/c'), Jid.parse('a@b/c'));
    expect(Jid.parse('a@b/c').hashCode, Jid.parse('a@b/c').hashCode);
    expect(Jid.parse('a@b/c'), isNot(Jid.parse('a@b/d')));
  });
}
