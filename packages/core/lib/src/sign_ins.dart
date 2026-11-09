import 'wire.dart';

/// The app's own address, which a magic link sends the phone back to (#104).
///
/// The phone asks for the link with this as its redirect, and the server's
/// verify step sends the browser here with a one-time code (PKCE, owner
/// decision at #104's pickup). The app's main manifest declares it as a
/// `VIEW` intent, `test/main_manifest_test.dart` holds the two to each other,
/// and a server must list it among its allowed redirects: the local stack's
/// `supabase/config.toml` does, and the live project's is held story R38.
const signInRedirect = 'procompanion://sign-in';

/// What a core's host wires magic-link sign-in to (#104), as `join` is wired
/// to a `JoinHandler`: in the app that is sync, in the core host's engine
/// (#113); the core itself makes no network call. Each throws a
/// [CoreException] coded from [SignInCodes] for anything the screen must tell
/// apart.
class SignInHandlers {
  const SignInHandlers({required this.requestLink, required this.completeLink});

  /// Asks the server to mail a magic link to the email address it is given,
  /// redirecting to [signInRedirect]. Completes once the server has taken the
  /// request.
  final Future<void> Function(String email) requestLink;

  /// Exchanges the one-time code a magic link brought back for the
  /// volunteer's own session, and answers with the account's email address.
  final Future<String> Function(String code) completeLink;
}

/// The codes a [CoreException] from a sign-in carries (#104), beside the
/// core's own `refused`, `invalid` and `failed`. The screen reads the code,
/// never the message, to decide what to do next.
abstract final class SignInCodes {
  /// The server judged the request or the link and said no: an address it
  /// will not mail, or a link that has expired, was used already, or was
  /// opened on another phone than the one that asked for it. The message is
  /// one plain sentence for the volunteer.
  static const refused = 'sign_in_refused';

  /// The phone already holds a session. Signing in again over it would leave
  /// the events written under it with an admission nobody holds, so the phone
  /// keeps the session it has.
  static const signedIn = 'signed_in';

  /// The server could not be reached. The screen keeps what was typed and
  /// tries again.
  static const noSignal = 'no_signal';

  /// This core has nothing to sign in through: no sync engine is wired to it.
  /// On a phone that is a build without a server (#113 wires it).
  static const noServer = 'no_server';

  /// A sign-in that could not be made and the server did not judge: a rate
  /// limit, or an answer nobody expected.
  static const failed = 'sign_in_failed';

  static const all = {refused, signedIn, noSignal, noServer, failed};
}

/// A sign-in the core could not make, as [CoreException]s come back over the
/// port: one of [SignInCodes.all] and a sentence.
CoreException signInException(String code, String message) {
  if (!SignInCodes.all.contains(code)) throw ArgumentError.value(code, 'code', 'is not a sign-in code');
  return CoreException(code, message);
}

/// What a magic link handed the app when it opened it at [signInRedirect]
/// (#104): the one-time [code] to exchange, or the error the server's verify
/// step sent instead.
class SignInLink {
  const SignInLink._({this.code, this.errorCode, this.errorDescription});

  /// The one-time code the server's verify step issued, or null when it sent
  /// an error.
  final String? code;

  /// The server's `error_code` (such as `otp_expired`), else its `error`, when
  /// it sent an error. Null when [code] is set.
  final String? errorCode;

  /// The server's own description of the error, for a log, never for the
  /// screen.
  final String? errorDescription;

  bool get isError => code == null;

  /// Reads [uri] as the address a magic link opened, or answers null when it
  /// is not [signInRedirect] at all. The code and the error are read from the
  /// query and from the fragment both, since the server's verify step sends
  /// an error in whichever its flow uses. An address at [signInRedirect] that
  /// carries neither is an error of its own (`no_code`).
  static SignInLink? parse(String uri) {
    final Uri parsed;
    try {
      parsed = Uri.parse(uri);
    } on FormatException {
      return null;
    }
    final expected = Uri.parse(signInRedirect);
    if (parsed.scheme != expected.scheme || parsed.host != expected.host) return null;
    if (parsed.path.isNotEmpty && parsed.path != '/') return null;
    final params = <String, String>{
      ...parsed.queryParameters,
      if (parsed.hasFragment) ..._fragmentParameters(parsed.fragment),
    };
    final code = params['code'];
    final error = params['error_code'] ?? params['error'];
    if (error != null && error.isNotEmpty) {
      return SignInLink._(errorCode: error, errorDescription: params['error_description']);
    }
    if (code != null && code.isNotEmpty) return SignInLink._(code: code);
    return const SignInLink._(errorCode: 'no_code');
  }

  static Map<String, String> _fragmentParameters(String fragment) {
    try {
      return Uri.splitQueryString(fragment);
    } on FormatException {
      return const {};
    }
  }

  @override
  String toString() => isError ? 'SignInLink(error $errorCode)' : 'SignInLink(code)';
}
