import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// The transport sync hands its Supabase client, over the one that reaches
/// the network. It does two things the client does not.
///
/// It bounds every request, body included, by [timeout]. The client sets none
/// by default, and a request into a dead link would otherwise hold a run, and
/// the upload behind it, for as long as the link stays dead (#6 criterion 12).
///
/// And it keeps the phone signed in through answers GoTrue never gives. gotrue
/// signs the phone out on any refresh failure it does not count as retryable,
/// and on the device-handoff path a session lost is a new anonymous user who
/// must be admitted again (ADR 006). So an answer on the token endpoint is
/// passed to gotrue only when it is one GoTrue gives: a session, or a 4xx
/// carrying the error code gotrue reads (`error_code`, or `code` with the API
/// version header; measured on the local stack: a revoked refresh token is a
/// 400 `{"code":"refresh_token_not_found"}` with that header). Anything else -
/// a captive portal's page, a gateway's error, a rate limit, a 5xx, an empty
/// body - is turned into a [http.ClientException], which gotrue retries and
/// never signs the phone out over.
class GuardedTransport extends http.BaseClient {
  GuardedTransport(this._inner, {required this.timeout});

  final http.Client _inner;
  final Duration timeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final http.Response response;
    try {
      response = await Future(() async => http.Response.fromStream(await _inner.send(request))).timeout(timeout);
    } on TimeoutException {
      throw http.ClientException('no answer within ${timeout.inMilliseconds} ms', request.url);
    }
    if (request.url.path.endsWith('/auth/v1/token')) _vetToken(response, request.url);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      contentLength: response.bodyBytes.length,
      request: request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  static void _vetToken(http.Response response, Uri url) {
    Object? body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      body = null;
    }
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      if (body is Map && body['access_token'] is String) return;
    } else if (status >= 400 && status < 500 && status != 429 && body is Map) {
      if (body['error_code'] is String) return;
      if (body['code'] is String && response.headers.containsKey('x-supabase-api-version')) return;
    }
    throw http.ClientException('the token endpoint answered $status with something GoTrue does not send', url);
  }

  @override
  void close() => _inner.close();
}
