import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web/web.dart' as web;

import 'signaling.dart';

enum ReceiverState {
  connecting,
  waitingForBroadcaster,
  connected,
  disconnected,
}

class AudioReceiver {
  AudioReceiver(
    this.signaling, {
    this.iceServers = const [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  });

  final SupabaseSignaling signaling;
  final List<Map<String, dynamic>> iceServers;

  final state = ValueNotifier(ReceiverState.disconnected);
  final log = ValueNotifier<List<String>>([]);
  final audioAvailable = ValueNotifier(false);
  final renderer = RTCVideoRenderer();

  RTCPeerConnection? _pc;
  String? _remoteId;
  String? _sessionId;
  bool _remoteDescriptionSet = false;
  bool _started = false;
  final _pendingCandidates = <SignalingMessage>[];
  StreamSubscription<SignalingMessage>? _messageSub;
  StreamSubscription<void>? _readySub;
  Future<void> _queue = Future.value();

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _setState(ReceiverState.connecting);
    await renderer.initialize();
    renderer.muted = true;
    _messageSub = signaling.messages.listen(
      _enqueueSignal,
      onError: (Object error) => _enqueueOperation(() async {
        _log('Signaling disconnected: $error');
        await _closePeer();
        _setState(ReceiverState.disconnected);
      }),
    );
    _readySub = signaling.readyEvents.listen((_) {
      _enqueueOperation(_announceReady);
    });
    await signaling.connect();
  }

  void _enqueueSignal(SignalingMessage message) {
    _enqueueOperation(() => _handleSignal(message));
  }

  void _enqueueOperation(Future<void> Function() operation) {
    _queue = _queue.then((_) async {
      if (!_started) return;
      try {
        await operation();
      } catch (error) {
        _log('Signaling operation failed: $error');
        await _closePeer();
        _setState(ReceiverState.disconnected);
      }
    });
  }

  Future<void> _announceReady() async {
    await _closePeer();
    _setState(ReceiverState.connecting);
    await signaling.send(type: SignalingMessageType.join);
    _setState(ReceiverState.waitingForBroadcaster);
    _log('Joined room "${signaling.roomId}"; waiting for broadcaster');
  }

  Future<void> _handleSignal(SignalingMessage message) async {
    if (message.role != 'broadcaster') return;
    _log(
      'Received ${message.type.value} from ${message.senderId} '
      '(session ${message.sessionId}, room ${message.roomId})',
    );
    try {
      switch (message.type) {
        case SignalingMessageType.peerReady:
          await _negotiate(message);
        case SignalingMessageType.answer:
          await _handleAnswer(message);
        case SignalingMessageType.candidate:
          await _handleCandidate(message);
        case SignalingMessageType.peerLeft:
          if (_isCurrentPeer(message)) {
            await _closePeer();
            _setState(ReceiverState.disconnected);
            _log('Broadcaster disconnected');
          }
        case SignalingMessageType.error:
          if (!_isCurrentPeer(message)) return;
          _log('Signaling error: ${message.error}');
          await _closePeer();
          _setState(ReceiverState.disconnected);
        case SignalingMessageType.join:
          if (_isCurrentPeer(message)) return;
          await signaling.send(
            type: SignalingMessageType.peerReady,
            sessionId: message.sessionId,
            recipientId: message.senderId,
          );
          await _negotiate(message);
          break;
        case SignalingMessageType.offer:
          break;
      }
    } catch (error) {
      _log('Error handling ${message.type.value}: $error');
      await _closePeer();
      _setState(ReceiverState.disconnected);
    }
  }

  Future<void> _negotiate(SignalingMessage ready) async {
    if (ready.role != 'broadcaster') return;
    if (_isCurrentPeer(ready)) return;
    _log(
      'Negotiation started with broadcaster ${ready.senderId} '
      '(session ${ready.sessionId})',
    );
    final earlyCandidates = [..._pendingCandidates];
    await _closePeer();
    _remoteId = ready.senderId;
    _sessionId = ready.sessionId;
    _pendingCandidates.addAll(earlyCandidates.where(_isCurrentPeer));
    _setState(ReceiverState.connecting);

    final pc = await createPeerConnection({'iceServers': iceServers});
    if (!_started) {
      await pc.close();
      return;
    }
    _pc = pc;
    final sessionId = ready.sessionId!;
    final remoteId = ready.senderId;
    final localCandidates = <RTCIceCandidate>[];
    var offerSent = false;

    Future<void> sendCandidate(RTCIceCandidate candidate) => signaling.send(
      type: SignalingMessageType.candidate,
      sessionId: sessionId,
      recipientId: remoteId,
      candidate: candidate.candidate,
      sdpMid: candidate.sdpMid,
      sdpMLineIndex: candidate.sdpMLineIndex,
    );

    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );

    pc.onIceCandidate = (candidate) {
      if (_pc != pc ||
          candidate.candidate == null ||
          candidate.candidate!.isEmpty) {
        return;
      }
      if (!offerSent) {
        localCandidates.add(candidate);
        return;
      }
      unawaited(
        sendCandidate(candidate).catchError((Object error) {
          _log('Failed to send ICE candidate: $error');
        }),
      );
    };

