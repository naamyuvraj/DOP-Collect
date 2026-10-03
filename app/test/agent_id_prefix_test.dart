import 'package:dop_collect/data/credentials.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every DOP agent id is `DOP.` + the agent's own code — the corporate half of
/// Finacle's `corpId.cxpsUserId`, identical for every agent on this portal. The
/// app fills it in so he types only his own part.
///
/// Prefilling a field is the easy half. The hard half is that he will then
/// paste the whole id on top of it, and `DOP.DOP.MI8472350100005` is not a
/// login — it is a rejected attempt, and rejected attempts are what walk an
/// agent towards Finacle's ten-failure lockout.
void main() {
  String n(String s) => Credentials.normaliseAgentId(s);

  test('a bare code gains the prefix', () {
    expect(n('MI8472350100005'), 'DOP.MI8472350100005');
  });

  test('an id that already has it is left alone', () {
    expect(n('DOP.MI8472350100005'), 'DOP.MI8472350100005');
  });

  test('pasting the full id over the prefilled prefix does not double it', () {
    expect(n('DOP.DOP.MI8472350100005'), 'DOP.MI8472350100005');
    expect(n('DOP.DOP.DOP.MI8472350100005'), 'DOP.MI8472350100005');
  });

  test('case and stray spacing are normalised', () {
    expect(n('dop.MI8472350100005'), 'DOP.MI8472350100005');
    expect(n('  Dop. MI8472350100005  '), 'DOP.MI8472350100005');
  });

  test('empty stays empty, and so does a field holding only the prefix', () {
    // This one matters. The sign-up form checks `agentId.isEmpty` to refuse a
    // half-filled login; if a prefilled "DOP." counted as an id, the app would
    // save credentials with no agent code and then autofill a login that
    // cannot succeed.
    expect(n(''), '');
    expect(n('   '), '');
    expect(n('DOP.'), '');
    expect(n('dop.'), '');
  });

  test('the prefix constant is what the portal states', () {
    // `portalAgentId()` reads corpId + '.' + cxpsUserId, e.g.
    // "DOP.MI8472350100005", and that exact string is typed into the login
    // box — so the prefix the app fills in has to be the same one.
    expect(Credentials.dopPrefix, 'DOP.');
    expect(n('MI1').startsWith(Credentials.dopPrefix), isTrue);
  });
}
