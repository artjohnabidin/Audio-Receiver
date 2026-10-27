import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'speech_token.dart';

@JS('azureSpeechTranscriber.start')
external JSPromise<JSAny?> _startSpeechTranscription(
  web.MediaStream stream,
  JSString token,
  JSString region,
  JSFunction onTranscript,
  JSFunction onStatus,
);

@JS('azureSpeechTranscriber.updateToken')
external JSBoolean _updateSpeechToken(JSString token);

@JS('azureSpeechTranscriber.stop')
external JSPromise<JSAny?> _stopSpeechTranscription();

class SpeechTranscriber {
  final transcript = ValueNotifier<String>('');
  final status = ValueNotifier<String>('Idle');

  String _finalTranscript = '';
  String _partialTranscript = '';
  Timer? _tokenRefreshTimer;
  bool _stopped = true;
  bool _disposed = false;

  bool get isStopped => _stopped;

  Future<void> start(
    web.MediaStream stream, {
    required SpeechToken token,
    required Future<SpeechToken> Function() refreshToken,
  }) async {
    _stopped = false;
    status.value = 'Connecting to Azure Speech';
    try {
      final onTranscript = (JSString text, JSBoolean isFinal) {
        _handleTranscript(text.toDart, isFinal.toDart);
      }.toJS;
      final onStatus = (JSString value) {
        if (!_disposed && !_stopped) status.value = value.toDart;
      }.toJS;
      // The WebAssembly package's Dart online recognizer is currently a stub;
      // its JavaScript wrapper provides the streaming API.
      await _startSpeechTranscription(
        stream,
        token.token.toJS,
        token.region.toJS,
        onTranscript,
        onStatus,
      ).toDart;
      _scheduleTokenRefresh(token, refreshToken);
    } catch (error) {
      if (!_stopped && !_disposed) {
        status.value = 'Transcription failed: $error';
      }
      rethrow;
    }
  }

  Future<void> stop() async {
    _stopped = true;
    _tokenRefreshTimer?.cancel();
    _tokenRefreshTimer = null;
    if (_partialTranscript.isNotEmpty) {
      _finalTranscript = _finalTranscript.isEmpty
          ? _partialTranscript
          : '$_finalTranscript\n$_partialTranscript';
      _partialTranscript = '';
      transcript.value = _finalTranscript;
    }
    await _stopSpeechTranscription().toDart;
    if (!_disposed) status.value = 'Stopped';
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    transcript.dispose();
    status.dispose();
  }

  void _handleTranscript(String text, bool isFinal) {
    if (_disposed || _stopped) return;
    final cleaned = text.trim();
    if (isFinal) {
      if (cleaned.isNotEmpty) {
        _finalTranscript = _finalTranscript.isEmpty
            ? cleaned
            : '$_finalTranscript\n$cleaned';
      }
      _partialTranscript = '';
    } else {
      _partialTranscript = cleaned;
    }
    transcript.value = [
      _finalTranscript,
      _partialTranscript,
    ].where((part) => part.isNotEmpty).join('\n');
  }

  void _scheduleTokenRefresh(
    SpeechToken token,
    Future<SpeechToken> Function() refreshToken,
  ) {
    if (_stopped || _disposed) return;
    final refreshInSeconds = token.expiresIn > 60
        ? token.expiresIn - 60
        : (token.expiresIn ~/ 2).clamp(1, token.expiresIn);
    _tokenRefreshTimer = Timer(Duration(seconds: refreshInSeconds), () async {
      if (_stopped || _disposed) return;
      try {
        final refreshedToken = await refreshToken();
        if (_stopped || _disposed) return;
        if (!_updateSpeechToken(refreshedToken.token.toJS).toDart) {
          throw StateError('Azure Speech recognizer is not active');
        }
        _scheduleTokenRefresh(refreshedToken, refreshToken);
      } catch (error) {
        if (!_stopped && !_disposed) {
          status.value = 'Speech authorization refresh failed: $error';
        }
      }
    });
  }
}
