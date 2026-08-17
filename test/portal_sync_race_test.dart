import 'package:dop_collect/data/app_settings.dart';
import 'package:dop_collect/data/portal/portal_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Daily Auto-Login Lockout Counter', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('starts at zero and increments per call for the day', () async {
      final now = DateTime(2026, 8, 17);
      expect(await AppSettings.dailyAutoLoginCount(now), 0);

      expect(await AppSettings.incrementDailyAutoLoginCount(now), 1);
      expect(await AppSettings.dailyAutoLoginCount(now), 1);

      expect(await AppSettings.incrementDailyAutoLoginCount(now), 2);
      expect(await AppSettings.dailyAutoLoginCount(now), 2);
    });

    test('isolates counts across different calendar days', () async {
      final day1 = DateTime(2026, 8, 17);
      final day2 = DateTime(2026, 8, 18);

      await AppSettings.incrementDailyAutoLoginCount(day1);
      await AppSettings.incrementDailyAutoLoginCount(day1);
      await AppSettings.incrementDailyAutoLoginCount(day1);

      expect(await AppSettings.dailyAutoLoginCount(day1), 3);
      expect(await AppSettings.dailyAutoLoginCount(day2), 0);
    });
  });

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
