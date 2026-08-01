import 'package:flutter_test/flutter_test.dart';

import 'package:dop_collect/data/portal/portal_sync.dart';

/// The reference-capture logic: after the agent taps Pay All, the app reads the
/// C/DC/NDC + digits reference off the portal page. This must match the longest
/// mode prefix and not false-fire on ordinary page text.
void main() {
  test('captures cash / DOP-cheque / non-DOP-cheque references', () {
    expect(PortalSyncEngine.parseReference('E-Banking Ref No: C340185771'),
        'C340185771');
    expect(PortalSyncEngine.parseReference('Reference DC123456789 generated'),
        'DC123456789');
    // NDC must win over the shorter DC/C prefixes, not be clipped.
    expect(PortalSyncEngine.parseReference('Ref: NDC998877665'), 'NDC998877665');
  });

  test('returns null when no reference is present', () {
    expect(PortalSyncEngine.parseReference('<html>Please log in</html>'), isNull);
    // A bare 9-digit number with no C/DC/NDC prefix is not a reference.
    expect(PortalSyncEngine.parseReference('Account 340185771'), isNull);
    // Too few digits.
    expect(PortalSyncEngine.parseReference('C12345'), isNull);
  });
}
