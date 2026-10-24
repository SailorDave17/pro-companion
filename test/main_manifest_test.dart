import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #46: a release build is allowed onto the network, so sync can run at all (ADR 006 decision 5).
///
/// A release build has only the main manifest's permissions. The debug and profile manifests add
/// INTERNET for the Flutter tool, so the debug APK CI builds would show INTERNET whatever the main
/// manifest says. This reads the main manifest itself, in every `flutter test` run, with nothing
/// built. scripts/check_release_signing.sh holds the release APK it builds to the same two, which is
/// the merged release manifest. #31 holds both to the two location permissions the same way, and #32
/// to the core host's three.

const networkPermissions = {
  'android.permission.INTERNET',
  'android.permission.ACCESS_NETWORK_STATE',
};

/// #31: every event carries where its phone was. Android 12+ grants FINE only when COARSE is
/// requested beside it.
const locationPermissions = {
  'android.permission.ACCESS_FINE_LOCATION',
  'android.permission.ACCESS_COARSE_LOCATION',
};

/// #32: the core host is a foreground service of type location (ADR 003), and shows a notification
/// while it logs. Without the first two, Android refuses to put it in the foreground, so the core
/// stops with the UI; without the third, Android 13+ never shows the notification.
const coreHostPermissions = {
  'android.permission.FOREGROUND_SERVICE',
  'android.permission.FOREGROUND_SERVICE_LOCATION',
  'android.permission.POST_NOTIFICATIONS',
};

final _comment = RegExp(r'<!--[\s\S]*?-->');
final _application = RegExp(r'<application\b[\s\S]*?</application>');
final _usesPermission = RegExp(r'<uses-permission\s([^>]*)>');
final _name = RegExp(r'''android:name\s*=\s*["']([^"']+)["']''');
final _removed = RegExp(r'''tools:node\s*=\s*["']remove(All)?["']''');
final _service = RegExp(r'<service\b([^>]*)>');
final _attribute = RegExp(r'''([\w:]+)\s*=\s*["']([^"']*)["']''');

/// #32: the attributes of the `<service>` named [name] in [manifest], or null when it declares
/// none. A commented-out element is not declared.
Map<String, String>? serviceAttributes(String manifest, String name) {
  for (final element in _service.allMatches(manifest.replaceAll(_comment, ''))) {
    final attributes = {for (final a in _attribute.allMatches(element.group(1)!)) a.group(1)!: a.group(2)!};
    if (attributes['android:name'] == name) return attributes;
  }
  return null;
}

/// The permissions [manifest] requests, by name. A commented-out element is not one, and nor is a
/// `<uses-permission>` inside `<application>`, which requests nothing. An element the manifest merge
/// removes (`tools:node="remove"`) is left out, and so is one capped by `android:maxSdkVersion`,
/// which current phones never get.
Set<String> requestedPermissions(String manifest) {
  final text = manifest.replaceAll(_comment, '').replaceAll(_application, '');
  final names = <String>{};
  for (final element in _usesPermission.allMatches(text)) {
    final attributes = element.group(1)!;
    if (_removed.hasMatch(attributes) || attributes.contains('maxSdkVersion')) continue;
    final name = _name.firstMatch(attributes)?.group(1);
    if (name != null) names.add(name);
  }
  return names;
}

void main() {
  group('the checker itself', () {
    const internet = '<uses-permission android:name="android.permission.INTERNET"/>';

    test('reads a requested permission, in either quote', () {
      expect(requestedPermissions('<manifest>$internet</manifest>'), {'android.permission.INTERNET'});
      expect(
          requestedPermissions("<manifest><uses-permission android:name='android.permission.INTERNET' />"
              '</manifest>'),
          {'android.permission.INTERNET'});
    });

    test('a commented-out permission is not requested', () {
      expect(requestedPermissions('<manifest><!-- $internet --></manifest>'), isEmpty);
    });

    test('a uses-permission inside <application> is not requested', () {
      expect(requestedPermissions('<manifest><application>$internet</application></manifest>'),
          isEmpty);
    });

    test('one the merge removes, or one capped below current phones, is not requested', () {
      expect(
          requestedPermissions('<manifest><uses-permission tools:node="remove" '
              'android:name="android.permission.INTERNET"/></manifest>'),
          isEmpty);
      expect(
          requestedPermissions('<manifest><uses-permission android:name="android.permission.INTERNET" '
              'android:maxSdkVersion="22"/></manifest>'),
          isEmpty);
    });

    test('reads a declared service by name, and a commented-out one is not declared', () {
      const service = '<service android:name=".CoreService" android:exported="false"\n'
          "    android:foregroundServiceType='location'/>";
      expect(serviceAttributes('<application>$service</application>', '.CoreService'), {
        'android:name': '.CoreService',
        'android:exported': 'false',
        'android:foregroundServiceType': 'location',
      });
      expect(serviceAttributes('<application><!-- $service --></application>', '.CoreService'), isNull);
      expect(serviceAttributes('<application>$service</application>', '.Other'), isNull);
    });
  });

  test('the main manifest requests INTERNET and ACCESS_NETWORK_STATE (#46)', () {
    final requested =
        requestedPermissions(File('android/app/src/main/AndroidManifest.xml').readAsStringSync());
    expect(requested, contains('android.permission.VIBRATE'),
        reason: 'the read must reach the permissions the manifest already requests');
    expect(requested, containsAll(networkPermissions),
        reason: 'a release build has only the main manifest\'s permissions (ADR 006 decision 5)');
  });

  test('the main manifest requests ACCESS_FINE_LOCATION and ACCESS_COARSE_LOCATION (#31)', () {
    final requested =
        requestedPermissions(File('android/app/src/main/AndroidManifest.xml').readAsStringSync());
    expect(requested, contains('android.permission.VIBRATE'),
        reason: 'the read must reach the permissions the manifest already requests');
    expect(requested, containsAll(locationPermissions),
        reason: 'without them a release build can never read where an event happened; a plugin that '
            'declares them would keep the merged manifest green while main lost them');
    expect(requested, isNot(contains('android.permission.ACCESS_BACKGROUND_LOCATION')),
        reason: 'nothing reads location from the background (ADR 003)');
  });

  test('the main manifest requests what the core host needs: FOREGROUND_SERVICE, its location type '
      'and POST_NOTIFICATIONS (#32)', () {
    final requested =
        requestedPermissions(File('android/app/src/main/AndroidManifest.xml').readAsStringSync());
    expect(requested, contains('android.permission.VIBRATE'),
        reason: 'the read must reach the permissions the manifest already requests');
    expect(requested, containsAll(coreHostPermissions),
        reason: 'a release build has only the main manifest\'s permissions, and without these the core '
            'cannot outlive the UI or say that it is logging (ADR 003)');
  });

  test('the main manifest declares the core host: an unexported location service (#32)', () {
    final service = serviceAttributes(
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync(), '.CoreService');
    expect(service, isNotNull, reason: 'no <service android:name=".CoreService">');
    expect(service!['android:foregroundServiceType']?.split('|'), contains('location'),
        reason: 'startForeground with the location type is refused unless the manifest declares it');
    expect(service['android:exported'], 'false',
        reason: 'only the app itself may start or append to the core');
  });
}
