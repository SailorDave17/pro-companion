import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #46: a release build is allowed onto the network, so sync can run at all (ADR 006 decision 5).
///
/// A release build has only the main manifest's permissions. The debug and profile manifests add
/// INTERNET for the Flutter tool, so the debug APK CI builds would show INTERNET whatever the main
/// manifest says. This reads the main manifest itself, in every `flutter test` run, with nothing
/// built. scripts/check_release_signing.sh holds the release APK it builds to the same two, which is
/// the merged release manifest.

const networkPermissions = {
  'android.permission.INTERNET',
  'android.permission.ACCESS_NETWORK_STATE',
};

final _comment = RegExp(r'<!--[\s\S]*?-->');
final _application = RegExp(r'<application\b[\s\S]*?</application>');
final _usesPermission = RegExp(r'<uses-permission\s([^>]*)>');
final _name = RegExp(r'''android:name\s*=\s*["']([^"']+)["']''');
final _removed = RegExp(r'''tools:node\s*=\s*["']remove(All)?["']''');

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
  });

  test('the main manifest requests INTERNET and ACCESS_NETWORK_STATE (#46)', () {
    final requested =
        requestedPermissions(File('android/app/src/main/AndroidManifest.xml').readAsStringSync());
    expect(requested, contains('android.permission.VIBRATE'),
        reason: 'the read must reach the permissions the manifest already requests');
    expect(requested, containsAll(networkPermissions),
        reason: 'a release build has only the main manifest\'s permissions (ADR 006 decision 5)');
  });
}
