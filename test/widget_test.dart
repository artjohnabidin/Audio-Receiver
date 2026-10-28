// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:web/web.dart' as web;

import 'package:audio_receiver/acs_audio_receiver.dart';
import 'package:audio_receiver/event_detail_page.dart';
import 'package:audio_receiver/event_dto.dart';
import 'package:audio_receiver/main.dart';
import 'package:audio_receiver/speech_token.dart';
import 'package:audio_receiver/stream_control.dart';
import 'package:flutter/material.dart';

class _ControlChannelStub extends StreamControlChannel {
  _ControlChannelStub()
    : super(
        eventId: 'event-1',
        negotiateUrl: 'https://control.example.com',
        httpClient: MockClient((_) async => throw UnimplementedError()),
        fetchIdToken: () async => 'test-token',
        fetchUserId: () async => 'test-user',
        connectSocket: (_) async => throw UnimplementedError(),
      );

  final sent = <StreamControlAction>[];

  @override
  Future<void> connect() async => connected.value = true;

  @override
  Future<void> send(StreamControlAction action) async => sent.add(action);

  @override
  Future<void> close() async => connected.value = false;
}

void main() {
  testWidgets('remote start is enabled while waiting for the broadcaster', (
    tester,
  ) async {
    final control = _ControlChannelStub();
    late JSFunction onState;
    final bridge = JSObject();
    bridge.setProperty(
      'start'.toJS,
      ((JSString eventId, JSFunction fetchToken) {
        return Future<JSAny?>.value().toJS;
      }).toJS,
    );
    bridge.setProperty('stop'.toJS, (() => Future<JSAny?>.value().toJS).toJS);
    final factory = JSObject();
    factory.setProperty(
      'create'.toJS,
      ((JSFunction state, JSFunction audio, JSFunction error) {
        onState = state;
        state.callAsFunction(null, 'waitingForBroadcaster'.toJS);
        return bridge;
      }).toJS,
    );
    globalContext.setProperty('acsAudioReceiver'.toJS, factory);
    addTearDown(() => globalContext.delete('acsAudioReceiver'.toJS));

    await tester.pumpWidget(
      MaterialApp(
        home: EventDetailPage(
          event: events.first,
          createReceiver: () => ACSAudioReceiver(
            eventId: 'event-1',
            fetchToken: () async => 'acs-token',
          ),
          createControlChannel: () => control,
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump(const Duration(milliseconds: 200));

    FilledButton button(String label) =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, label));
    expect(button('Start stream').onPressed, isNotNull);
    expect(button('Pause stream').onPressed, isNull);
    expect(button('Stop stream').onPressed, isNull);
    onState.callAsFunction(null, 'connected'.toJS);
    await tester.pump();
    expect(button('Start stream').onPressed, isNull);
    control.broadcasterState.value = BroadcasterStreamState.stopped;
    await tester.pump();
    expect(button('Start stream').onPressed, isNotNull);
    control.broadcasterState.value = BroadcasterStreamState.unknown;
    await tester.pump();
    expect(button('Start stream').onPressed, isNull);
    onState.callAsFunction(null, 'waitingForBroadcaster'.toJS);
    await tester.pump();
    expect(button('Start stream').onPressed, isNotNull);
    await tester.ensureVisible(find.text('Start stream'));
    await tester.tap(find.text('Start stream'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(control.sent, [StreamControlAction.start]);

    control.broadcasterState.value = BroadcasterStreamState.live;
    await tester.pump();
    expect(button('Start stream').onPressed, isNull);
    control.broadcasterState.value = BroadcasterStreamState.stopped;
    await tester.pump();
    expect(button('Start stream').onPressed, isNotNull);
    control.connected.value = false;
    await tester.pump();
    expect(button('Start stream').onPressed, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  test(
    'ACS bridge forwards the event and token and rejects late callbacks',
    () async {
      late JSFunction onState;
      late JSFunction onStream;
      late JSFunction onError;
      String? joinedEvent;
      String? joinedToken;
      bool? muted;
      var stops = 0;
      final bridge = JSObject();
      bridge.setProperty(
        'start'.toJS,
        ((JSString eventId, JSFunction fetchToken) {
          joinedEvent = eventId.toDart;
          final tokenPromise =
              fetchToken.callAsFunction() as JSPromise<JSString>;
          return tokenPromise.toDart.then<JSAny?>((token) {
            joinedToken = token.toDart;
            onState.callAsFunction(null, 'waitingForBroadcaster'.toJS);
            return null;
          }).toJS;
        }).toJS,
      );
      bridge.setProperty(
        'stop'.toJS,
        (() {
          stops++;
          return Future<JSAny?>.value().toJS;
        }).toJS,
      );
      bridge.setProperty(
        'setPlaybackMuted'.toJS,
        ((JSBoolean value) {
          muted = value.toDart;
          return Future<JSAny?>.value().toJS;
        }).toJS,
      );
      final factory = JSObject();
      factory.setProperty(
        'create'.toJS,
        ((JSFunction state, JSFunction stream, JSFunction error) {
          onState = state;
          onStream = stream;
          onError = error;
          return bridge;
        }).toJS,
      );
      globalContext.setProperty('acsAudioReceiver'.toJS, factory);
      addTearDown(() => globalContext.delete('acsAudioReceiver'.toJS));

      final receiver = ACSAudioReceiver(
        eventId: 'event-1',
        fetchToken: () async => 'acs-token',
      );
      await receiver.start();
      expect(joinedEvent, 'event-1');
      expect(joinedToken, 'acs-token');
      expect(receiver.state.value, ReceiverState.waitingForBroadcaster);
      final stream = web.MediaStream();
      onStream.callAsFunction(null, stream);
      expect(receiver.remoteWebStream, stream);
      expect(receiver.audioAvailable.value, isTrue);
      await receiver.pauseStreaming();
      expect(muted, isTrue);
      expect(receiver.paused.value, isTrue);
      await receiver.enableAudioPlayback();
      expect(muted, isFalse);
      onError.callAsFunction(null, 'refresh failed'.toJS);
      expect(receiver.error.value, 'refresh failed');
      await receiver.stop();
      await receiver.stop();
      expect(stops, 1);
      onState.callAsFunction(null, 'connected'.toJS);
      onStream.callAsFunction(null, stream);
      expect(receiver.state.value, ReceiverState.disconnected);
      expect(receiver.remoteWebStream, isNull);
      expect(receiver.audioAvailable.value, isFalse);
    },
  );

  test('ACS bridge preserves the original token failure', () async {
    var stops = 0;
    final bridge = JSObject();
    bridge.setProperty(
      'start'.toJS,
      ((JSString eventId, JSFunction fetchToken) {
        return fetchToken.callAsFunction() as JSPromise<JSString>;
      }).toJS,
    );
    bridge.setProperty(
      'stop'.toJS,
      (() {
        stops++;
        return Future<JSAny?>.value().toJS;
      }).toJS,
    );
    final factory = JSObject();
    factory.setProperty(
      'create'.toJS,
      ((JSFunction state, JSFunction stream, JSFunction error) => bridge).toJS,
    );
    globalContext.setProperty('acsAudioReceiver'.toJS, factory);
    addTearDown(() => globalContext.delete('acsAudioReceiver'.toJS));
    final failure = StateError('ACS token request failed (HTTP 401).');
    final receiver = ACSAudioReceiver(
      eventId: 'event-1',
      fetchToken: () async => throw failure,
    );
    await expectLater(receiver.start(), throwsA(same(failure)));
    expect(stops, 1);
    expect(receiver.state.value, ReceiverState.disconnected);
  });

  testWidgets('starts STT automatically on the latest incoming ACS audio', (
    tester,
  ) async {
    final firstStream = web.MediaStream();
    final secondStream = web.MediaStream();
    final transcribedStreams = <web.MediaStream>[];
    late JSFunction audioCallback;
    final bridge = JSObject();
    bridge.setProperty(
      'start'.toJS,
      ((JSString eventId, JSFunction fetchToken) {
        audioCallback.callAsFunction(null, firstStream);
        return Future<JSAny?>.value().toJS;
      }).toJS,
    );
    bridge.setProperty('stop'.toJS, (() => Future<JSAny?>.value().toJS).toJS);
    final factory = JSObject();
    factory.setProperty(
      'create'.toJS,
      ((JSFunction state, JSFunction audio, JSFunction error) {
        audioCallback = audio;
        return bridge;
      }).toJS,
    );
    globalContext.setProperty('acsAudioReceiver'.toJS, factory);
    final speech = JSObject();
    speech.setProperty(
      'start'.toJS,
      ((
            web.MediaStream stream,
            JSString token,
            JSString region,
            JSFunction transcript,
            JSFunction status,
          ) {
            transcribedStreams.add(stream);
            transcript.callAsFunction(
              null,
              'Interim phrase'.toJS,
              'Guest-1'.toJS,
              false.toJS,
            );
            transcript.callAsFunction(
              null,
              'Live keynote transcript'.toJS,
              'Guest-1'.toJS,
              true.toJS,
            );
            transcript.callAsFunction(
              null,
              'A second recognized phrase'.toJS,
              'Guest-2'.toJS,
              true.toJS,
            );
            return Future<JSAny?>.value().toJS;
          })
          .toJS,
    );
    speech.setProperty('stop'.toJS, (() => Future<JSAny?>.value().toJS).toJS);
    globalContext.setProperty('azureSpeechTranscriber'.toJS, speech);
    addTearDown(() {
      globalContext.delete('acsAudioReceiver'.toJS);
      globalContext.delete('azureSpeechTranscriber'.toJS);
    });
    final pendingToken = Completer<SpeechToken>();
    final token = SpeechToken(
      token: 'speech-token',
      region: 'japaneast',
      expiresIn: 540,
    );
    var tokenRequests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: EventDetailPage(
          event: events.first,
          createReceiver: () => ACSAudioReceiver(
            eventId: 'event-1',
            fetchToken: () async => 'acs-token',
          ),
          fetchSpeechToken: () =>
              ++tokenRequests == 1 ? pendingToken.future : Future.value(token),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(tokenRequests, 1);
    audioCallback.callAsFunction(null, secondStream);
    pendingToken.complete(token);
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(transcribedStreams, [secondStream]);
    expect(find.text('Live keynote transcript'), findsOneWidget);
    expect(find.text('A second recognized phrase'), findsOneWidget);
    expect(find.text('Interim phrase'), findsNothing);
    expect(find.text('Guest 1'), findsOneWidget);
    expect(find.text('Guest 2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('opens the event list after Microsoft sign-in succeeds', (
    tester,
  ) async {
    await tester.pumpWidget(MyApp(signIn: () async {}));

    expect(find.text('Sign in to continue'), findsOneWidget);
    await tester.tap(find.text('Sign in with Microsoft'));
    await tester.pumpAndSettle();

    expect(find.text('Event Monitoring'), findsOneWidget);
    expect(
      find.textContaining('Missing ACS token service config'),
      findsOneWidget,
    );
  });

  testWidgets('opens the event list when redirect sign-in is complete', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp(initiallySignedIn: true));

    expect(find.text('Event Monitoring'), findsOneWidget);
    expect(
      find.textContaining('Missing ACS token service config'),
      findsOneWidget,
    );
  });

  testWidgets('shows an error when Microsoft sign-in fails', (tester) async {
    await tester.pumpWidget(
      MyApp(signIn: () async => throw StateError('sign-in failed')),
    );

    await tester.tap(find.text('Sign in with Microsoft'));
    await tester.pump();

    expect(find.text('Sign in to continue'), findsOneWidget);
    expect(find.text('Microsoft sign-in failed. Try again.'), findsOneWidget);
  });
}
