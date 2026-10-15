import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'signaling_protocol.dart';

export 'signaling_protocol.dart';

class SupabaseSignaling {
  SupabaseSignaling({required this.client, required this.roomId})
    : peerId = _uuidV4(),
      _localSessionId = _uuidV4() {
    _router = SignalingMessageRouter(roomId: roomId, recipientId: peerId);
  }

  static const event = 'webrtc-signal';
  static const role = 'listener';

  final SupabaseClient client;
  final String roomId;
  final String peerId;
  late final SignalingMessageRouter _router;

  String _localSessionId;
  String get localSessionId => _localSessionId;

  RealtimeChannel? _channel;
  Future<void>? _connectFuture;
  bool _hasSubscribed = false;
  bool _isSubscribed = false;
  final _messages = StreamController<SignalingMessage>.broadcast();
  final _readyEvents = StreamController<void>.broadcast();

  Stream<SignalingMessage> get messages => _messages.stream;
  Stream<void> get readyEvents => _readyEvents.stream;

  Future<void> connect() {
    if (_channel != null) return _connectFuture ?? Future.value();

    _log('Connecting channel=webrtc:$roomId peer=$peerId wireFormat=nested-v1');
    final completer = Completer<void>();
    _connectFuture = completer.future;
    _channel = client
        .channel(
          'webrtc:$roomId',
          opts: const RealtimeChannelConfig(
            self: false,
            ack: true,
            private: false,
          ),
        )
        .onBroadcast(
          event: event,
          callback: (envelope) {
            final message = _router.route(
              envelope,
              event: event,
              ownSenderId: peerId,
            );
            if (message == null) {
              _log(
                'Ignored incoming message: invalid, duplicate, or not addressed to this peer',
              );
              return;
            }
            _logMessage('Received', message);
            _messages.add(message);
          },
        )
        .subscribe((status, error) {
          if (_channel == null) return;
          _log(
            'Channel status=${status.name}${error == null ? '' : ' error=$error'}',
          );
          _isSubscribed = status == RealtimeSubscribeStatus.subscribed;
          if (status == RealtimeSubscribeStatus.subscribed) {
            if (_hasSubscribed) {
              _localSessionId = _uuidV4();
              _router.resetDeduplication();
            }
            _hasSubscribed = true;
            _readyEvents.add(null);
            if (!completer.isCompleted) completer.complete();
          } else if (!completer.isCompleted &&
              (status == RealtimeSubscribeStatus.channelError ||
                  status == RealtimeSubscribeStatus.timedOut ||
                  status == RealtimeSubscribeStatus.closed)) {
            completer.completeError(error ?? 'Realtime subscribe $status');
          } else if (_hasSubscribed &&
              status != RealtimeSubscribeStatus.subscribed) {
            _messages.addError(error ?? StateError('Realtime channel $status'));
          }
        });
    return _connectFuture!;
  }

  Future<void> send({
    required SignalingMessageType type,
    String? sessionId,
    String? recipientId,
    String? sdp,
    String? candidate,
    String? sdpMid,
    int? sdpMLineIndex,
    String? error,
  }) async {
    final channel = _channel;
    if (channel == null || !_isSubscribed) {
      _log(
        'Send failed type=${type.value}: signaling channel is not connected',
      );
      throw StateError('Signaling channel is not connected');
    }
    final message = SignalingMessage(
      type: type,
      roomId: roomId,
      sessionId: sessionId,
      senderId: peerId,
      role: role,
      recipientId: recipientId,
      sdp: sdp,
      candidate: candidate,
      sdpMid: sdpMid,
      sdpMLineIndex: sdpMLineIndex,
      error: error,
    );
    final payload = message.toBroadcastPayload();
    _logMessage('Sending', message);
    _log('Outbound envelope wireFormat=nested-v1 ${jsonEncode(payload)}');
    try {
      final response = await channel.sendBroadcastMessage(
        event: event,
        payload: payload,
      );
      if (response != ChannelResponse.ok) {
        throw StateError('Signaling broadcast failed: ${response.name}');
      }
      _logMessage('Sent', message);
    } catch (error) {
      _log(
        'Send failed type=${type.value} session=${sessionId ?? 'none'} '
        'recipient=${recipientId ?? 'broadcast'} error=$error',
      );
      rethrow;
    }
  }

  Future<void> dispose() async {
    _log('Disconnecting channel=webrtc:$roomId peer=$peerId');
    final channel = _channel;
    _channel = null;
    _isSubscribed = false;
    _connectFuture = null;
    if (channel != null) await client.removeChannel(channel);
    await _messages.close();
    await _readyEvents.close();
  }

  void _logMessage(String direction, SignalingMessage message) {
    if (!kDebugMode) return;
    _log(
      '$direction event=$event type=${message.type.value} '
      'session=${message.sessionId ?? 'none'} '
      'sender=${message.senderId} '
      'recipient=${message.recipientId ?? 'broadcast'} '
      'payload=${jsonEncode(message.toJson())}',
    );
  }

  void _log(String message) {
    if (!kDebugMode) return;
    debugPrint(
      '[Signaling][${DateTime.now().toUtc().toIso8601String()}] '
      'room=$roomId $message',
    );
  }

  static String _uuidV4() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}'
        '-${h.substring(16, 20)}-${h.substring(20)}';
  }
}
