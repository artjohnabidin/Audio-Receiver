@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:audio_receiver/audio_receiver.dart';
import 'package:audio_receiver/signaling.dart';
import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web/web.dart' as web;

class LocalSignaling extends SupabaseSignaling {
  LocalSignaling()
    : super(
        client: SupabaseClient('https://example.supabase.co', 'test-key'),
        roomId: 'event-1',
      );

  final incoming = StreamController<SignalingMessage>.broadcast();
  final ready = StreamController<void>.broadcast();
  final sent = <SignalingMessage>[];
  final pendingCandidates = <RTCIceCandidate>[];
  web.AudioContext? audioContext;
  RTCPeerConnection? broadcaster;
  bool remoteDescriptionSet = false;
  bool rejectJoin = false;
  bool rejectDeparture = false;

  @override
  Stream<SignalingMessage> get messages => incoming.stream;

  @override
  Stream<void> get readyEvents => ready.stream;

  @override
  Future<void> connect() async => ready.add(null);

  void announce({SignalingMessageType type = SignalingMessageType.join}) {
    incoming.add(
      SignalingMessage(
        type: type,
        roomId: roomId,
        sessionId: 'BROADCASTER-SESSION',
        senderId: 'broadcaster-1',
        role: 'broadcaster',
        recipientId: type == SignalingMessageType.join ? null : peerId,
      ),
    );
  }

  @override
  Future<void> send({
    required SignalingMessageType type,
    String? sessionId,
    String? recipientId,
    String? sdp,
    String? candidate,
    String? sdpMid,
    int? sdpMLineIndex,
    String? error,
  }) async {
    if (type == SignalingMessageType.join && rejectJoin ||
        type == SignalingMessageType.peerLeft && rejectDeparture) {
      throw StateError('Simulated transport failure');
    }
    final message = SignalingMessage(
      type: type,
      roomId: roomId,
      sessionId: sessionId,
      senderId: peerId,
      role: 'listener',
      recipientId: recipientId,
      sdp: sdp,
      candidate: candidate,
      sdpMid: sdpMid,
      sdpMLineIndex: sdpMLineIndex,
      error: error,
    );
    message.toJson();
    sent.add(message);
    final pc = broadcaster;
    if (pc == null) return;
    if (type == SignalingMessageType.offer) {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      remoteDescriptionSet = true;
      for (final pending in pendingCandidates) {
        await pc.addCandidate(pending);
      }
      pendingCandidates.clear();
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      incoming.add(
        SignalingMessage(
          type: SignalingMessageType.answer,
          roomId: roomId,
          sessionId: sessionId,
          senderId: 'broadcaster-1',
          role: 'broadcaster',
          recipientId: peerId,
          sdp: answer.sdp,
        ),
      );
    } else if (type == SignalingMessageType.candidate) {
      final ice = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);
      if (remoteDescriptionSet) {
        await pc.addCandidate(ice);
      } else {
        pendingCandidates.add(ice);
      }
    }
  }

  Future<void> createBroadcaster() async {
    broadcaster = await createPeerConnection({'iceServers': []});
    broadcaster!.onIceCandidate = (candidate) {
      if (candidate.candidate?.isEmpty ?? true) return;
      incoming.add(
        SignalingMessage(
          type: SignalingMessageType.candidate,
          roomId: roomId,
          sessionId: 'BROADCASTER-SESSION',
          senderId: 'broadcaster-1',
          role: 'broadcaster',
          recipientId: peerId,
          candidate: candidate.candidate,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
        ),
      );
    };
  }

  Future<void> createBroadcasterWithAudio() async {
    await createBroadcaster();
    audioContext = web.AudioContext();
    final audioStream = audioContext!.createMediaStreamDestination().stream;
    final stream = MediaStreamWeb(audioStream, 'test-broadcaster');
    await broadcaster!.addTrack(stream.getAudioTracks().single, stream);
  }

  @override
  Future<void> dispose() async {
    await broadcaster?.close();
    final context = audioContext;
    if (context != null && context.state != 'closed') {
      await context.close().toDart;
    }
    await incoming.close();
    await ready.close();
    await client.dispose();
  }
}

Future<void> waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for WebRTC state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test(
    'late listener discovers broadcaster and negotiates once with real ICE',
    () async {
      final signaling = LocalSignaling();
      final receiver = AudioReceiver(signaling, iceServers: const []);
      addTearDown(receiver.stop);
      await signaling.createBroadcaster();
      await receiver.start();
      await waitFor(() => signaling.sent.isNotEmpty);
      expect(signaling.sent.first.type, SignalingMessageType.join);
      expect(signaling.sent.first.sessionId, isNull);

      signaling.announce();
      await waitFor(() => receiver.state.value == ReceiverState.connected);
      final offer = signaling.sent.singleWhere(
        (message) => message.type == SignalingMessageType.offer,
      );
      expect(offer.sdp, contains('a=recvonly'));
      expect(offer.sessionId, 'BROADCASTER-SESSION');
      expect(offer.recipientId, 'broadcaster-1');
      expect(signaling.pendingCandidates, isEmpty);
      final offerIndex = signaling.sent.indexOf(offer);
      for (final message in signaling.sent.where(
        (message) => message.type == SignalingMessageType.candidate,
      )) {
        expect(signaling.sent.indexOf(message), greaterThan(offerIndex));
      }

      signaling.announce();
      signaling.announce(type: SignalingMessageType.peerReady);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        signaling.sent.where(
          (message) => message.type == SignalingMessageType.offer,
        ),
        hasLength(1),
      );
      expect(receiver.state.value, ReceiverState.connected);

      signaling.incoming.addError(StateError('Disconnected'));
      await waitFor(() => receiver.state.value == ReceiverState.disconnected);
      expect(receiver.audioAvailable.value, isFalse);
      expect(receiver.renderer.srcObject, isNull);
    },
  );

  test(
    'failed discovery does not poison queue and departure is best effort',
    () async {
      final signaling = LocalSignaling()..rejectJoin = true;
      final receiver = AudioReceiver(signaling, iceServers: const []);
      await signaling.createBroadcaster();
      await receiver.start();
      await waitFor(() => receiver.state.value == ReceiverState.disconnected);
      signaling.rejectJoin = false;
      signaling.ready.add(null);
      await waitFor(
        () => receiver.state.value == ReceiverState.waitingForBroadcaster,
      );
      signaling.announce();
      await waitFor(() => receiver.state.value == ReceiverState.connected);
      signaling.rejectDeparture = true;
      await receiver.stop();
      expect(receiver.state.value, ReceiverState.disconnected);
      expect(receiver.renderer.srcObject, isNull);
    },
  );

  test(
    'exposes the remote browser stream and clears it on peer departure',
    () async {
      final signaling = LocalSignaling();
      final receiver = AudioReceiver(signaling, iceServers: const []);
      addTearDown(receiver.stop);
      await signaling.createBroadcasterWithAudio();
      await receiver.start();
      signaling.announce();

      await waitFor(() => receiver.audioAvailable.value);
      expect(receiver.remoteWebStream, isNotNull);

      signaling.announce(type: SignalingMessageType.peerLeft);
      await waitFor(() => !receiver.audioAvailable.value);
      expect(receiver.remoteWebStream, isNull);
    },
  );
}
