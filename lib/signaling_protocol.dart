import 'dart:convert';

enum SignalingMessageType {
  join('join'),
  peerReady('peer-ready'),
  startStreaming('start-streaming'),
  pauseStreaming('pause-streaming'),
  resumeStreaming('resume-streaming'),
  stopStreaming('stop-streaming'),
  offer('offer'),
  answer('answer'),
  candidate('candidate'),
  peerLeft('peer-left'),
  error('error');

  const SignalingMessageType(this.value);

  final String value;

  static SignalingMessageType? fromValue(Object? value) {
    for (final type in values) {
      if (type.value == value) return type;
    }
    return null;
  }
}

class SignalingMessage {
  const SignalingMessage({
    required this.type,
    required this.roomId,
    this.sessionId,
    required this.senderId,
    required this.role,
    this.recipientId,
    this.sdp,
    this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
    this.error,
  });

  final SignalingMessageType type;
  final String roomId;
  final String? sessionId;
  final String senderId;
  final String role;
  final String? recipientId;
  final String? sdp;
  final String? candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;
  final String? error;

  Map<String, dynamic> toBroadcastPayload() => {'payload': toJson()};

  Map<String, dynamic> toJson() {
    _validate();
    return {
      'type': type.value,
      'roomID': roomId,
      if (sessionId != null) 'sessionID': sessionId,
      'senderID': senderId,
      'role': role,
      if (recipientId != null) 'recipientID': recipientId,
      if (sdp != null) 'sdp': sdp,
      if (candidate != null) 'candidate': candidate,
      if (sdpMid != null) 'sdpMid': sdpMid,
      if (sdpMLineIndex != null) 'sdpMLineIndex': sdpMLineIndex,
      if (error != null) 'message': error,
    };
  }

  void _validate() {
    if (roomId.isEmpty ||
        senderId.isEmpty ||
        role.isEmpty ||
        (sessionId != null && sessionId!.isEmpty) ||
        (sessionId == null &&
            !(type == SignalingMessageType.join && role == 'listener'))) {
      throw const FormatException(
        'roomID, sessionID, senderID and role are required',
      );
    }
    if (recipientId != null && recipientId!.isEmpty) {
      throw const FormatException('recipientID cannot be empty');
    }
    if ((type == SignalingMessageType.peerReady ||
            type == SignalingMessageType.startStreaming ||
            type == SignalingMessageType.offer ||
            type == SignalingMessageType.answer ||
            type == SignalingMessageType.candidate ||
            type == SignalingMessageType.peerLeft) &&
        recipientId == null) {
      throw FormatException('${type.value} requires recipientID');
    }
    if ((type == SignalingMessageType.offer ||
            type == SignalingMessageType.answer) &&
        (sdp == null || sdp!.isEmpty)) {
      throw FormatException('${type.value} requires sdp');
    }
    if (type == SignalingMessageType.candidate &&
        (candidate == null || candidate!.isEmpty)) {
      throw const FormatException('candidate requires candidate');
    }
    if (type == SignalingMessageType.error &&
        (error == null || error!.isEmpty)) {
      throw const FormatException('error message requires error');
    }
  }

  factory SignalingMessage.fromJson(Map<String, dynamic> json) {
    final type = SignalingMessageType.fromValue(json['type']);
    if (type == null) throw const FormatException('Unknown signaling type');

    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw FormatException('Missing or invalid $key');
      }
      return value;
    }

    String? optionalString(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! String) throw FormatException('Invalid $key');
      return value;
    }

    final index = json['sdpMLineIndex'];
    if (index != null && index is! num) {
      throw const FormatException('Invalid sdpMLineIndex');
    }

    final message = SignalingMessage(
      type: type,
      roomId: requiredString('roomID'),
      sessionId: optionalString('sessionID'),
      senderId: requiredString('senderID'),
      role: requiredString('role'),
      recipientId: optionalString('recipientID'),
      sdp: optionalString('sdp'),
      candidate: optionalString('candidate'),
      sdpMid: optionalString('sdpMid'),
      sdpMLineIndex: (index as num?)?.toInt(),
      error: optionalString('message') ?? optionalString('error'),
    );
    message._validate();
    return message;
  }

  static SignalingMessage fromRealtimeEnvelope(
    Object? envelope, {
    required String event,
  }) {
    Object? applicationPayload = envelope;
    if (envelope is String) {
      applicationPayload = jsonDecode(envelope);
    }
    if (applicationPayload is! Map) {
      throw const FormatException('Realtime message must be a JSON object');
    }

    final outer = Map<String, dynamic>.from(applicationPayload);
    if (outer['type'] == 'broadcast') {
      if (outer['event'] != null && outer['event'] != event) {
        throw const FormatException('Unexpected Realtime event');
      }
      applicationPayload = outer['payload'];
    } else if (!outer.containsKey('roomID') && outer.containsKey('payload')) {
      applicationPayload = outer['payload'];
    }

    if (applicationPayload is String) {
      applicationPayload = jsonDecode(applicationPayload);
    }
    if (applicationPayload is! Map) {
      throw const FormatException('Missing signaling payload');
    }
    return SignalingMessage.fromJson(
      Map<String, dynamic>.from(applicationPayload),
    );
  }
}

class SignalingMessageRouter {
  SignalingMessageRouter({required this.roomId, required this.recipientId});

  final String roomId;
  final String recipientId;
  final _seen = <String>{};
  static const _maxRememberedMessages = 512;

  SignalingMessage? route(
    Object? envelope, {
    required String event,
    required String ownSenderId,
  }) {
    late final SignalingMessage message;
    try {
      message = SignalingMessage.fromRealtimeEnvelope(envelope, event: event);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }

    if (message.roomId != roomId ||
        message.senderId == ownSenderId ||
        (message.recipientId != null && message.recipientId != recipientId)) {
      return null;
    }

    // Control messages repeat identically (pause/resume/pause), so they are not deduplicated.
    final isControl =
        message.type == SignalingMessageType.pauseStreaming ||
        message.type == SignalingMessageType.resumeStreaming ||
        message.type == SignalingMessageType.stopStreaming;
    final key = jsonEncode(message.toJson());
    if (!isControl && !_seen.add(key)) return null;
    if (_seen.length > _maxRememberedMessages) _seen.remove(_seen.first);
    return message;
  }

  void resetDeduplication() => _seen.clear();
}
