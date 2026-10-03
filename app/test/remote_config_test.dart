import 'package:flutter_test/flutter_test.dart';
import 'package:dop_collect/services/remote_config.dart';

void main() {
  group('RemoteConfig.versionLess (force-update gate)', () {
    test('older build is less than a higher minimum', () {
      expect(RemoteConfig.versionLess('0.9.35', '0.9.36'), isTrue);
      expect(RemoteConfig.versionLess('0.9.3', '0.9.36'), isTrue);
      expect(RemoteConfig.versionLess('0.8.99', '0.9.0'), isTrue);
    });

    test('equal or newer build is NOT blocked', () {
      expect(RemoteConfig.versionLess('0.9.36', '0.9.36'), isFalse);
      expect(RemoteConfig.versionLess('0.9.37', '0.9.36'), isFalse);
      expect(RemoteConfig.versionLess('1.0.0', '0.9.99'), isFalse);
    });

    test('build-number suffix is compared after patch', () {
      expect(RemoteConfig.versionLess('0.9.3+12', '0.9.3+20'), isTrue);
      expect(RemoteConfig.versionLess('0.9.3+20', '0.9.3+12'), isFalse);
      expect(RemoteConfig.versionLess('0.9.3+12', '0.9.3+12'), isFalse);
    });

    test('garbled parts fall back to 0, never crash', () {
      expect(RemoteConfig.versionLess('', '0.9.1'), isTrue);
      expect(RemoteConfig.versionLess('0.9.1', ''), isFalse);
      expect(RemoteConfig.versionLess('x.y.z', '0.0.1'), isTrue);
    });
  });
}
