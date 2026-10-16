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
  web.AudioContext? _audioContext;
  bool _stopped = false;
  bool _disposed = false;

  bool get isStopped => _stopped;

  Future<void> start(web.MediaStream stream) async {
    _stopped = false;
    status.value = 'Loading local speech recognition';
    final audioContext = web.AudioContext(
      web.AudioContextOptions(sampleRate: 16000),
    );
    _audioContext = audioContext;
    try {
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

  Future<void> resumeAudioFromUserGesture() async {
    final audioContext = _audioContext;
    if (audioContext == null ||
        audioContext.state == 'closed' ||
        audioContext.state == 'running') {
      return;
    }
    await audioContext.resume().toDart;
  }

  Future<void> stop() async {
    _stopped = true;
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
}
