import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory stand-in for the Android Keystore behind flutter_secure_storage.
///
/// Without it the plugin's MethodChannel is unimplemented in tests, so anything
/// reading the DOP login or the device session throws MissingPluginException —
/// and `SessionStore` would only ever be exercised through its in-process
/// cache, never through a real read/write round trip.
class FakeSecureStorage {
  FakeSecureStorage._();

  static const _channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  static final Map<String, String> values = {};

  /// Install the fake and clear it. Call from `setUp`.
  static void install([Map<String, String> seed = const {}]) {
    values
      ..clear()
      ..addAll(seed);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return values[key];
        case 'write':
          if (key != null) values[key] = args['value'] as String? ?? '';
          return null;
        case 'delete':
          values.remove(key);
          return null;
        case 'readAll':
          return Map<String, String>.from(values);
        case 'deleteAll':
          values.clear();
          return null;
        case 'containsKey':
          return values.containsKey(key);
        default:
          return null;
      }
    });
  }

  /// Remove the fake. Call from `tearDown`.
  static void remove() {
    values.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}
