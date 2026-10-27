import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'stream_control.dart';

class BrowserStreamControlSocket implements StreamControlSocket {
  BrowserStreamControlSocket._(this._socket, this._messages);

  final web.WebSocket _socket;
  final StreamController<String> _messages;

  static Future<StreamControlSocket> connect(Uri url) async {
    final socket = web.WebSocket(url.toString(), webPubSubJsonProtocol.toJS);
    final messages = StreamController<String>();
    final opened = Completer<void>();

    socket.onopen = ((web.Event _) {
      if (!opened.isCompleted) opened.complete();
    }).toJS;
    socket.onmessage = ((web.MessageEvent event) {
      final data = event.data.dartify();
      if (data is String && !messages.isClosed) messages.add(data);
    }).toJS;
    socket.onclose = ((web.CloseEvent _) {
      if (!opened.isCompleted) {
        opened.completeError(StateError('Stream control connection was refused.'));
      }
      if (!messages.isClosed) messages.close();
    }).toJS;

    try {
      await opened.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      socket.close();
      rethrow;
    }
    return BrowserStreamControlSocket._(socket, messages);
  }

  @override
  Stream<String> get messages => _messages.stream;

  @override
  void send(String data) => _socket.send(data.toJS);

  @override
  Future<void> close() async {
    _socket.close();
    if (!_messages.isClosed) await _messages.close();
  }
}
