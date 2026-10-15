import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx_web/sherpa_onnx_web.dart';
import 'package:web/web.dart' as web;

@JS('speechTranscriber.start')
external JSPromise<JSAny?> _startSpeechTranscription(
  web.MediaStream stream,
  web.AudioContext audioContext,
  JSFunction onTranscript,
  JSFunction onStatus,
);

@JS('speechTranscriber.stop')
external JSPromise<JSAny?> _stopSpeechTranscription();

class SpeechTranscriber {
  final transcript = ValueNotifier<String>('');
  final status = ValueNotifier<String>('Idle');

  String _finalTranscript = '';
  String _partialTranscript = '';
  bool _stopped = false;
  bool _disposed = false;

  bool get isStopped => _stopped;

  Future<void> start(web.MediaStream stream) async {
    _stopped = false;
    status.value = 'Loading local speech recognition';
    final audioContext = web.AudioContext(
      web.AudioContextOptions(sampleRate: 16000),
    );
    try {
      await audioContext.resume().toDart;
      await SherpaOnnxWeb.loadWasm();
      if (_stopped) {
        await audioContext.close().toDart;
        return;
      }
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
        audioContext,
        onTranscript,
        onStatus,
      ).toDart;
    } catch (error) {
      if (audioContext.state != 'closed') {
        await audioContext.close().toDart;
      }
      if (!_stopped && !_disposed) {
        status.value = 'Transcription failed: $error';
      }
      rethrow;
    }
  }

  Future<void> stop() async {
    _stopped = true;
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
}
