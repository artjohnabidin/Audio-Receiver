import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:audio_receiver/signaling_protocol.dart';

void main() {
  test('listener discovery omits the unknown broadcaster session ID', () {
    const discovery = SignalingMessage(
      type: SignalingMessageType.join,
      roomId: 'event-4',
      senderId: 'listener-1',
      role: 'listener',
    );
    expect(discovery.toJson().containsKey('sessionID'), isFalse);
    expect(SignalingMessage.fromJson(discovery.toJson()).sessionId, isNull);
    expect(
      () => SignalingMessage.fromJson({
        ...discovery.toJson(),
        'role': 'broadcaster',
      }),
      throwsFormatException,
    );
  });

  const message = SignalingMessage(
    type: SignalingMessageType.candidate,
    roomId: 'event-4',
    sessionId: 'session-1',
    senderId: 'sender-1',
    role: 'broadcaster',
    recipientId: 'listener-1',
    candidate: 'candidate:1 1 UDP 123 192.0.2.1 5000 typ host',
    sdpMid: '0',
    sdpMLineIndex: 0,
  );

  test('encodes Swift-compatible wire keys and decodes the message', () {
    final json = message.toJson();

    expect(json['type'], 'candidate');
    expect(json['roomID'], 'event-4');
    expect(json['sessionID'], 'session-1');
    expect(json['senderID'], 'sender-1');
    expect(json['recipientID'], 'listener-1');
    expect(json['candidate'], startsWith('candidate:'));
    expect(SignalingMessage.fromJson(json).toJson(), json);
  });

  test(
    'SDK broadcast metadata cannot overwrite the signaling message type',
    () {
      final envelope = message.toBroadcastPayload();
      expect(envelope.keys, ['payload']);
      envelope['type'] = 'broadcast';
      envelope['event'] = 'webrtc-signal';

      expect((envelope['payload'] as Map)['type'], 'candidate');
      final decoded = SignalingMessage.fromRealtimeEnvelope(
        envelope,
        event: 'webrtc-signal',
      );
      expect(decoded.toJson(), message.toJson());
    },
  );

  test('decodes Swift signaling errors from the message field', () {
    final decoded = SignalingMessage.fromJson({
      'type': 'error',
      'roomID': 'event-4',
      'sessionID': 'session-1',
      'senderID': 'broadcaster-1',
      'role': 'broadcaster',
      'recipientID': 'listener-1',
      'message': 'Connection rejected',
    });
    expect(decoded.error, 'Connection rejected');
    expect(decoded.toJson()['message'], 'Connection rejected');
  });

  test('decodes application payload inside Realtime broadcast envelope', () {
    final decoded = SignalingMessage.fromRealtimeEnvelope({
      'type': 'broadcast',
      'event': 'webrtc-signal',
      'payload': message.toJson(),
    }, event: 'webrtc-signal');

    expect(decoded.toJson(), message.toJson());
  });

  test(
    'decodes a JSON-string payload without treating envelope type as DTO',
    () {
      final decoded = SignalingMessage.fromRealtimeEnvelope(
        jsonEncode({
          'type': 'broadcast',
          'event': 'webrtc-signal',
          'payload': jsonEncode(message.toJson()),
        }),
        event: 'webrtc-signal',
      );

      expect(decoded.type, SignalingMessageType.candidate);
    },
  );

  test('rejects wrong events and mismatched rooms', () {
    expect(
      () => SignalingMessage.fromRealtimeEnvelope({
        'type': 'broadcast',
        'event': 'other-event',
        'payload': message.toJson(),
      }, event: 'webrtc-signal'),
      throwsFormatException,
    );

    final router = SignalingMessageRouter(
      roomId: 'another-room',
      recipientId: 'listener-1',
    );
    expect(
      router.route(
        message.toJson(),
        event: 'webrtc-signal',
        ownSenderId: 'self',
      ),
      isNull,
    );
  });

  test('rejects answers without SDP and candidates without recipients', () {
    expect(
      () => SignalingMessage.fromJson({
        'type': 'answer',
        'roomID': 'event-4',
        'sessionID': 'session-1',
        'senderID': 'sender-1',
        'role': 'broadcaster',
        'recipientID': 'listener-1',
      }),
      throwsFormatException,
    );
    expect(
      () => SignalingMessage.fromJson({
        'type': 'candidate',
        'roomID': 'event-4',
        'sessionID': 'session-1',
        'senderID': 'sender-1',
        'role': 'broadcaster',
        'candidate': 'candidate:1',
      }),
      throwsFormatException,
    );
  });

  test('routes only eligible recipient messages and suppresses duplicates', () {
    final router = SignalingMessageRouter(
      roomId: 'event-4',
      recipientId: 'listener-1',
    );

    expect(
      router.route(
        message.toJson(),
        event: 'webrtc-signal',
        ownSenderId: 'sender-1',
      ),
      isNull,
    );
    expect(
      router.route(
        {...message.toJson(), 'recipientID': 'other-listener'},
        event: 'webrtc-signal',
        ownSenderId: 'self',
      ),
      isNull,
    );

    expect(
      router.route(
        message.toJson(),
        event: 'webrtc-signal',
        ownSenderId: 'self',
      ),
      isA<SignalingMessage>(),
    );
    expect(
      router.route(
        message.toJson(),
        event: 'webrtc-signal',
        ownSenderId: 'self',
      ),
      isNull,
    );
  });
}
