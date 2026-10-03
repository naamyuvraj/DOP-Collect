import 'package:dop_collect/data/portal/portal_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Reference parsing robustness', () {
    test('parses C, DC, NDC references correctly', () {
      expect(PortalSyncEngine.parseReference('Reference No: C340185771'), 'C340185771');
      expect(PortalSyncEngine.parseReference('Reference No: DC123456789'), 'DC123456789');
      expect(PortalSyncEngine.parseReference('Reference No: NDC987654321'), 'NDC987654321');
    });

    test('returns null for non-references', () {
      expect(PortalSyncEngine.parseReference('No reference here'), isNull);
      expect(PortalSyncEngine.parseReference('ABC12345'), isNull);
    });
  });
}
