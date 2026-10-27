import 'dart:convert';

import 'package:http/http.dart' as http;

class ACSTokenService {
  ACSTokenService({
    required this.endpoint,
    required this.httpClient,
    this.functionKey = const String.fromEnvironment('ACS_TOKEN_FUNCTION_KEY'),
  });

  final String endpoint;
  final http.Client httpClient;
  final String functionKey;

  Future<String> fetchToken(String microsoftIdToken) async {
    if (microsoftIdToken.isEmpty) {
      throw StateError('Please sign in with Microsoft again.');
    }
    final uri = Uri.parse(endpoint);
    if (!uri.hasAuthority ||
        (uri.scheme != 'https' &&
            uri.host != 'localhost' &&
            uri.host != '127.0.0.1')) {
      throw StateError('ACS_TOKEN_URL must be an HTTPS token endpoint.');
    }
    final http.Response response;
    try {
      response = await httpClient
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              'Authorization': 'Bearer $microsoftIdToken',
              if (functionKey.isNotEmpty &&
                  (uri.queryParameters['code'] ?? '').isEmpty)
                'x-functions-key': functionKey,
            },
          )
          .timeout(const Duration(seconds: 30));
    } on http.ClientException {
      throw StateError(
        'Cannot reach the ACS token API. Check network access and configure '
        'API CORS to allow the listener origin and Authorization header.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'ACS token request failed (HTTP ${response.statusCode}).',
      );
    }
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic> ||
        body['token'] is! String ||
        (body['token'] as String).isEmpty ||
        body['userId'] is! String ||
        (body['userId'] as String).isEmpty ||
        body['expiresOn'] is! String ||
        DateTime.tryParse(body['expiresOn'] as String) == null) {
      throw const FormatException('Invalid ACS token response.');
    }
    if (!DateTime.parse(body['expiresOn'] as String).isAfter(DateTime.now())) {
      throw const FormatException('ACS token has expired.');
    }
    return body['token'] as String;
  }
}
