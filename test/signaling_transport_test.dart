@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_receiver/signaling.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
    'real Supabase SDK preserves nested signaling on the WebSocket',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final captured = Completer<Map<String, dynamic>>();
      var shuttingDown = false;
      final requests = server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((rawFrame) {
          if (shuttingDown) return;
          final decoded = jsonDecode(rawFrame as String);
          final frame = decoded is List
              ? <String, dynamic>{
                  'join_ref': decoded[0],
                  'ref': decoded[1],
                  'topic': decoded[2],
                  'event': decoded[3],
                  'payload': decoded[4],
                }
              : Map<String, dynamic>.from(decoded as Map);
          if (frame['event'] == 'broadcast' && !captured.isCompleted) {
            captured.complete(
              Map<String, dynamic>.from(frame['payload'] as Map),
            );
          }
          final reply = <String, dynamic>{
            'join_ref': frame['join_ref'],
            'ref': frame['ref'],
            'topic': frame['topic'],
            'event': 'phx_reply',
            'payload': {'status': 'ok', 'response': <String, dynamic>{}},
          };
          if (socket.readyState != WebSocket.open) return;
          socket.add(
            jsonEncode(
              decoded is List
                  ? [
                      reply['join_ref'],
                      reply['ref'],
                      reply['topic'],
                      reply['event'],
                      reply['payload'],
                    ]
                  : reply,
            ),
          );
        });
      });
      final client = SupabaseClient(
        'http://127.0.0.1:${server.port}',
        'test-key',
      );
      final signaling = SupabaseSignaling(client: client, roomId: 'event-1');
      addTearDown(() async {
        shuttingDown = true;
        await signaling.dispose();
        await client.dispose();
        for (final socket in sockets) {
          await socket.close();
        }
        await requests.cancel();
        await server.close(force: true);
      });

      await signaling.connect().timeout(const Duration(seconds: 10));
      await signaling
          .send(
            type: SignalingMessageType.candidate,
            sessionId: 'session-1',
            recipientId: 'broadcaster-1',
            candidate: 'candidate:1 1 UDP 123 192.0.2.1 5000 typ host',
            sdpMid: '0',
            sdpMLineIndex: 0,
          )
          .timeout(const Duration(seconds: 10));

      final envelope = await captured.future.timeout(
        const Duration(seconds: 10),
      );
      expect(envelope['type'], 'broadcast');
      expect(envelope['event'], 'webrtc-signal');
      expect(envelope.containsKey('roomID'), isFalse);
      final payload = Map<String, dynamic>.from(envelope['payload'] as Map);
      expect(payload['type'], 'candidate');
      expect(payload['roomID'], 'event-1');
      expect(payload['senderID'], signaling.peerId);
      expect(payload['recipientID'], 'broadcaster-1');
      expect(payload['sdpMLineIndex'], 0);
      expect(
        SignalingMessage.fromRealtimeEnvelope(
          envelope,
          event: 'webrtc-signal',
        ).type,
        SignalingMessageType.candidate,
      );
    },
  );
}
