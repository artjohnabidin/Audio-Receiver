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
  final transcript = ValueNotifier<List<TranscriptEntry>>([]);
  final status = ValueNotifier<String>('Idle');

  final _transcriptEntries = <TranscriptEntry>[];
  TranscriptEntry? _partialTranscript;
  String? _lastRecognizedSpeakerId;
  String? _fallbackSpeakerId;
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
      final onTranscript =
          (JSString text, JSString speakerId, JSBoolean isFinal) {
            _handleTranscript(text.toDart, speakerId.toDart, isFinal.toDart);
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
    _partialTranscript = null;
    _publishTranscript();
    await _stopSpeechTranscription().toDart;
    if (!_disposed) status.value = 'Stopped';
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    transcript.dispose();
    status.dispose();
  }

  void _handleTranscript(String text, String speakerId, bool isFinal) {
    if (_disposed || _stopped) return;
    final cleaned = text.trim();
    final trimmedSpeakerId = speakerId.trim();
    final recognizedSpeakerId =
        trimmedSpeakerId.isEmpty || trimmedSpeakerId.toLowerCase() == 'unknown'
        ? null
        : trimmedSpeakerId;
    if (recognizedSpeakerId != null) {
      _lastRecognizedSpeakerId = recognizedSpeakerId;
    }
    final activePartial = _partialTranscript;
    final resolvedSpeakerId =
        recognizedSpeakerId ??
        activePartial?.speakerId ??
        _lastRecognizedSpeakerId;
    final fallbackSpeakerId = recognizedSpeakerId == null
        ? activePartial?.fallbackSpeakerId ??
              (resolvedSpeakerId == null
                  ? _fallbackSpeakerId ??= 'Guest-1'
                  : null)
        : null;
    if (isFinal) {
      if (cleaned.isNotEmpty) {
        _transcriptEntries.add(
          TranscriptEntry(
            text: cleaned,
            speakerId: resolvedSpeakerId,
            fallbackSpeakerId: fallbackSpeakerId,
            isFinal: true,
          ),
        );
      } else if (activePartial != null &&
          _isSameSpeaker(activePartial, resolvedSpeakerId, fallbackSpeakerId)) {
        _partialTranscript = null;
      }
    } else {
      if (cleaned.isNotEmpty) {
        _partialTranscript = TranscriptEntry(
          text: cleaned,
          speakerId: resolvedSpeakerId,
          fallbackSpeakerId: fallbackSpeakerId,
          isFinal: false,
        );
      } else if (activePartial != null &&
          _isSameSpeaker(activePartial, resolvedSpeakerId, fallbackSpeakerId)) {
        _partialTranscript = null;
      }
    }
    _publishTranscript();
  }

  bool _isSameSpeaker(
    TranscriptEntry entry,
    String? speakerId,
    String? fallbackSpeakerId,
  ) =>
      (speakerId != null &&
          (entry.speakerId == speakerId ||
              entry.fallbackSpeakerId == speakerId)) ||
      (fallbackSpeakerId != null &&
          (entry.speakerId == fallbackSpeakerId ||
              entry.fallbackSpeakerId == fallbackSpeakerId));

  void _publishTranscript() {
    transcript.value = List.unmodifiable(_transcriptEntries);
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

@immutable
class TranscriptEntry {
  const TranscriptEntry({
    required this.text,
    required this.isFinal,
    this.speakerId,
    this.fallbackSpeakerId,
  });

  final String text;
  final String? speakerId;
  final String? fallbackSpeakerId;
  final bool isFinal;

  String get speakerLabel {
    final id = speakerId ?? fallbackSpeakerId ?? 'Guest-1';
    final match = RegExp(r'^Guest-(\d+)$').firstMatch(id);
    return match == null ? id : 'Guest ${match.group(1)}';
  }

  TranscriptEntry get asFinal => TranscriptEntry(
    text: text,
    speakerId: speakerId,
    fallbackSpeakerId: fallbackSpeakerId,
    isFinal: true,
  );
}
