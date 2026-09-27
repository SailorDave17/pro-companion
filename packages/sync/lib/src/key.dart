import 'dart:convert';

/// Refuses any key but the project's publishable one, before any request.
///
/// Sync is a client, and service_role is on no client (#6 criteria 5 and 13):
/// a secret key (`sb_secret_...`) or a legacy JWT whose role is service_role
/// would pass every row-level check. This is an allowlist, so a key shape it
/// does not know is refused rather than let through: a publishable key, or a
/// legacy JWT whose role is `anon`. A key with surrounding whitespace is
/// refused too, since a header parser would strip it and send what it wraps.
/// The key itself is never put in the error.
void requirePublishableKey(String key) {
  if (key.isNotEmpty && key == key.trim()) {
    if (key.startsWith('sb_publishable_')) return;
    if (_legacyRole(key) == 'anon') return;
  }
  throw ArgumentError('sync takes the project\'s publishable key and nothing else '
      '(a secret or service_role key is on no client)');
}

String? _legacyRole(String key) {
  final parts = key.split('.');
  if (parts.length != 3) return null;
  try {
    final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    return claims is Map && claims['role'] is String ? claims['role'] as String : null;
  } on FormatException {
    return null;
  }
}
