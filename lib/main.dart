import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'audio_receiver.dart';
import 'signaling.dart';
import 'speech_transcriber.dart';

// Provide via: flutter run -d chrome --dart-define-from-file=env.json
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseAnonKey = String.fromEnvironment('SUPABASE_KEY');
const iceServersJson = String.fromEnvironment(
  'WEBRTC_ICE_SERVERS',
  defaultValue: '[{"urls":"stun:stun.l.google.com:19302"}]',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty) {
    await Supabase.initialize(
      url: supabaseUrl,
      publishableKey: supabaseAnonKey,
    );
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audio Receiver',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.deepPurple)),
      home: const ReceiverPage(),
    );
  }
}

class ReceiverPage extends StatefulWidget {
  const ReceiverPage({super.key});

  @override
  State<ReceiverPage> createState() => _ReceiverPageState();
}

class _ReceiverPageState extends State<ReceiverPage> {
  final _roomController = TextEditingController(text: 'event-1');
  AudioReceiver? _receiver;
  SpeechTranscriber? _transcriber;
  VoidCallback? _audioAvailabilityListener;

  bool get _configured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  Future<void> _start() async {
    final room = _roomController.text.trim();
    if (room.isEmpty) return;
    try {
      final iceServers = (jsonDecode(iceServersJson) as List)
          .map((server) => Map<String, dynamic>.from(server as Map))
          .toList();
      final receiver = AudioReceiver(
        SupabaseSignaling(client: Supabase.instance.client, roomId: room),
        iceServers: iceServers,
      );
      setState(() => _receiver = receiver);
      void onAudioAvailabilityChanged() {
        if (receiver.audioAvailable.value) {
          unawaited(_startTranscription(receiver));
        } else {
          unawaited(_stopTranscription());
        }
      }

      _audioAvailabilityListener = onAudioAvailabilityChanged;
      receiver.audioAvailable.addListener(onAudioAvailabilityChanged);
      await receiver.start();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to join: $e')));
      await _stop();
    }
  }

  Future<void> _stop() async {
    final receiver = _receiver;
    final listener = _audioAvailabilityListener;
    if (receiver != null && listener != null) {
      receiver.audioAvailable.removeListener(listener);
    }
    _audioAvailabilityListener = null;
    await _stopTranscription();
    setState(() => _receiver = null);
    await receiver?.stop();
  }

  Future<void> _startTranscription(AudioReceiver receiver) async {
    if (_transcriber case final current? when !current.isStopped) return;
    final stream = receiver.remoteWebStream;
    if (stream == null || !mounted) return;
    final transcriber = _transcriber ?? SpeechTranscriber();
    setState(() => _transcriber = transcriber);
    try {
      await transcriber.start(stream);
    } catch (error) {
      if (transcriber.isStopped || !mounted) return;
      debugPrint('Transcription failed: $error');
    }
  }

  Future<void> _stopTranscription() async {
    final transcriber = _transcriber;
    if (transcriber == null || transcriber.isStopped) return;
    try {
      await transcriber.stop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not stop transcription: $error')),
        );
      }
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> _enableAudio(AudioReceiver receiver) async {
    final resumeTranscription = _transcriber?.resumeAudioFromUserGesture();
    try {
      await receiver.enableAudioPlayback();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not enable audio: $error')));
    }
    try {
      await resumeTranscription;
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not resume transcription: $error')),
      );
    }
  }

  @override
  void dispose() {
    final receiver = _receiver;
    final listener = _audioAvailabilityListener;
    if (receiver != null && listener != null) {
      receiver.audioAvailable.removeListener(listener);
    }
    final transcriber = _transcriber;
    if (transcriber != null) {
      unawaited(
        transcriber.stop().catchError((Object error) {
          debugPrint('Could not stop transcription: $error');
        }),
      );
      transcriber.dispose();
    }
    _receiver?.stop();
    _roomController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final receiver = _receiver;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('WebRTC Audio Receiver'),
      ),
      body: Column(
        children: [
          Expanded(
            child: !_configured
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Missing Supabase config.\nRun with --dart-define-from-file=env.json',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: .stretch,
                      children: [
                        TextField(
                          controller: _roomController,
                          enabled: receiver == null,
                          decoration: const InputDecoration(
                            labelText: 'Room ID',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: receiver == null ? _start : _stop,
                          icon: Icon(
                            receiver == null ? Icons.headphones : Icons.stop,
                          ),
                          label: Text(receiver == null ? 'Connect' : 'Leave'),
                        ),
                        const SizedBox(height: 16),
                        if (receiver != null) ...[
                          ValueListenableBuilder(
                            valueListenable: receiver.state,
                            builder: (_, state, _) {
                              final label = switch (state) {
                                ReceiverState.connecting => 'Connecting',
                                ReceiverState.waitingForBroadcaster =>
                                  'Waiting for Broadcaster',
                                ReceiverState.connected => 'Connected',
                                ReceiverState.disconnected => 'Disconnected',
                              };
                              return Text(
                                'Status: $label',
                                style: Theme.of(context).textTheme.titleMedium,
                              );
                            },
                          ),
                          ValueListenableBuilder(
                            valueListenable: receiver.audioAvailable,
                            builder: (_, available, _) => available
                                ? Align(
                                    alignment: Alignment.centerLeft,
                                    child: FilledButton.icon(
                                      onPressed: () => _enableAudio(receiver),
                                      icon: const Icon(Icons.volume_up),
                                      label: const Text('Enable audio'),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                          // Hidden renderer; required for the browser to play remote audio.
                          SizedBox(
                            width: 1,
                            height: 1,
                            child: RTCVideoView(receiver.renderer),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: ValueListenableBuilder(
                              valueListenable: receiver.log,
                              builder: (_, lines, _) => ListView(
                                children: [
                                  for (final l in lines)
                                    Text(
                                      l,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
          if (_transcriber case final transcriber?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ValueListenableBuilder(
                    valueListenable: transcriber.status,
                    builder: (_, value, _) => Text(
                      value,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 160,
                    child: Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Transcript',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: ValueListenableBuilder(
                                valueListenable: transcriber.transcript,
                                builder: (_, text, _) => SingleChildScrollView(
                                  reverse: true,
                                  child: SelectableText(
                                    text.isEmpty
                                        ? 'Transcript will appear here'
                                        : text,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