    pc.onTrack = (event) async {
      if (_pc != pc || event.track.kind != 'audio') return;
      final stream = event.streams.isNotEmpty
          ? event.streams.first
          : await createLocalMediaStream('remote-audio');
      if (event.streams.isEmpty) await stream.addTrack(event.track);
      if (_pc != pc) return;
      event.track.enabled = true;
      renderer.srcObject = stream;
      renderer.muted = true;
      audioAvailable.value = true;
      _log('Remote audio track received');
    };

    pc.onIceConnectionState = (iceState) {
      if (_pc != pc) return;
      _log('ICE: ${iceState.name}');
      if (iceState == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          iceState == RTCIceConnectionState.RTCIceConnectionStateClosed ||
          iceState == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _setState(ReceiverState.disconnected);
      }
    };
    pc.onConnectionState = (connectionState) {
      if (_pc != pc) return;
      _log('Connection: ${connectionState.name}');
      if (connectionState ==
          RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _setState(ReceiverState.connected);
      } else if (connectionState ==
              RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          connectionState ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          connectionState ==
              RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _setState(ReceiverState.disconnected);
      }
    };

    final offer = await pc.createOffer();
    if (_pc != pc) return;
    await pc.setLocalDescription(offer);
    if (_pc != pc) return;
    _log(
      'Sending offer to $_remoteId '
      '(session $_sessionId, ${offer.sdp?.length ?? 0} SDP characters)',
    );
    await signaling.send(
      type: SignalingMessageType.offer,
      sessionId: sessionId,
      recipientId: remoteId,
      sdp: offer.sdp,
    );
    if (_pc != pc) return;
    offerSent = true;
    for (final candidate in localCandidates) {
      if (_pc != pc) return;
      await sendCandidate(candidate);
    }
    _log('Offer sent to $_remoteId (session $_sessionId)');
  }

  Future<void> _handleAnswer(SignalingMessage message) async {
    if (!_isCurrentPeer(message)) return;
    final pc = _pc;
    if (pc == null || _remoteDescriptionSet) return;
    _log(
      'Received answer from ${message.senderId} '
      '(session ${message.sessionId}, ${message.sdp?.length ?? 0} SDP characters)',
    );
    await pc.setRemoteDescription(RTCSessionDescription(message.sdp, 'answer'));
    _remoteDescriptionSet = true;
    for (final candidate in _pendingCandidates.where(_isCurrentPeer).toList()) {
      await pc.addCandidate(_toCandidate(candidate));
      _pendingCandidates.remove(candidate);
    }
    _log('Answer applied');
  }

  bool _isCurrentPeer(SignalingMessage message) =>
      message.senderId == _remoteId && message.sessionId == _sessionId;

  RTCIceCandidate _toCandidate(SignalingMessage message) =>
      RTCIceCandidate(message.candidate, message.sdpMid, message.sdpMLineIndex);

  Future<void> _handleCandidate(SignalingMessage message) async {
    if (_remoteId != null && !_isCurrentPeer(message)) return;
    final pc = _pc;
    if (pc != null && _remoteDescriptionSet) {
      await pc.addCandidate(_toCandidate(message));
    } else {
      _pendingCandidates.add(message);
    }
  }

  Future<void> enableAudioPlayback() async {
    final textureId = renderer.textureId;
    if (!audioAvailable.value || textureId == null) return;
    final element = web.document.getElementById(
      'audio_RTCVideoRenderer-$textureId',
    );
    if (element == null || !element.isA<web.HTMLAudioElement>()) return;
    final audioElement = element as web.HTMLAudioElement;
    try {
      audioElement.muted = false;
      renderer.muted = false;
      await audioElement.play().toDart;
      _log('Audio playback enabled');
    } catch (error) {
      _log('Browser blocked audio playback: $error');
      rethrow;
    }
  }

  Future<void> _closePeer() async {
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    audioAvailable.value = false;
    renderer.srcObject = null;
    final pc = _pc;
    _pc = null;
    _remoteId = null;
    _sessionId = null;
    await pc?.close();
  }

  Future<void> stop() async {
    _started = false;
    final remoteId = _remoteId;
    final sessionId = _sessionId;
    await _messageSub?.cancel();
    await _readySub?.cancel();
    await _closePeer();
    await _queue;
    if (remoteId != null && sessionId != null) {
      try {
        await signaling.send(
          type: SignalingMessageType.peerLeft,
          sessionId: sessionId,
          recipientId: remoteId,
        );
      } catch (error) {
        _log('Could not send departure: $error');
      }
    }
    await signaling.dispose();
    await renderer.dispose();
    _started = false;
    _setState(ReceiverState.disconnected);
  }

  void _setState(ReceiverState next) {
    state.value = next;
    _log('Listener status: ${next.name}');
  }

  void _log(String line) {
    debugPrint('[AudioReceiver] $line');
    log.value = [...log.value, line];
  }
}
