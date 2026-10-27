@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:audio_receiver/stream_control.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeSocket implements StreamControlSocket {
  final incoming = StreamController<String>();
  final sent = <Map<String, dynamic>>[];
  bool closed = false;

  @override
  Stream<String> get messages => incoming.stream;

  @override
  void send(String data) {
    final frame = jsonDecode(data) as Map<String, dynamic>;
    sent.add(frame);
    if (frame['type'] == 'joinGroup') {
      scheduleMicrotask(() => ack(frame['ackId'] as int, success: joinSucceeds));
    }
  }

  bool joinSucceeds = true;

  @override
  Future<void> close() async {
    closed = true;
    await incoming.close();
  }

  void ack(int id, {bool success = true}) => incoming.add(jsonEncode({
        'type': 'ack',
        'ackId': id,
        'success': success,
        if (!success) 'error': {'name': 'Forbidden', 'message': 'denied'},
      }));
}

void main() {
  late _FakeSocket socket;
  late http.Request negotiateRequest;
  Uri? connectedUrl;

  StreamControlChannel makeChannel() => StreamControlChannel(
        eventId: 'event-1',
        negotiateUrl: 'https://func.example.com/api/negotiate',
        httpClient: MockClient((request) async {
          negotiateRequest = request;
          return http.Response(
            jsonEncode({
              'url': 'wss://pubsub.example.com/client/hubs/streamcontrol?access_token=t',
            }),
            200,
          );
        }),
        fetchIdToken: () async => 'id-token',
        fetchUserId: () async => 'microsoft-oid',
        connectSocket: (url) async {
          connectedUrl = url;
          return socket;
        },
        ackTimeout: const Duration(milliseconds: 200),
      );

  setUp(() => socket = _FakeSocket());

  test('negotiates with the Microsoft user id and joins the event group', () async {
    final channel = makeChannel();
    await channel.connect();

    expect(negotiateRequest.url.queryParameters, {'userId': 'microsoft-oid', 'eventId': 'event-1'});
    expect(negotiateRequest.headers['Authorization'], 'Bearer id-token');
    expect(connectedUrl.toString(), startsWith('wss://pubsub.example.com/'));
    expect(socket.sent.single, containsPair('type', 'joinGroup'));
    expect(socket.sent.single, containsPair('group', 'event.event-1'));
    expect(channel.connected.value, isTrue);
    await channel.close();
  });

  test('fails to connect when the group join is rejected', () async {
    socket.joinSucceeds = false;
    final channel = makeChannel();
    await expectLater(channel.connect(), throwsStateError);
    expect(channel.connected.value, isFalse);
    expect(socket.closed, isTrue);
  });

  test('publishes pause to the event group and waits for ack', () async {
    final channel = makeChannel();
    await channel.connect();

    final sending = channel.send(StreamControlAction.pause);
    await Future<void>.delayed(Duration.zero);
    final frame = socket.sent.last;
    expect(frame['type'], 'sendToGroup');
    expect(frame['group'], 'event.event-1');
    expect(frame['noEcho'], isTrue);
    expect(frame['data'], containsPair('action', 'pause'));
    expect(frame['data'], containsPair('source', 'listener'));
    socket.ack(frame['ackId'] as int);
    await sending;

    expect(channel.broadcasterState.value, BroadcasterStreamState.paused);
    await channel.close();
  });

  test('surfaces rejected commands', () async {
    final channel = makeChannel();
    await channel.connect();

    final sending = channel.send(StreamControlAction.stop);
    await Future<void>.delayed(Duration.zero);
    socket.ack(socket.sent.last['ackId'] as int, success: false);

    await expectLater(sending, throwsStateError);
    expect(channel.broadcasterState.value, BroadcasterStreamState.unknown);
    await channel.close();
  });

  test('reflects broadcaster and other listener commands only', () async {
    final channel = makeChannel();
    await channel.connect();

    void deliver(String action, {String source = 'broadcaster', String eventId = 'event-1'}) {
      socket.incoming.add(jsonEncode({
        'type': 'message',
        'from': 'group',
        'group': 'event.event-1',
        'dataType': 'json',
        'data': {
          'kind': 'stream-control',
          'action': action,
          'eventId': eventId,
          'source': source,
        },
      }));
    }

    deliver('pause');
    await Future<void>.delayed(Duration.zero);
    expect(channel.broadcasterState.value, BroadcasterStreamState.paused);

    deliver('stop', source: 'unknown');
    deliver('stop', eventId: 'event-2');
    await Future<void>.delayed(Duration.zero);
    expect(channel.broadcasterState.value, BroadcasterStreamState.paused);

    deliver('resume', source: 'listener');
    await Future<void>.delayed(Duration.zero);
    expect(channel.broadcasterState.value, BroadcasterStreamState.live);

    deliver('stop');
    await Future<void>.delayed(Duration.zero);
    expect(channel.broadcasterState.value, BroadcasterStreamState.stopped);

    deliver('start');
    await Future<void>.delayed(Duration.zero);
    expect(channel.broadcasterState.value, BroadcasterStreamState.live);
    await channel.close();
  });

  test('rejects sending while disconnected', () async {
    final channel = makeChannel();
    await expectLater(channel.send(StreamControlAction.pause), throwsStateError);
  });
}
