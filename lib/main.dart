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
      body: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            if (!_configured)
              const Expanded(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Missing Supabase config.\nRun with --dart-define-from-file=env.json',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight * 0.45,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: .stretch,
                    mainAxisSize: MainAxisSize.min,
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
                      if (receiver == null)
                        const _ConnectionStatus()
                      else
                        ValueListenableBuilder(
                          valueListenable: receiver.state,
                          builder: (_, state, _) =>
                              _ConnectionStatus(state: state),
                        ),
                      const SizedBox(height: 16),
                      if (receiver != null) ...[
                        ValueListenableBuilder(
                          valueListenable: receiver.state,
                          builder: (_, state, _) =>
                              state == ReceiverState.connected
                              ? Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: ValueListenableBuilder(
                                    valueListenable: receiver.paused,
                                    builder: (_, paused, _) => Wrap(
                                      spacing: 8,
                                      children: [
                                        FilledButton.tonalIcon(
                                          onPressed: paused
                                              ? receiver.resumeStreaming
                                              : receiver.pauseStreaming,
                                          icon: Icon(
                                            paused
                                                ? Icons.play_arrow
                                                : Icons.pause,
                                          ),
                                          label: Text(
                                            paused ? 'Resume' : 'Pause',
                                          ),
                                        ),
                                        FilledButton.tonalIcon(
                                          onPressed: receiver.stopStreaming,
                                          icon: const Icon(Icons.stop),
                                          label: const Text('Stop'),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                        ValueListenableBuilder(
                          valueListenable: receiver.pendingBroadcaster,
                          builder: (_, pending, _) => pending != null
                              ? Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: FilledButton.icon(
                                      onPressed: receiver.startStreaming,
                                      icon: const Icon(Icons.play_arrow),
                                      label: const Text('Start streaming'),
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink(),
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
                      ],
                    ],
                  ),
                ),
              ),
            if (_transcriber case final transcriber?)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ValueListenableBuilder(
                        valueListenable: transcriber.status,
                        builder: (_, value, _) => Text(
                          value,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
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
                                    builder: (_, text, _) =>
                                        SingleChildScrollView(
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
              ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({this.state});

  final ReceiverState? state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (title, description, icon, color) = switch (state) {
      null => (
        'Ready to connect',
        'Choose a room to start listening.',
        Icons.headphones,
        scheme.primary,
      ),
      ReceiverState.connecting => (
        'Connecting',
        'Establishing a signaling connection.',
        Icons.sync,
        scheme.primary,
      ),
      ReceiverState.waitingForBroadcaster => (
        'Waiting for broadcaster',
        'Connected to the room. Waiting for live audio.',
        Icons.hourglass_top,
        scheme.tertiary,
      ),
      ReceiverState.connected => (
        'Audio connected',
        'The live audio stream is ready.',
        Icons.graphic_eq,
        Colors.green.shade700,
      ),
      ReceiverState.disconnected => (
        'Disconnected',
        'The connection ended. Reconnect to continue listening.',
        Icons.link_off,
        scheme.error,
      ),
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(description, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.circle, size: 10, color: color),
        ],
      ),
    );
  }
}
