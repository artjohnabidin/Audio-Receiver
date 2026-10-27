import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Subprotocol that lets clients publish to groups directly through Web PubSub.
const webPubSubJsonProtocol = 'json.webpubsub.azure.v1';

enum StreamControlAction { pause, resume, stop }

enum BroadcasterStreamState { unknown, live, paused, stopped }

abstract interface class StreamControlSocket {
  Stream<String> get messages;
  void send(String data);
  Future<void> close();
}

typedef StreamControlSocketConnector = Future<StreamControlSocket> Function(
  Uri url,
);

class StreamControlChannel {
  StreamControlChannel({
    required this.eventId,
    required this.negotiateUrl,
    required this.httpClient,
    required this.fetchIdToken,
    required this.fetchUserId,
    required this.connectSocket,
    this.ackTimeout = const Duration(seconds: 10),
  });

  final String eventId;
  final String negotiateUrl;
  final http.Client httpClient;
  final Future<String> Function() fetchIdToken;
  final Future<String> Function() fetchUserId;
  final StreamControlSocketConnector connectSocket;
  final Duration ackTimeout;

  final connected = ValueNotifier(false);
  final broadcasterState = ValueNotifier(BroadcasterStreamState.unknown);
  final error = ValueNotifier<String?>(null);

  final Map<int, Completer<void>> _pendingAcks = {};
  StreamControlSocket? _socket;
  StreamSubscription<String>? _subscription;
  Timer? _reconnectTimer;
  String? _group;
  int _nextAckId = 1;
  int _reconnectAttempt = 0;
  bool _closed = false;

  Future<void> connect() async {
    _closed = false;
    await _open();
  }

  Future<void> send(StreamControlAction action) async {
    final group = _group;
    if (_socket == null || group == null || !connected.value) {
      throw StateError('Stream control is not connected.');
    }
    await _sendWithAck({
      'type': 'sendToGroup',
      'group': group,
      'noEcho': true,
      'dataType': 'json',
      'data': {
        'kind': 'stream-control',
        'version': 1,
        'action': action.name,
        'eventId': eventId,
        'source': 'listener',
        'sentAt': DateTime.now().toUtc().toIso8601String(),
      },
    });
    if (!_closed) broadcasterState.value = _stateFor(action);
  }

  Future<void> _sendWithAck(Map<String, Object?> frame) async {
    final socket = _socket;
    if (socket == null) throw StateError('Stream control is not connected.');
    final ackId = _nextAckId++;
    final ack = Completer<void>();
    _pendingAcks[ackId] = ack;
    socket.send(jsonEncode({...frame, 'ackId': ackId}));
    try {
      await ack.future.timeout(ackTimeout);
    } on TimeoutException {
      throw StateError('Stream control ${frame['type']} was not acknowledged.');
    } finally {
      _pendingAcks.remove(ackId);
    }
  }

  Future<void> close() async {
    _closed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _closeSocket();
  }

  Future<void> _open() async {
    final url = await _negotiate();
    if (_closed) return;
    final socket = await connectSocket(url);
    if (_closed) {
      await socket.close();
      return;
    }
    _socket = socket;
    _subscription = socket.messages.listen(
      _handleMessage,
      onDone: _handleSocketClosed,
      onError: (Object _) => _handleSocketClosed(),
      cancelOnError: true,
    );
    try {
      await _sendWithAck({'type': 'joinGroup', 'group': _group});
    } catch (_) {
      await _closeSocket();
      rethrow;
    }
    _reconnectAttempt = 0;
    error.value = null;
    connected.value = true;
  }

  Future<Uri> _negotiate() async {
    final base = Uri.parse(negotiateUrl);
    if (!base.hasAuthority ||
        (base.scheme != 'https' &&
            base.host != 'localhost' &&
            base.host != '127.0.0.1')) {
      throw StateError('STREAM_CONTROL_NEGOTIATE_URL must be HTTPS.');
    }
    final userId = await fetchUserId();
    if (userId.isEmpty) throw StateError('Microsoft user id is missing.');
    final uri = base.replace(queryParameters: {
      ...base.queryParameters,
      'userId': userId,
      'eventId': eventId,
    });
    final http.Response response;
    try {
      response = await httpClient.get(uri, headers: {
        'Accept': 'application/json',
        'Authorization': 'Bearer ${await fetchIdToken()}',
      }).timeout(const Duration(seconds: 30));
    } on http.ClientException {
      throw StateError('Cannot reach the stream control service.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Stream control negotiation failed (HTTP ${response.statusCode}).',
      );
    }
    final body = jsonDecode(response.body);
    final url = body is Map<String, dynamic> && body['url'] is String
        ? Uri.tryParse(body['url'] as String)
        : null;
    final group = body is Map<String, dynamic> && body['group'] is String
        ? body['group'] as String
        : 'event.$eventId';
    if (url == null ||
        !(url.scheme == 'wss' ||
            (url.scheme == 'ws' && url.host == 'localhost')) ||
        group.isEmpty) {
      throw const FormatException('Invalid stream control negotiation.');
    }
    _group = group;
    return url;
  }

  void _handleMessage(String raw) {
    final Object? message;
    try {
      message = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (message is! Map<String, dynamic>) return;
    switch (message['type']) {
      case 'ack':
        final ack = _pendingAcks[message['ackId']];
        if (ack == null || ack.isCompleted) return;
        final failure = message['error'];
        if (message['success'] == true ||
            (failure is Map && failure['name'] == 'Duplicate')) {
          ack.complete();
        } else {
          ack.completeError(StateError(
            'Stream control command failed: '
            '${failure is Map ? failure['message'] ?? failure['name'] : 'unknown'}',
          ));
        }
      case 'message':
        final data = message['data'];
        if (message['group'] != _group ||
            data is! Map<String, dynamic> ||
            data['kind'] != 'stream-control' ||
            (data['source'] != 'broadcaster' && data['source'] != 'listener') ||
            data['eventId'] != eventId) {
          return;
        }
        if (data['action'] == 'start') {
          broadcasterState.value = BroadcasterStreamState.live;
          return;
        }
        final action = StreamControlAction.values
            .where((value) => value.name == data['action'])
            .firstOrNull;
        if (action != null) broadcasterState.value = _stateFor(action);
    }
  }

  void _handleSocketClosed() {
    _socket = null;
    _subscription = null;
    connected.value = false;
    _failPendingAcks();
    if (_closed) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    final delay = Duration(seconds: min(30, 1 << min(_reconnectAttempt, 5)));
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () async {
      try {
        await _open();
      } catch (reconnectError) {
        if (_closed) return;
        error.value = 'Stream control reconnect failed: $reconnectError';
        _scheduleReconnect();
      }
    });
  }

  Future<void> _closeSocket() async {
    final socket = _socket;
    final subscription = _subscription;
    _socket = null;
    _subscription = null;
    connected.value = false;
    _failPendingAcks();
    await subscription?.cancel();
    await socket?.close();
  }

  void _failPendingAcks() {
    for (final ack in _pendingAcks.values) {
      if (!ack.isCompleted) {
        ack.completeError(StateError('Stream control disconnected.'));
      }
    }
    _pendingAcks.clear();
  }

  static BroadcasterStreamState _stateFor(StreamControlAction action) =>
      switch (action) {
        StreamControlAction.pause => BroadcasterStreamState.paused,
        StreamControlAction.resume => BroadcasterStreamState.live,
        StreamControlAction.stop => BroadcasterStreamState.stopped,
      };
}
