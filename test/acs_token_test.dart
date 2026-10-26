@TestOn('vm')
library;

import 'dart:convert';

import 'package:audio_receiver/acs_token.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  Map<String, dynamic> responseBody() => {
    'userId': '8:acs:test-user',
    'token': 'acs-token',
    'expiresOn': DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
  };

  test('matches Swift GET, Microsoft ID token, and function key headers', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.toString(), 'https://tokens.example/api/acsToken');
      expect(request.headers['Accept'], 'application/json');
      expect(request.headers['Authorization'], 'Bearer microsoft-id-token');
      expect(request.headers['x-functions-key'], 'test-function-key');
      return http.Response(jsonEncode(responseBody()), 200);
    });
    addTearDown(client.close);
    expect(
      await ACSTokenService(
        endpoint: 'https://tokens.example/api/acsToken',
        httpClient: client,
        functionKey: 'test-function-key',
      ).fetchToken('microsoft-id-token'),
      'acs-token',
    );
  });

  test('omits the function key when using an authenticated proxy', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.toString(), 'https://tokens.example/api/acsToken');
      expect(request.headers['Authorization'], 'Bearer microsoft-id-token');
      expect(request.headers.containsKey('x-functions-key'), isFalse);
      return http.Response(jsonEncode(responseBody()), 200);
    });
    addTearDown(client.close);
    expect(
      await ACSTokenService(
        endpoint: 'https://tokens.example/api/acsToken',
        httpClient: client,
        functionKey: '',
      ).fetchToken('microsoft-id-token'),
      'acs-token',
    );
  });

  test('preserves the URL code and authorizes with the sign-in ID token', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.queryParameters['code'], 'test-query-key==');
      expect(request.headers['Authorization'], 'Bearer microsoft-id-token');
      expect(request.headers['Accept'], 'application/json');
      expect(request.headers.containsKey('x-functions-key'), isFalse);
      return http.Response(jsonEncode(responseBody()), 200);
    });
    addTearDown(client.close);
    expect(
      await ACSTokenService(
        endpoint: 'https://tokens.example/api/acsToken?code=test-query-key==',
        httpClient: client,
        functionKey: 'unused-header-key',
      ).fetchToken('microsoft-id-token'),
      'acs-token',
    );
  });

  test('network failures explain CORS without exposing URL credentials', () async {
    final client = MockClient((request) async {
      throw http.ClientException('Failed to fetch', request.url);
    });
    addTearDown(client.close);
    await expectLater(
      ACSTokenService(
        endpoint: 'https://tokens.example/api/acsToken?code=private-key',
        httpClient: client,
      ).fetchToken('microsoft-id-token'),
      throwsA(
        isA<StateError>()
            .having((error) => error.message, 'message', contains('CORS'))
            .having((error) => error.message, 'message', isNot(contains('private-key'))),
      ),
    );
  });

  test('uses ACS_TOKEN_FUNCTION_KEY configuration by default', () async {
    const configuredKey = String.fromEnvironment('ACS_TOKEN_FUNCTION_KEY');
    final client = MockClient((request) async {
      expect(
        request.headers['x-functions-key'],
        configuredKey.isEmpty ? isNull : configuredKey,
      );
      return http.Response(jsonEncode(responseBody()), 200);
    });
    addTearDown(client.close);
    await ACSTokenService(
      endpoint: 'https://tokens.example/api/acsToken',
      httpClient: client,
    ).fetchToken('microsoft-id-token');
  });

  test(
    'rejects unauthorized responses without including sensitive bodies',
    () async {
      final client = MockClient(
        (_) async => http.Response('private server details', 401),
      );
      addTearDown(client.close);
      final service = ACSTokenService(
        endpoint: 'https://tokens.example/api/acsToken',
        httpClient: client,
      );
      await expectLater(
        service.fetchToken('id-token'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'ACS token request failed (HTTP 401).',
          ),
        ),
      );
    },
  );

  test('rejects invalid and expired ACS credentials', () async {
    final bodies = [
      {},
      {...responseBody(), 'token': ''},
      {...responseBody(), 'userId': ''},
      {...responseBody(), 'expiresOn': 'invalid'},
      {...responseBody(), 'expiresOn': '2020-01-01T00:00:00Z'},
    ];
    for (final body in bodies) {
      final client = MockClient(
        (_) async => http.Response(jsonEncode(body), 200),
      );
      addTearDown(client.close);
      await expectLater(
        ACSTokenService(
          endpoint: 'https://tokens.example/api/acsToken',
          httpClient: client,
        ).fetchToken('id-token'),
        throwsFormatException,
      );
    }
  });

  test(
    'does not send credentials to an insecure endpoint or without sign-in',
    () async {
      final client = MockClient((_) async => fail('No HTTP request expected'));
      addTearDown(client.close);
      await expectLater(
        ACSTokenService(
          endpoint: 'http://tokens.example/api/acsToken',
          httpClient: client,
        ).fetchToken('id-token'),
        throwsStateError,
      );
      await expectLater(
        ACSTokenService(
          endpoint: 'https://tokens.example/api/acsToken',
          httpClient: client,
        ).fetchToken(''),
        throwsStateError,
      );
    },
  );
}
