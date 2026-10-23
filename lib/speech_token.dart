import 'dart:convert';
import 'package:http/http.dart' as http;

class SpeechToken {
  final String token;
  final String region;
  final int expiresIn;

  SpeechToken({
    required this.token,
    required this.region,
    required this.expiresIn,
  });

  factory SpeechToken.fromJson(Map<String, dynamic> json) {
    final token = json['token'];
    final region = json['region'];
    final expiresIn = json['expiresIn'];

    if (token is! String || token.isEmpty) {
      throw FormatException('Invalid token');
    }
    if (region is! String || region.isEmpty) {
      throw FormatException('Invalid region');
    }
    if (expiresIn is! int || expiresIn <= 0) {
      throw FormatException('Invalid expiresIn');
    }

    return SpeechToken(token: token, region: region, expiresIn: expiresIn);
  }
}

class SpeechTranscriberAuthService {
  final String backendBaseUrl;
  final http.Client httpClient;

  SpeechTranscriberAuthService({
    required this.backendBaseUrl,
    required this.httpClient,
  });

  Future<SpeechToken> fetchToken(String supabaseAccessToken) async {
    final baseUrl = backendBaseUrl.replaceFirst(RegExp(r'/$'), '');
    final uri = Uri.parse('$baseUrl/api/speech/token');
    final res = await httpClient.post(
      uri,
      headers: {
        'Authorization': 'Bearer $supabaseAccessToken',
        'Content-Type': 'application/json',
      },
    );

    if (res.statusCode != 200) {
      throw Exception('Token fetch failed: ${res.statusCode}');
    }

    final body = jsonDecode(res.body);
    if (body is! Map<String, dynamic>) {
      throw FormatException('Unexpected token response format');
    }

    return SpeechToken.fromJson(body);
  }
}
