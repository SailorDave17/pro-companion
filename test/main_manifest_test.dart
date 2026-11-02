import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #46: a release build is allowed onto the network, so sync can run at all (ADR 006 decision 5).
///
/// A release build has only the main manifest's permissions. The debug and profile manifests add
/// INTERNET for the Flutter tool, so the debug APK CI builds would show INTERNET whatever the main
/// manifest says. This reads the main manifest itself, in every `flutter test` run, with nothing
/// built. scripts/check_release_signing.sh holds the release APK it builds to the same two, which is
/// the merged release manifest. #31 holds both to the two location permissions the same way, and #32
/// to the core host's three. #33 holds the exported surface here, which the same script holds the
/// release APK's link service to.

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

/// #33: the package LinkTrust reads the signer of. ADR 004 keeps the `<queries>` declaration, since
/// whether a caller is visible without it was not measured.
const raceTimerPackage = 'io.github.sailordave17.racetimer';

final _comment = RegExp(r'<!--[\s\S]*?-->');
final _application = RegExp(r'<application\b[\s\S]*?</application>');
final _usesPermission = RegExp(r'<uses-permission\s([^>]*)>');
final _name = RegExp(r'''android:name\s*=\s*["']([^"']+)["']''');
final _removed = RegExp(r'''tools:node\s*=\s*["']remove(All)?["']''');
final _service = RegExp(r'<service\b([^>]*)>');
final _attribute = RegExp(r'''([\w:]+)\s*=\s*["']([^"']*)["']''');
final _exportable = RegExp(r'<(?:service|receiver|provider)\b([^>]*)>');
final _queries = RegExp(r'<queries\b[\s\S]*?</queries>');
final _package = RegExp(r'<package\b([^>]*)>');

/// #32: the attributes of the `<service>` named [name] in [manifest], or null when it declares
/// none. A commented-out element is not declared.
Map<String, String>? serviceAttributes(String manifest, String name) {
  for (final element in _service.allMatches(manifest.replaceAll(_comment, ''))) {
    final attributes = {for (final a in _attribute.allMatches(element.group(1)!)) a.group(1)!: a.group(2)!};
    if (attributes['android:name'] == name) return attributes;
  }
  return null;
}

/// #33: the services, receivers and providers [manifest] exports, by name. ADR 003 counts any of
/// them as a way in. An activity is not here: MainActivity has to be exported for the launcher, and
/// ADR 003 sets it apart because an activity start puts the app in the foreground.
Set<String> exportedComponents(String manifest) {
  final names = <String>{};
  for (final element in _exportable.allMatches(manifest.replaceAll(_comment, ''))) {
    final attributes = {for (final a in _attribute.allMatches(element.group(1)!)) a.group(1)!: a.group(2)!};
    if (attributes['android:exported'] == 'true') names.add(attributes['android:name']!);
  }
  return names;
}

/// #33: the packages [manifest] names in `<queries>`. A `<package>` commented out is not one, and an
/// `<intent>` beside it names none.
Set<String> queriedPackages(String manifest) {
  final names = <String>{};
  for (final queries in _queries.allMatches(manifest.replaceAll(_comment, ''))) {
    for (final element in _package.allMatches(queries.group(0)!)) {
      final name = _name.firstMatch(element.group(1)!)?.group(1);
      if (name != null) names.add(name);
    }
  }
  return names;
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

    test('reads every exported service, receiver and provider, and nothing else', () {
      const manifest = '<application>'
          '<activity android:name=".Screen" android:exported="true"/>'
          '<service android:name=".Open" android:exported="true"/>'
          '<service android:name=".Closed" android:exported="false"/>'
          '<service android:name=".Silent"/>'
          "<receiver android:exported='true' android:name='.Heard'/>"
          '<provider android:name=".Shared"\n    android:exported="true"/>'
          '<!-- <service android:name=".Gone" android:exported="true"/> -->'
          '</application>';
      expect(exportedComponents(manifest), {'.Open', '.Heard', '.Shared'});
    });

    test('reads a queried package, and neither a comment nor an intent is one', () {
      const manifest = '<manifest><queries>'
          '<intent><action android:name="android.intent.action.PROCESS_TEXT"/></intent>'
          '<package android:name="a.queried.app"/>'
          '<!-- <package android:name="a.commented.app"/> -->'
          '</queries></manifest>';
      expect(queriedPackages(manifest), {'a.queried.app'});
      expect(queriedPackages('<manifest><package android:name="outside.queries"/></manifest>'), isEmpty);
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

  test('the main manifest declares the race-timer link: exported, unguarded, in-process (#33)', () {
    final service = serviceAttributes(
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync(), '.LinkService');
    expect(service, isNotNull, reason: 'no <service android:name=".LinkService">');
    expect(service!['android:exported'], 'true',
        reason: 'race-timer binds it by name from another app');
    expect(service, isNot(contains('android:permission')),
        reason: 'a signature permission refuses race-timer on a real phone, where the two apps carry '
            'different keys (ADR 004), and says nothing; LinkTrust judges every call instead');
    expect(service, isNot(contains('android:process')),
        reason: 'it reaches the core by living in the core\'s process (ADR 004)');
  });

  test("the main manifest declares race-timer's package in <queries> (#33)", () {
    expect(queriedPackages(File('android/app/src/main/AndroidManifest.xml').readAsStringSync()),
        contains(raceTimerPackage),
        reason: 'LinkTrust reads this package\'s signer, and ADR 004 keeps the declaration');
  });

  test('the only service, receiver or provider the main manifest exports is .LinkService (#33)', () {
    expect(exportedComponents(File('android/app/src/main/AndroidManifest.xml').readAsStringSync()),
        {'.LinkService'},
        reason: 'ADR 003 counts any exported component as a way in, and only this one judges its '
            'caller');
  });
}
