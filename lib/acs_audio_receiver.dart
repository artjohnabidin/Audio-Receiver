import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

@JS('acsAudioReceiver.create')
external _ACSReceiver _createReceiver(
  JSFunction onState,
  JSFunction onStream,
  JSFunction onError,
);

extension type _ACSReceiver(JSObject _) implements JSObject {
  external JSPromise<JSAny?> start(JSString eventId, JSFunction fetchToken);
  external JSPromise<JSAny?> stop();
  external JSPromise<JSAny?> setPlaybackMuted(JSBoolean muted);
}

enum ReceiverState {
  connecting,
  waitingForBroadcaster,
  connected,
  disconnected,
}

class ACSAudioReceiver {
  ACSAudioReceiver({required this.eventId, required this.fetchToken});

  final String eventId;
  final Future<String> Function() fetchToken;
  final state = ValueNotifier(ReceiverState.disconnected);
  final audioAvailable = ValueNotifier(false);
  final paused = ValueNotifier(false);
  final error = ValueNotifier<String?>(null);

  _ACSReceiver? _receiver;
  web.MediaStream? _stream;
  bool _stopped = false;
  Future<void>? _stopFuture;

  web.MediaStream? get remoteWebStream => _stream;

  Future<void> start() async {
    if (_stopped || _receiver != null) return;
    state.value = ReceiverState.connecting;
    final receiver = _createReceiver(
      ((JSString value) {
        if (_stopped) return;
        state.value = ReceiverState.values.byName(value.toDart);
      }).toJS,
      ((web.MediaStream? stream) {
        if (_stopped || identical(_stream, stream)) return;
        _stream = stream;
        if (audioAvailable.value && stream != null) {
          audioAvailable.value = false;
        }
        audioAvailable.value = stream != null;
      }).toJS,
      ((JSString message) {
        if (!_stopped) error.value = message.toDart;
      }).toJS,
    );
    _receiver = receiver;
    Object? tokenError;
    StackTrace? tokenErrorStack;
    Future<JSString> requestToken() async {
      try {
        return (await fetchToken()).toJS;
      } catch (error, stack) {
        tokenError = error;
        tokenErrorStack = stack;
        rethrow;
      }
    }

    try {
      await receiver
          .start(
            eventId.toJS,
            (() => requestToken().toJS).toJS,
          )
          .toDart;
    } catch (error, stack) {
      await stop();
      Error.throwWithStackTrace(tokenError ?? error, tokenErrorStack ?? stack);
    }
  }

  Future<void> enableAudioPlayback() => resumeStreaming();

  Future<void> pauseStreaming() async {
    await _receiver?.setPlaybackMuted(true.toJS).toDart;
    if (!_stopped) paused.value = true;
  }

  Future<void> resumeStreaming() async {
    await _receiver?.setPlaybackMuted(false.toJS).toDart;
    if (!_stopped) paused.value = false;
  }

  Future<void> stop() => _stopFuture ??= _stop();

  Future<void> _stop() async {
    _stopped = true;
    _stream = null;
    audioAvailable.value = false;
    state.value = ReceiverState.disconnected;
    await _receiver?.stop().toDart;
  }
}
